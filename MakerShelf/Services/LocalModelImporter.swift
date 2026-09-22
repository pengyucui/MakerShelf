import Foundation

/// 将用户选择的本地文件复制到统一归档目录。所有磁盘操作都在 actor 内串行执行，
/// 避免多个创建任务同时写入同一目录或阻塞 SwiftUI 主线程。
actor LocalModelImporter {
    private let modelExtensions: Set<String> = ["3mf", "stl", "obj", "step", "stp", "gcode", "amf"]
    private let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "webp", "tiff", "tif", "gif"]

    func importModel(_ draft: LocalModelDraft, archiveRoot: URL) throws -> ModelRecord {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw LocalModelImportError.missingTitle }
        guard !draft.modelFiles.isEmpty else { throw LocalModelImportError.missingModelFile }

        let identifier = UUID().uuidString.lowercased()
        let folderName = "\(PathSafety.component(title))_\(identifier.prefix(8))"
        let localRoot = archiveRoot.appendingPathComponent("本地模型", isDirectory: true)
        let finalFolder = localRoot.appendingPathComponent(folderName, isDirectory: true)
        let stagingFolder = archiveRoot.appendingPathComponent(".makershelf-import-\(identifier)", isDirectory: true)
        let modelsFolder = stagingFolder.appendingPathComponent("models", isDirectory: true)
        let imagesFolder = stagingFolder.appendingPathComponent("images", isDirectory: true)

        let manager = FileManager.default
        try manager.createDirectory(at: localRoot, withIntermediateDirectories: true)
        try manager.createDirectory(at: modelsFolder, withIntermediateDirectories: true)
        try manager.createDirectory(at: imagesFolder, withIntermediateDirectories: true)

        do {
            let copiedModels = try copyFiles(draft.modelFiles, allowedExtensions: modelExtensions,
                                             destination: modelsFolder, finalFolder: finalFolder,
                                             archiveRoot: archiveRoot)
            let copiedImages = try copyFiles(draft.imageFiles, allowedExtensions: imageExtensions,
                                             destination: imagesFolder, finalFolder: finalFolder,
                                             archiveRoot: archiveRoot)
            try Task.checkCancellation()
            let totalBytes = copiedModels.reduce(0) { $0 + $1.sizeBytes }
            let archivePath = PathSafety.relative(from: finalFolder, toRoot: archiveRoot)
            let imagePaths = copiedImages.compactMap(\.relativePath)
            let summary = draft.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            let record = ModelRecord(
                id: "local:\(identifier)",
                title: title,
                subtitle: valueOrDefault(draft.subtitle, default: "我的本地创作"),
                author: valueOrDefault(draft.author, default: "我"),
                imageName: "",
                category: valueOrDefault(draft.category, default: "其他"),
                site: .china,
                origin: .local,
                sizeMB: Double(totalBytes) / 1_048_576,
                fileCount: copiedModels.count,
                isDownloaded: true,
                backgroundHex: "E9EEE8",
                summary: summary,
                material: valueOrDefault(draft.material, default: "未填写"),
                printTime: valueOrDefault(draft.printTime, default: "未填写"),
                sortIndex: -Int(Date().timeIntervalSince1970),
                localCoverPath: imagePaths.first,
                localImagePaths: imagePaths,
                license: "LOCAL",
                descriptionHTML: summary.isEmpty ? nil : Self.paragraphHTML(summary),
                archiveFolder: archivePath,
                files: copiedModels,
                archivedAt: Date()
            )

            let htmlURL = stagingFolder.appendingPathComponent("description.html")
            try Data(Self.descriptionDocument(title: title, summary: summary).utf8).write(to: htmlURL, options: .atomic)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(record).write(to: stagingFolder.appendingPathComponent("metadata.json"), options: .atomic)
            try Task.checkCancellation()
            try manager.moveItem(at: stagingFolder, to: finalFolder)
            return record
        } catch {
            // 仅清理本次创建的临时目录，不触碰用户原文件和既有归档。
            try? manager.removeItem(at: stagingFolder)
            throw error
        }
    }

    /// 在保持模型 ID、排序位置和归档路径不变的前提下更新已归档模型。
    /// 所有选中的旧文件与新增文件先复制到临时目录，完整写入成功后才替换旧归档。
    func updateModel(_ existing: ModelRecord, with draft: LocalModelDraft, archiveRoot: URL) throws -> ModelRecord {
        guard existing.canEditLocally else { throw LocalModelImportError.missingArchive }
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw LocalModelImportError.missingTitle }
        guard !draft.modelFiles.isEmpty else { throw LocalModelImportError.missingModelFile }
        guard let archivePath = existing.archiveFolder,
              let finalFolder = PathSafety.resolve(archivePath, archiveRoot: archiveRoot),
              FileManager.default.fileExists(atPath: finalFolder.path) else {
            throw LocalModelImportError.missingArchive
        }

        let operationID = UUID().uuidString.lowercased()
        let stagingFolder = archiveRoot.appendingPathComponent(".makershelf-edit-\(operationID)", isDirectory: true)
        let backupFolder = archiveRoot.appendingPathComponent(".makershelf-backup-\(operationID)", isDirectory: true)
        let modelsFolder = stagingFolder.appendingPathComponent("models", isDirectory: true)
        let imagesFolder = stagingFolder.appendingPathComponent("images", isDirectory: true)
        let manager = FileManager.default
        try manager.createDirectory(at: modelsFolder, withIntermediateDirectories: true)
        try manager.createDirectory(at: imagesFolder, withIntermediateDirectories: true)

        do {
            let copiedModels = try copyFiles(draft.modelFiles, allowedExtensions: modelExtensions,
                                             destination: modelsFolder, finalFolder: finalFolder,
                                             archiveRoot: archiveRoot)
            let copiedImages = try copyFiles(draft.imageFiles, allowedExtensions: imageExtensions,
                                             destination: imagesFolder, finalFolder: finalFolder,
                                             archiveRoot: archiveRoot)
            try Task.checkCancellation()

            let draftSummary = draft.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            let summaryUnchanged = draftSummary == existing.plainSummary
            let summary = summaryUnchanged ? existing.summary : draftSummary
            let descriptionHTML = summaryUnchanged
                ? existing.descriptionHTML
                : (draftSummary.isEmpty ? nil : Self.paragraphHTML(draftSummary))
            let imagePaths = copiedImages.compactMap(\.relativePath)
            let totalBytes = copiedModels.reduce(0) { $0 + $1.sizeBytes }
            let updated = ModelRecord(
                id: existing.id,
                title: title,
                subtitle: valueOrDefault(draft.subtitle, default: existing.isLocal ? "我的本地创作" : existing.subtitle),
                author: valueOrDefault(draft.author, default: existing.author),
                imageName: existing.imageName,
                category: valueOrDefault(draft.category, default: existing.category),
                site: existing.site,
                origin: existing.origin,
                sizeMB: Double(totalBytes) / 1_048_576,
                fileCount: copiedModels.count,
                isDownloaded: true,
                backgroundHex: existing.backgroundHex,
                summary: summary,
                material: valueOrDefault(draft.material, default: existing.material),
                printTime: valueOrDefault(draft.printTime, default: existing.printTime),
                sortIndex: existing.sortIndex,
                designId: existing.designId,
                modelId: existing.modelId,
                authorId: existing.authorId,
                authorHandle: existing.authorHandle,
                coverURL: existing.coverURL,
                localCoverPath: imagePaths.first,
                galleryURLs: existing.galleryURLs,
                localImagePaths: imagePaths,
                sourceURL: existing.sourceURL,
                license: existing.license ?? (existing.isLocal ? "LOCAL" : nil),
                descriptionHTML: descriptionHTML,
                archiveFolder: archivePath,
                files: copiedModels,
                archivedAt: Date(),
                warnings: existing.warnings,
                defaultInstanceId: existing.defaultInstanceId
            )

            try writeCompanionFiles(for: updated, title: title, summary: draftSummary, folder: stagingFolder,
                                    keepOriginalHTML: summaryUnchanged ? finalFolder.appendingPathComponent("description.html") : nil)
            try Task.checkCancellation()

            // 旧归档先改名为备份；若新归档移动失败，立即恢复，避免编辑失败后丢失文件。
            try manager.moveItem(at: finalFolder, to: backupFolder)
            do {
                try manager.moveItem(at: stagingFolder, to: finalFolder)
                try? manager.removeItem(at: backupFolder)
            } catch {
                try? manager.moveItem(at: backupFolder, to: finalFolder)
                throw error
            }
            return updated
        } catch {
            try? manager.removeItem(at: stagingFolder)
            // 只有新归档已经落位时备份才会被清理；异常路径优先恢复旧目录。
            if manager.fileExists(atPath: backupFolder.path), !manager.fileExists(atPath: finalFolder.path) {
                try? manager.moveItem(at: backupFolder, to: finalFolder)
            }
            throw error
        }
    }

    private func writeCompanionFiles(for record: ModelRecord, title: String, summary: String, folder: URL,
                                     keepOriginalHTML: URL? = nil) throws {
        let htmlURL = folder.appendingPathComponent("description.html")
        if let original = keepOriginalHTML, FileManager.default.fileExists(atPath: original.path) {
            try FileManager.default.copyItem(at: original, to: htmlURL)
        } else {
            try Data(Self.descriptionDocument(title: title, summary: summary).utf8)
                .write(to: htmlURL, options: .atomic)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: folder.appendingPathComponent("metadata.json"), options: .atomic)
    }

    private func copyFiles(_ sources: [URL], allowedExtensions: Set<String>, destination: URL,
                           finalFolder: URL, archiveRoot: URL) throws -> [ModelFile] {
        var usedNames: Set<String> = []
        var records: [ModelFile] = []
        for source in sources {
            try Task.checkCancellation()
            let ext = source.pathExtension.lowercased()
            guard allowedExtensions.contains(ext) else {
                throw LocalModelImportError.unsupportedFile(source.lastPathComponent)
            }
            let accessing = source.startAccessingSecurityScopedResource()
            defer { if accessing { source.stopAccessingSecurityScopedResource() } }
            let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { throw LocalModelImportError.invalidFile(source.lastPathComponent) }
            let fileName = uniqueName(for: source.lastPathComponent, usedNames: &usedNames)
            let target = destination.appendingPathComponent(fileName)
            try FileManager.default.copyItem(at: source, to: target)

            let relativeTarget = finalFolder
                .appendingPathComponent(destination.lastPathComponent, isDirectory: true)
                .appendingPathComponent(fileName)
            records.append(ModelFile(
                id: UUID().uuidString,
                name: fileName,
                kind: ext,
                sizeBytes: values.fileSize ?? 0,
                relativePath: PathSafety.relative(from: relativeTarget, toRoot: archiveRoot),
                remoteHint: nil
            ))
        }
        return records
    }

    private func uniqueName(for rawName: String, usedNames: inout Set<String>) -> String {
        let ext = (rawName as NSString).pathExtension
        let stem = PathSafety.component((rawName as NSString).deletingPathExtension)
        var candidate = ext.isEmpty ? stem : "\(stem).\(ext.lowercased())"
        var suffix = 2
        while usedNames.contains(candidate.lowercased()) {
            candidate = ext.isEmpty ? "\(stem)-\(suffix)" : "\(stem)-\(suffix).\(ext.lowercased())"
            suffix += 1
        }
        usedNames.insert(candidate.lowercased())
        return candidate
    }

    private func valueOrDefault(_ value: String, default fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private static func paragraphHTML(_ summary: String) -> String {
        summary
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { "<p>\(escapeHTML($0))</p>" }
            .joined(separator: "\n")
    }

    private static func descriptionDocument(title: String, summary: String) -> String {
        let safeTitle = escapeHTML(title)
        return "<!doctype html><html lang=\"zh-Hans\"><meta charset=\"utf-8\"><title>\(safeTitle)</title><body><h1>\(safeTitle)</h1>\(paragraphHTML(summary))</body></html>"
    }

    private static func escapeHTML(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

enum LocalModelImportError: LocalizedError {
    case missingTitle
    case missingModelFile
    case unsupportedFile(String)
    case invalidFile(String)
    case missingArchive

    var errorDescription: String? {
        switch self {
        case .missingTitle: return "请填写模型名称。"
        case .missingModelFile: return "请至少选择一个模型文件。"
        case .unsupportedFile(let name): return "不支持文件“\(name)”的格式。"
        case .invalidFile(let name): return "“\(name)”不是可读取的普通文件。"
        case .missingArchive: return "找不到这个模型的本地归档目录。"
        }
    }
}
