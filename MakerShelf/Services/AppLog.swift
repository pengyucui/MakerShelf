import Foundation

enum AppLogLevel: String, Codable, CaseIterable, Sendable {
    case debug = "调试", info = "信息", warning = "警告", error = "错误"
}

enum AppLogCategory: String, Codable, CaseIterable, Sendable {
    case app = "应用", preview = "文件预览", image = "图片处理", download = "下载任务"
    case importing = "模型导入", storage = "本地存储", account = "站点账号"
}

struct AppLogEntry: Identifiable, Codable, Sendable {
    let id: UUID
    let date: Date
    let session: String
    let level: AppLogLevel
    let category: AppLogCategory
    let message: String
    let detail: String

    var text: String {
        "\(date.ISO8601Format()) [\(level.rawValue)] [\(category.rawValue)] \(message)\n会话：\(session)"
            + (detail.isEmpty ? "" : "\n\(detail)")
    }
}

struct AppLogSnapshot: Sendable {
    let entries: [AppLogEntry]
    let storageError: String?
}

/// 所有可变状态由 serial queue 独占；调用处无需切换 actor，磁盘写入不会阻塞 SwiftUI。
/// 不记录网络正文、Cookie、密码或令牌；日志中的错误文本仍统一经过脱敏。
final class AppLog: @unchecked Sendable {
    static let shared = AppLog()
    let session = UUID().uuidString
    let directory: URL
    private let queue = DispatchQueue(label: "MakerShelf.AppLog", qos: .utility)
    private var entries: [AppLogEntry] = []
    private var loaded = false
    private var storageError: String?
    private let maxEntries = 2_000
    private let maxFileBytes = 2 * 1_024 * 1_024

    private init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        directory = root.appendingPathComponent("MakerShelf/Logs", isDirectory: true)
    }

    static func write(_ level: AppLogLevel = .info, _ category: AppLogCategory,
                      _ message: String, detail: String = "") {
        let logger = shared
        let timestamp = Date()
        // 在排队之前裁剪，避免错误响应或意外传入的大文本占满待写队列。
        let message = String(message.prefix(512))
        let detail = String(detail.prefix(8_192))
        logger.queue.async {
            logger.loadIfNeeded()
            let entry = AppLogEntry(id: UUID(), date: timestamp, session: logger.session,
                                    level: level, category: category,
                                    message: Self.redact(message), detail: Self.redact(detail))
            logger.entries.append(entry)
            if logger.entries.count > logger.maxEntries {
                logger.entries.removeFirst(logger.entries.count - logger.maxEntries)
            }
            do {
                try logger.append(entry)
                logger.storageError = nil
            } catch {
                // 日志落盘失败只影响持久化，不递归写日志、不打断业务。
                logger.storageError = Self.errorDescription(error)
            }
        }
    }

    /// 排除 ShelfError.http 的响应正文，保留错误类型、状态码和经过脱敏的可读原因。
    static func errorDescription(_ error: Error) -> String {
        if let shelf = error as? ShelfError, case .http(let status, _) = shelf { return "HTTP \(status)" }
        let value = error as NSError
        return redact("\(value.domain) (\(value.code))：\(String(error.localizedDescription.prefix(2_048)))")
    }

    func snapshot() async -> AppLogSnapshot {
        await withCheckedContinuation { continuation in
            queue.async {
                self.loadIfNeeded()
                continuation.resume(returning: AppLogSnapshot(entries: Array(self.entries.reversed()), storageError: self.storageError))
            }
        }
    }

    /// 与追加共用串行队列，清空后新产生的日志仍正常保留。
    func clear() async -> String? {
        await withCheckedContinuation { continuation in
            queue.async {
                self.loadIfNeeded()
                do {
                    for index in 0...2 {
                        let url = self.file(index)
                        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                    }
                    self.entries = []
                    self.storageError = nil
                    continuation.resume(returning: nil)
                } catch {
                    self.storageError = Self.errorDescription(error)
                    continuation.resume(returning: self.storageError)
                }
            }
        }
    }

    /// 应用退出前等待已经排队的少量关键事件写完；不能从日志队列内部调用。
    func flush() { queue.sync {} }

    static func exportData(_ entries: [AppLogEntry]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        var data = Data()
        for entry in entries.reversed() {
            data.append(try encoder.encode(entry))
            data.append(0x0A)
        }
        return data
    }

    /// 导出使用用户在保存面板选择的位置；编码和写文件不占用主线程，也不阻塞日志写入队列。
    static func export(_ entries: [AppLogEntry], to url: URL) async throws {
        try await Task.detached(priority: .utility) {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            try exportData(entries).write(to: url, options: .atomic)
        }.value
    }

    private func file(_ index: Int) -> URL {
        directory.appendingPathComponent(index == 0 ? "app.jsonl" : "app-\(index).jsonl")
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for index in (0...2).reversed() {
            let url = file(index)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: maxFileBytes) ?? Data()
                for line in data.split(separator: 0x0A) {
                    if let entry = try? decoder.decode(AppLogEntry.self, from: Data(line)) { entries.append(entry) }
                }
                if entries.count > maxEntries { entries.removeFirst(entries.count - maxEntries) }
            } catch { storageError = Self.errorDescription(error) }
        }
    }

    private func append(_ entry: AppLogEntry) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoded = try Self.exportData([entry])
        let size = (try? file(0).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size + encoded.count > maxFileBytes {
            if manager.fileExists(atPath: file(2).path) { try manager.removeItem(at: file(2)) }
            if manager.fileExists(atPath: file(1).path) { try manager.moveItem(at: file(1), to: file(2)) }
            if manager.fileExists(atPath: file(0).path) { try manager.moveItem(at: file(0), to: file(1)) }
        }
        if !manager.fileExists(atPath: file(0).path) {
            try encoded.write(to: file(0), options: .atomic)
        } else {
            let handle = try FileHandle(forWritingTo: file(0))
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: encoded)
        }
    }

    private static func redact(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
        if let regex = try? NSRegularExpression(pattern: #"https?://[^\s<>"']+"#) {
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
                guard let range = Range(match.range, in: text), var url = URLComponents(string: String(text[range])) else { continue }
                url.user = nil; url.password = nil; url.query = nil; url.fragment = nil
                text.replaceSubrange(range, with: url.string ?? "[网址已隐藏]")
            }
        }
        text = text.replacingOccurrences(of: #"(?i)\bBearer\s+[^\s,;]+"#, with: "Bearer [已隐藏]", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?im)["']?(authorization|cookie|set-cookie|access[_-]?token|refresh[_-]?token|token|password)["']?\s*[=:]\s*[^\r\n]+"#,
                                         with: "$1=[已隐藏]", options: .regularExpression)
        return text
    }
}
