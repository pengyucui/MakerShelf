import Foundation

struct ArchiveRecoveryScan: Sendable {
    var records: [ModelRecord] = []
    var metadataCount = 0
    var legacyIDs: Set<String> = []
    var warningCount = 0
    var warnings: [String] = []

    mutating func warn(_ message: String) {
        warningCount += 1
        // 页面只保留有限详情；总数单独统计，避免损坏目录使提示无限增长。
        if warnings.count < 50 { warnings.append(message) }
        AppLog.write(.warning, .storage, "归档恢复提示", detail: message)
    }
}

struct ArchiveRecoveryResult: Sendable {
    var added: Int
    var updated: Int
    var unchanged: Int
    var backupName: String?
}

/// 只读取已有 MakerShelf 归档；恢复时不复制模型、不修改 metadata.json，也不访问原归档以外的路径。
actor ArchiveRecoveryScanner {
    private let modelExtensions: Set<String> = ["3mf", "stl", "obj", "step", "stp", "gcode", "amf"]
    private let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "webp", "tiff", "tif", "gif"]
    private let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                                                   .isPackageKey, .fileSizeKey, .contentModificationDateKey]
    private let maxDocumentBytes = 8 * 1_024 * 1_024

    enum Failure: LocalizedError {
        case unreadable, selectParent, scanLimit, documentLimit
        var errorDescription: String? {
            switch self {
            case .unreadable: return "无法读取归档目录，请重新选择并授权原来的模型归档总目录。"
            case .selectParent: return "当前选择的是单个模型目录，请选择包含这些模型的归档总目录后恢复。"
            case .scanLimit: return "目录超过恢复扫描限制（20 万个条目、1 万份模型资料或 64 层目录），请确认选择的是模型归档总目录。"
            case .documentLimit: return "模型资料与介绍累计超过 128 MiB，已停止扫描；未改动当前模型库，请检查归档中的异常大文档。"
            }
        }
    }

    func scan(root selectedRoot: URL) throws -> ArchiveRecoveryScan {
        let accessing = selectedRoot.startAccessingSecurityScopedResource()
        defer { if accessing { selectedRoot.stopAccessingSecurityScopedResource() } }
        let root = selectedRoot.standardizedFileURL.resolvingSymlinksInPath()
        let manager = FileManager.default
        guard (try root.resourceValues(forKeys: resourceKeys)).isDirectory == true else { throw Failure.unreadable }
        // 单个模型根目录无法安全作为后续编辑的归档总目录，因此明确要求选择上层。
        if manager.fileExists(atPath: root.appendingPathComponent("metadata.json").path) { throw Failure.selectParent }
        var report = ArchiveRecoveryScan()
        var metadata: [URL] = []
        guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: Array(resourceKeys),
                                                 options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                                 errorHandler: { url, error in
            report.warn("无法读取 \(url.lastPathComponent)：\(error.localizedDescription)")
            return true
        }) else { throw Failure.unreadable }
        var visited = 0
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            visited += 1
            guard visited <= 200_000, enumerator.level <= 64 else { throw Failure.scanLimit }
            let values: URLResourceValues
            do { values = try url.resourceValues(forKeys: resourceKeys) }
            catch { report.warn("无法检查 \(url.lastPathComponent)：\(error.localizedDescription)"); continue }
            if values.isSymbolicLink == true || values.isPackage == true {
                enumerator.skipDescendants()
                continue
            }
            if values.isRegularFile == true, url.lastPathComponent == "metadata.json" {
                metadata.append(url)
                guard metadata.count <= 10_000 else { throw Failure.scanLimit }
            }
        }
        // 路径排序让恢复顺序稳定；重复 ID 的多份目录全部跳过，不依赖磁盘遍历顺序覆盖其中一份。
        var recordsByID: [String: ModelRecord] = [:]
        var duplicates: Set<String> = []
        var documentBudget = 128 * 1_024 * 1_024
        for url in metadata.sorted(by: { $0.path < $1.path }) {
            try Task.checkCancellation()
            report.metadataCount += 1
            do {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let data = try readDocument(url, budget: &documentBudget)
                let record: ModelRecord
                // 站点下载的早期归档只保存精简字段，不能直接当作完整 ModelRecord 解码。
                // 完整格式字段存在时仍严格解码，避免把损坏的新格式误当旧版而静默丢失资料。
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                if object?["subtitle"] == nil, object?["origin"] == nil {
                    record = try decoder.decode(LegacyMetadata.self, from: data).record
                    report.legacyIDs.insert(record.id)
                } else {
                    record = try decoder.decode(ModelRecord.self, from: data)
                }
                guard !record.id.isEmpty, !record.isDemo else {
                    report.warn("跳过 \(url.deletingLastPathComponent().lastPathComponent)：缺少模型 ID 或属于示例资料。")
                    continue
                }
                let restored = try restore(record, folder: url.deletingLastPathComponent(), root: root,
                                           report: &report, documentBudget: &documentBudget)
                if duplicates.contains(record.id) { continue }
                if recordsByID[record.id] != nil {
                    recordsByID[record.id] = nil
                    duplicates.insert(record.id)
                    report.warn("模型“\(record.title)”存在多份相同 ID 的归档，本次跳过，请整理重复目录后再恢复。")
                } else { recordsByID[record.id] = restored }
            } catch is CancellationError { throw CancellationError() }
            catch Failure.documentLimit { throw Failure.documentLimit }
            catch {
                report.warn("跳过 \(PathSafety.relative(from: url.deletingLastPathComponent(), toRoot: root))：\(error.localizedDescription)")
            }
        }
        report.records = recordsByID.values.sorted {
            $0.sortIndex == $1.sortIndex ? $0.id < $1.id : $0.sortIndex < $1.sortIndex
        }
        report.legacyIDs.formIntersection(Set(report.records.map(\.id)))
        if !report.legacyIDs.isEmpty {
            report.warn("已读取 \(report.legacyIDs.count) 份旧版站点资料：优先保留现有模型库中的分类等信息；原索引丢失且归档从未保存的资料使用默认值，介绍从原文件恢复。")
        }
        return report
    }

    private func restore(_ original: ModelRecord, folder: URL, root: URL,
                         report: inout ArchiveRecoveryScan, documentBudget: inout Int) throws -> ModelRecord {
        var record = original
        // MakerShelf 自有归档的 models / images 为平铺结构，以真实文件为准重建相对路径。
        // 不使用旧电脑的绝对路径，也不将 metadata 中的路径直接拼接到文件系统。
        let modelFiles = try files(in: folder.appendingPathComponent("models"), allowed: modelExtensions,
                                  expectedNames: Set(original.files.map(\.name)))
        guard !modelFiles.isEmpty else { throw LocalModelImportError.missingModelFile }
        var oldFiles: [String: ModelFile] = [:]
        for file in original.files where oldFiles[file.name] == nil { oldFiles[file.name] = file }
        record.files = try modelFiles.map { url in
            try Task.checkCancellation()
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            let suffix = url.pathExtension.lowercased()
            // 旧归档的长文件名可能被截断而丢失扩展名；已登记文件保留原格式信息。
            let kind = modelExtensions.contains(suffix) ? suffix : (oldFiles[url.lastPathComponent]?.kind ?? suffix)
            return ModelFile(id: oldFiles[url.lastPathComponent]?.id ?? "recovered:\(url.lastPathComponent)",
                             name: url.lastPathComponent, kind: kind, sizeBytes: size,
                             relativePath: PathSafety.relative(from: url, toRoot: root), remoteHint: nil)
        }
        let actualNames = Set(record.files.map(\.name))
        let missing = original.files.filter { !actualNames.contains($0.name) }.count
        if missing > 0 { report.warn("“\(original.title)”缺少 \(missing) 个原模型文件，已恢复仍然存在的文件。") }
        var images: [URL] = []
        do { images = try files(in: folder.appendingPathComponent("images"), allowed: imageExtensions) }
        catch is CancellationError { throw CancellationError() }
        catch { report.warn("“\(original.title)”的展示图片未能读取：\(error.localizedDescription)") }
        let imagesByName = Dictionary(uniqueKeysWithValues: images.map { ($0.lastPathComponent, $0) })
        var orderedImages: [URL] = []
        var seen: Set<String> = []
        for path in [original.localCoverPath].compactMap({ $0 }) + original.localImagePaths {
            let name = (path as NSString).lastPathComponent
            if let image = imagesByName[name], seen.insert(name).inserted { orderedImages.append(image) }
        }
        for image in images where seen.insert(image.lastPathComponent).inserted { orderedImages.append(image) }
        record.localImagePaths = orderedImages.map { PathSafety.relative(from: $0, toRoot: root) }
        record.localCoverPath = record.localImagePaths.first
        record.archiveFolder = PathSafety.relative(from: folder, toRoot: root)
        record.fileCount = record.files.count
        record.sizeMB = record.files.reduce(0.0) { $0 + Double($1.sizeBytes) } / 1_048_576
        record.isDownloaded = true
        if record.archivedAt == nil {
            record.archivedAt = try folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }
        let description = folder.appendingPathComponent("description.html")
        if FileManager.default.fileExists(atPath: description.path) {
            do {
                let bytes = try readDocument(description, budget: &documentBudget)
                if let html = String(data: bytes, encoding: .utf8) { record.descriptionHTML = html }
                else { report.warn("“\(original.title)”的介绍不是 UTF-8，保留模型资料中的介绍。") }
            } catch is CancellationError { throw CancellationError() }
            catch Failure.documentLimit { throw Failure.documentLimit }
            catch { report.warn("“\(original.title)”的介绍未能读取，保留模型资料中的介绍。") }
        }
        return record
    }

    private func files(in directory: URL, allowed: Set<String>, expectedNames: Set<String> = []) throws -> [URL] {
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let info = try directory.resourceValues(forKeys: resourceKeys)
        guard info.isDirectory == true, info.isSymbolicLink != true else { throw Failure.unreadable }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(resourceKeys),
                                                           options: [.skipsHiddenFiles]).filter { url in
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: resourceKeys)
            return values.isRegularFile == true && values.isSymbolicLink != true
                && (allowed.contains(url.pathExtension.lowercased()) || expectedNames.contains(url.lastPathComponent))
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func readDocument(_ url: URL, budget: inout Int) throws -> Data {
        try Task.checkCancellation()
        let values = try url.resourceValues(forKeys: resourceKeys)
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= maxDocumentBytes else { throw Failure.unreadable }
        guard size <= budget else { throw Failure.documentLimit }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maxDocumentBytes + 1) ?? Data()
        guard data.count <= maxDocumentBytes else { throw Failure.unreadable }
        guard data.count <= budget else { throw Failure.documentLimit }
        budget -= data.count
        return data
    }

    /// 兼容 2.0 及以前站点下载器写出的 name / kind / path 精简清单。
    private struct LegacyMetadata: Decodable {
        struct File: Decodable {
            let name: String
            let kind: String
            let path: String?
        }
        let id: String
        let title: String
        let author: String
        let site: MakerSite
        let designId: Int?
        let modelId: String?
        let authorId: String?
        let sourceURL: String?
        let license: String?
        let archivedAt: Date?
        let files: [File]

        var record: ModelRecord {
            ModelRecord(id: id, title: title, subtitle: "", author: author, imageName: "", category: "其他",
                        site: site, origin: .makerWorld, sizeMB: 0, fileCount: files.count, isDownloaded: true,
                        backgroundHex: "E9EEE8", summary: "", material: "未填写", printTime: "未填写",
                        sortIndex: archivedAt.map { -Int($0.timeIntervalSince1970) } ?? 0,
                        designId: designId, modelId: modelId, authorId: authorId, sourceURL: sourceURL,
                        license: license, files: files.map {
                            ModelFile(id: "recovered:\($0.name)", name: $0.name, kind: $0.kind,
                                      sizeBytes: 0, relativePath: $0.path, remoteHint: nil)
                        }, archivedAt: archivedAt)
        }
    }
}
