import Foundation
import CryptoKit
import zlib

struct ModelFileThumb: Sendable {
    var imageURL: URL
    var plateCount: Int
}

struct ModelPreviewImage: Sendable {
    var imageData: Data
    var plateCount: Int
    var fileExtension: String
}

/// 3MF 提取包内图片，STL / OBJ 根据几何生成静态预览；结果缓存在应用缓存目录，不修改原文件。
/// 所有解析和渲染在此 actor 内串行执行。
actor ModelFilePreviewStore {
    static let shared = ModelFilePreviewStore()
    private struct Cached { let value: ModelFileThumb? }
    private var cache: [String: Cached] = [:]
    private var cacheOrder: [String] = []

    func thumbnail(for fileURL: URL, revision: String, retry: Bool = false) -> ModelFileThumb? {
        guard !Task.isCancelled else { return nil }
        let accessing = fileURL.startAccessingSecurityScopedResource()
        defer { if accessing { fileURL.stopAccessingSecurityScopedResource() } }
        let values: URLResourceValues
        do {
            values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        } catch {
            AppLog.write(.error, .preview, "模型文件无法读取",
                         detail: "文件：\(fileURL.lastPathComponent)\n\(AppLog.errorDescription(error))")
            return nil
        }
        // STL 的缓存标识包含本次参数快照，修改设置后不会沿用旧缩略图或失败记录。
        let options = fileURL.pathExtension.lowercased() == "stl" ? STLPreviewOptions.current() : nil
        let identity = "\(MeshPreviewRenderer.cacheVersion):\(fileURL.standardizedFileURL.path):\(values.fileSize ?? 0):\(values.contentModificationDate?.timeIntervalSince1970 ?? 0):\(revision):\(options?.cacheKey ?? "")"
        let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        // 主动重试跳过失败缓存，权限或文件恢复后无需重启应用。
        if retry {
            cache[key] = nil
            cacheOrder.removeAll { $0 == key }
        }
        if let known = cache[key] {
            if let value = known.value, FileManager.default.fileExists(atPath: value.imageURL.path) { return value }
            if known.value == nil { return nil }
            cache[key] = nil
            cacheOrder.removeAll { $0 == key }
        }
        let value = Self.make(fileURL, key: key, options: options, retry: retry)
        guard !Task.isCancelled else { return nil }
        cache[key] = Cached(value: value)
        cacheOrder.append(key)
        if cacheOrder.count > 128 { cache[cacheOrder.removeFirst()] = nil }
        return value
    }

    /// 用于新导入文件选封面；STL / OBJ 生成图片，3MF 读取包内图片，不在源文件旁写缓存。
    func coverPreview(for fileURL: URL) -> ModelPreviewImage? {
        Self.readPreview(fileURL, options: fileURL.pathExtension.lowercased() == "stl" ? .current() : nil)
    }

    private static func readPreview(_ fileURL: URL, options: STLPreviewOptions?) -> ModelPreviewImage? {
        guard !Task.isCancelled else { return nil }
        let type = fileURL.pathExtension.lowercased()
        let start = Date()
        AppLog.write(.debug, .preview, "开始读取 \(type.uppercased()) 预览", detail: "文件：\(fileURL.lastPathComponent)")
        do {
            let preview: ModelPreviewImage?
            switch type {
            case "stl":
                preview = ModelPreviewImage(imageData: try STLPreview.imageData(from: fileURL, options: options ?? .current()),
                                            plateCount: 0, fileExtension: "png")
            case "obj":
                preview = ModelPreviewImage(imageData: try OBJPreview.imageData(from: fileURL), plateCount: 0, fileExtension: "png")
            case "3mf": preview = readEmbedded(fileURL)
            default: return nil
            }
            try Task.checkCancellation()
            AppLog.write(preview == nil ? .warning : .info, .preview,
                         preview == nil ? "\(type.uppercased()) 没有可用预览" : "\(type.uppercased()) 预览已生成",
                         detail: "文件：\(fileURL.lastPathComponent)；耗时：\(Int(Date().timeIntervalSince(start) * 1_000)) ms"
                            + (preview == nil ? "；包内图片不存在、包已损坏或超出预览限制。" : ""))
            return preview
        } catch is CancellationError {
            AppLog.write(.debug, .preview, "预览已取消", detail: fileURL.lastPathComponent)
        } catch {
            AppLog.write(.error, .preview, "\(type.uppercased()) 预览失败",
                         detail: "文件：\(fileURL.lastPathComponent)；耗时：\(Int(Date().timeIntervalSince(start) * 1_000)) ms\n\(AppLog.errorDescription(error))")
        }
        return nil
    }

    private static func readEmbedded(_ fileURL: URL) -> ModelPreviewImage? {
        guard !Task.isCancelled else { return nil }
        let accessing = fileURL.startAccessingSecurityScopedResource()
        defer { if accessing { fileURL.stopAccessingSecurityScopedResource() } }
        guard let archive = try? PreviewArchive(fileURL) else { return nil }
        defer { archive.close() }
        let entries = ZipCatalog.entries(in: archive)
        guard let picked = ZipCatalog.preview(in: entries),
              let bytes = ZipCatalog.extract(picked.entry, from: archive),
              !Task.isCancelled,
              bytes.count > 8 else { return nil }
        let ext = (picked.entry.name as NSString).pathExtension.lowercased()
        return ModelPreviewImage(imageData: bytes, plateCount: picked.plateCount, fileExtension: ext)
    }

    private static func make(_ fileURL: URL, key: String, options: STLPreviewOptions?, retry: Bool) -> ModelFileThumb? {
        // 大 STL 在应用重启后优先复用同参数、同文件版本的磁盘缩略图，避免重复扫描。
        if !retry, options != nil,
           let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let existingURL = root.appendingPathComponent("MakerShelf/FilePreviews-v1/\(key).png")
            if let cached = try? existingURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
               (cached.fileSize ?? 0) > 0,
               let sourceDate = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               let cacheDate = cached.contentModificationDate,
               cacheDate >= sourceDate {
                AppLog.write(.debug, .preview, "STL 预览命中磁盘缓存",
                             detail: "文件：\(fileURL.lastPathComponent)；设置：\(options?.cacheKey ?? "")")
                return ModelFileThumb(imageURL: existingURL, plateCount: 0)
            }
        }
        guard let embedded = readPreview(fileURL, options: options) else { return nil }
        let bytes = embedded.imageData

        guard let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            AppLog.write(.error, .preview, "无法定位预览缓存目录", detail: fileURL.lastPathComponent)
            return nil
        }
        let cacheDir = root.appendingPathComponent("MakerShelf/FilePreviews-v1", isDirectory: true)
        let ext = embedded.fileExtension
        let suffix = ["png", "jpg", "jpeg", "webp"].contains(ext) ? ext : "png"
        // 完整路径、文件版本和归档版本共同标识缓存，避免同名文件冲突及编辑后沿用旧图。
        let name = key + "." + suffix
        let dest = cacheDir.appendingPathComponent(name)
        if !retry, let existing = try? dest.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
           (existing.fileSize ?? 0) > 0,
           let sourceDate = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           let cacheDate = existing.contentModificationDate,
           cacheDate >= sourceDate {
            return ModelFileThumb(imageURL: dest, plateCount: embedded.plateCount)
        }
        do {
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            try bytes.write(to: dest, options: .atomic)
            // 仅清理应用自有缓存目录；限制磁盘条目，避免浏览大量模型后持续累积。
            let files = (try? FileManager.default.contentsOfDirectory(at: cacheDir,
                includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            if files.count > 128 {
                let oldest = files.filter { $0 != dest }.sorted {
                    ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                        < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                }
                for file in oldest.prefix(files.count - 128) { try? FileManager.default.removeItem(at: file) }
            }
        } catch {
            if !Task.isCancelled { AppLog.write(.error, .preview, "预览缓存写入失败", detail: AppLog.errorDescription(error)) }
            return nil
        }
        return ModelFileThumb(imageURL: dest, plateCount: embedded.plateCount)
    }
}

/// 按范围读取 ZIP，避免将数 GB 的 3MF 整包加载或映射进内存。
private final class PreviewArchive {
    let size: Int
    private let handle: FileHandle

    init(_ url: URL) throws {
        let reader = try FileHandle(forReadingFrom: url)
        do {
            guard let length = Int(exactly: try reader.seekToEnd()) else { throw ShelfError.invalidImage }
            handle = reader
            size = length
        } catch { try? reader.close(); throw error }
    }

    func close() { try? handle.close() }

    func read(at offset: Int, count: Int) -> Data? {
        guard !Task.isCancelled, offset >= 0, count >= 0, offset <= size, count <= size - offset else { return nil }
        do {
            try handle.seek(toOffset: UInt64(offset))
            guard let data = try handle.read(upToCount: count), data.count == count else { return nil }
            return data
        } catch { return nil }
    }
}

private enum ZipCatalog {
    private static let maxPreviewBytes = 16 * 1_024 * 1_024
    struct Entry {
        var name: String
        var method: UInt16
        var compressedSize: Int
        var uncompressedSize: Int
        var localOffset: Int
        var flags: UInt16
        var checksum: UInt32
        var payloadLimit: Int
    }

    struct Preview {
        var entry: Entry
        var plateCount: Int
    }

    static func entries(in archive: PreviewArchive) -> [Entry] {
        let tailOffset = max(0, archive.size - 65_557)
        guard let tail = archive.read(at: tailOffset, count: archive.size - tailOffset),
              let eocd = endOfCentralDirectory(tail) else { return [] }
        let count = Int(u16(tail, eocd + 10))
        let cdSize = u32(tail, eocd + 12)
        let cdOffset = u32(tail, eocd + 16)
        // 预览仅支持普通单卷 ZIP；ZIP64、加密及过大的目录不提供文件预览。
        guard u16(tail, eocd + 4) == 0, u16(tail, eocd + 6) == 0,
              Int(u16(tail, eocd + 8)) == count, count < 65_535,
              cdSize > 0, cdSize <= 8 * 1_024 * 1_024,
              cdOffset >= 0, cdOffset + cdSize <= tailOffset + eocd,
              let data = archive.read(at: cdOffset, count: cdSize) else { return [] }
        var result: [Entry] = []
        var cursor = 0
        for _ in 0..<count {
            guard !Task.isCancelled, cursor + 46 <= data.count, u32(data, cursor) == 0x02014b50 else { return [] }
            let method = u16(data, cursor + 10)
            let compressed = u32(data, cursor + 20)
            let uncompressed = u32(data, cursor + 24)
            let nameLength = Int(u16(data, cursor + 28))
            let extraLength = Int(u16(data, cursor + 30))
            let commentLength = Int(u16(data, cursor + 32))
            let local = u32(data, cursor + 42)
            let nameStart = cursor + 46
            let nameEnd = nameStart + nameLength
            guard nameEnd + extraLength + commentLength <= data.count,
                  compressed >= 0, uncompressed >= 0, local >= 0,
                  local < cdOffset, u16(data, cursor + 34) == 0 else { return [] }
            let name = String(data: data.subdata(in: nameStart..<nameEnd), encoding: .utf8) ?? ""
            result.append(Entry(name: name, method: method, compressedSize: compressed,
                                uncompressedSize: uncompressed, localOffset: local,
                                flags: u16(data, cursor + 8), checksum: UInt32(u32(data, cursor + 16)),
                                payloadLimit: cdOffset))
            cursor = nameEnd + extraLength + commentLength
        }
        return result
    }

    static func preview(in entries: [Entry]) -> Preview? {
        let entries = entries.filter { $0.flags & 1 == 0 && [0, 8].contains($0.method)
            && $0.compressedSize > 0 && $0.compressedSize <= maxPreviewBytes
            && $0.uncompressedSize > 0 && $0.uncompressedSize <= maxPreviewBytes }
        let plates = entries.filter { isPlatePreview($0.name) }
            .sorted { (plateNumber($0.name) ?? 0) < (plateNumber($1.name) ?? 0) }
        let numbers = Set(plates.compactMap { plateNumber($0.name) })
        let plateCount = numbers.count
        if let plate = plates.first(where: { plateNumber($0.name) == 1 }) ?? plates.first {
            return Preview(entry: plate, plateCount: max(plateCount, 1))
        }
        let fallback = entries.first { entry in
            let name = normalized(entry.name)
            return name.hasSuffix("auxiliaries/.thumbnails/thumbnail_small.png")
                || name.hasSuffix("auxiliaries/.thumbnails/thumbnail_3mf.png")
                || name.hasSuffix("/.thumbnails/thumbnail.png")
        }
        if let fallback { return Preview(entry: fallback, plateCount: plateCount) }
        return nil
    }

    static func extract(_ entry: Entry, from archive: PreviewArchive) -> Data? {
        let local = entry.localOffset
        guard entry.compressedSize <= maxPreviewBytes, entry.uncompressedSize <= maxPreviewBytes,
              let header = archive.read(at: local, count: 30), u32(header, 0) == 0x04034b50,
              u16(header, 6) == entry.flags, entry.flags & 1 == 0,
              u16(header, 8) == entry.method else { return nil }
        let nameLength = Int(u16(header, 26))
        let extraLength = Int(u16(header, 28))
        let start = local + 30 + nameLength + extraLength
        guard start + entry.compressedSize <= entry.payloadLimit,
              let name = archive.read(at: local + 30, count: nameLength),
              String(data: name, encoding: .utf8) == entry.name,
              let payload = archive.read(at: start, count: entry.compressedSize) else { return nil }
        let output: Data
        if entry.method == 0 { output = payload }
        else if entry.method == 8, let inflated = inflateRaw(payload, size: entry.uncompressedSize) { output = inflated }
        else { return nil }
        guard output.count == entry.uncompressedSize else { return nil }
        let checksum = output.withUnsafeBytes { raw in
            crc32(0, raw.bindMemory(to: Bytef.self).baseAddress, uInt(raw.count))
        }
        return UInt32(checksum) == entry.checksum ? output : nil
    }

    private static func isPlatePreview(_ name: String) -> Bool {
        let value = normalized(name)
        return value.hasPrefix("metadata/plate_") && plateNumber(value) != nil
    }

    private static func plateNumber(_ name: String) -> Int? {
        let value = normalized(name)
        guard let range = value.range(of: #"plate_(\d+)\.png$"#, options: .regularExpression) else { return nil }
        let digits = value[range].dropFirst("plate_".count).dropLast(".png".count)
        return Int(digits)
    }

    private static func normalized(_ name: String) -> String {
        name.replacingOccurrences(of: "\\", with: "/").lowercased()
    }

    private static func inflateRaw(_ payload: Data, size: Int) -> Data? {
        var stream = z_stream()
        guard inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&stream) }
        var output = Data(count: size)
        let status: Int32 = payload.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(source.count)
                stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(destination.count)
                return zlib.inflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END, stream.total_out == uLong(size), stream.avail_in == 0 else { return nil }
        return output
    }

    private static func endOfCentralDirectory(_ data: Data) -> Int? {
        let start = max(0, data.count - 66_000)
        var index = data.count - 22
        while index >= start {
            if u32(data, index) == 0x06054b50, index + 22 + Int(u16(data, index + 20)) == data.count { return index }
            index -= 1
        }
        return nil
    }

    private static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 1 < data.count else { return 0 }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func u32(_ data: Data, _ offset: Int) -> Int {
        guard offset >= 0, offset + 3 < data.count else { return -1 }
        let value = UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
        return Int(value)
    }
}
