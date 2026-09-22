import Foundation
import Observation

@MainActor @Observable
final class LocalModelStore {
    var title = ""
    var subtitle = ""
    var author = "我"
    var category = "其他"
    var summary = ""
    var material = ""
    var printTime = ""
    private(set) var modelFiles: [URL] = []
    private(set) var imageFiles: [URL] = []
    private(set) var isSaving = false
    var errorMessage: String?
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init() {}

    /// 编辑时直接载入归档内已有文件。保存服务会将这些文件与新选择的文件一起写入新版归档，
    /// 因此用户可以调整顺序、删除旧文件或继续追加文件。
    init(existing model: ModelRecord, archiveRoot: URL?) {
        title = model.title
        subtitle = model.subtitle
        author = model.author
        category = model.category
        summary = model.plainSummary
        material = model.material == "未填写" ? "" : model.material
        printTime = model.printTime == "未填写" ? "" : model.printTime
        let loaded = Self.loadArchivedFiles(model: model, archiveRoot: archiveRoot)
        modelFiles = loaded.models
        imageFiles = loaded.images
    }

    var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !modelFiles.isEmpty && !isSaving
    }

    var draft: LocalModelDraft {
        LocalModelDraft(title: title, subtitle: subtitle, author: author, category: category,
                        summary: summary, material: material, printTime: printTime,
                        modelFiles: modelFiles, imageFiles: imageFiles)
    }

    /// 文件选择与拖放都汇入同一个入口，校验规则不会散落在视图中。
    func addModelFiles(_ urls: [URL]) { appendModelFiles(urls) }

    func addImages(_ urls: [URL]) { appendImages(urls) }

    func reportSelectionError(_ error: Error) {
        errorMessage = "无法读取所选文件：\(error.localizedDescription)"
    }

    func removeModelFile(_ url: URL) { modelFiles.removeAll { $0.standardizedFileURL == url.standardizedFileURL } }
    func removeImage(_ url: URL) { imageFiles.removeAll { $0.standardizedFileURL == url.standardizedFileURL } }

    func setCover(_ url: URL) {
        guard let index = imageFiles.firstIndex(where: { $0.standardizedFileURL == url.standardizedFileURL }), index > 0 else { return }
        imageFiles.insert(imageFiles.remove(at: index), at: 0)
    }

    func save(using action: @escaping @MainActor (LocalModelDraft) async throws -> Void) {
        guard canSave else {
            errorMessage = modelFiles.isEmpty ? "请至少选择一个模型文件。" : "请填写模型名称。"
            return
        }
        isSaving = true
        errorMessage = nil
        let snapshot = draft
        saveTask = Task { [weak self] in
            defer {
                self?.isSaving = false
                self?.saveTask = nil
            }
            do {
                try await action(snapshot)
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    func cancelSave() {
        saveTask?.cancel()
        saveTask = nil
    }

    private func appendModelFiles(_ urls: [URL]) {
        let allowed: Set<String> = ["3mf", "stl", "obj", "step", "stp", "gcode", "amf"]
        let accepted = urls.filter { allowed.contains($0.pathExtension.lowercased()) }
        Self.appendUnique(accepted, to: &modelFiles)
        errorMessage = accepted.count == urls.count ? nil : "已忽略不支持的文件；支持 3MF、STL、OBJ、STEP、STP、GCODE 和 AMF。"
        if title.isEmpty, let first = accepted.first {
            title = first.deletingPathExtension().lastPathComponent
        }
    }

    private func appendImages(_ urls: [URL]) {
        Self.appendUnique(urls, to: &imageFiles)
        errorMessage = nil
    }

    private static func appendUnique(_ additions: [URL], to values: inout [URL]) {
        var known = Set(values.map { $0.standardizedFileURL.path })
        for url in additions where known.insert(url.standardizedFileURL.path).inserted {
            values.append(url)
        }
    }

    private static func loadArchivedFiles(model: ModelRecord, archiveRoot: URL?) -> (models: [URL], images: [URL]) {
        let manager = FileManager.default
        func existing(_ urls: [URL]) -> [URL] {
            urls.filter { manager.fileExists(atPath: $0.path) }
        }
        var models = existing(model.files.compactMap { file in
            file.relativePath.flatMap { PathSafety.resolve($0, archiveRoot: archiveRoot) }
        })
        var images = existing(model.localImagePaths.compactMap { PathSafety.resolve($0, archiveRoot: archiveRoot) })
        if let folder = model.archiveFolder.flatMap({ PathSafety.resolve($0, archiveRoot: archiveRoot) }) {
            if models.isEmpty {
                models = listedFiles(in: folder.appendingPathComponent("models", isDirectory: true),
                                     extensions: ["3mf", "stl", "obj", "step", "stp", "gcode", "amf"])
            }
            if images.isEmpty {
                images = listedFiles(in: folder.appendingPathComponent("images", isDirectory: true),
                                     extensions: ["png", "jpg", "jpeg", "heic", "webp", "tiff", "tif", "gif"])
            }
        }
        return (models, images)
    }

    private static func listedFiles(in folder: URL, extensions: Set<String>) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return urls
            .filter { extensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}
