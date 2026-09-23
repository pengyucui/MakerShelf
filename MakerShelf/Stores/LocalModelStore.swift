import Foundation
import Observation

struct CoverSuggestion: Identifiable, Sendable {
    let id: String
    let fileName: String
    let plateCount: Int
    let imageURL: URL
    let previewLabel: String
}

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
    var showsCoverPrompt = false
    var coverSuggestionQuery = ""
    var selectedCoverSuggestionID: String?
    private(set) var coverSuggestions: [CoverSuggestion] = []
    @ObservationIgnored private var coverTask: Task<Void, Never>?
    @ObservationIgnored private var coverGeneration = 0
    @ObservationIgnored private var temporaryCovers: Set<URL> = []

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

    func removeModelFile(_ url: URL) {
        modelFiles.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        coverSuggestions.removeAll { $0.id == url.standardizedFileURL.path }
    }
    func removeImage(_ url: URL) {
        imageFiles.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        cleanupTemporaryCovers()
    }

    func setCover(_ url: URL) {
        guard let index = imageFiles.firstIndex(where: { $0.standardizedFileURL == url.standardizedFileURL }), index > 0 else { return }
        imageFiles.insert(imageFiles.remove(at: index), at: 0)
    }

    private func useAsCover(_ url: URL) {
        imageFiles.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        imageFiles.insert(url, at: 0)
    }

    var visibleCoverSuggestions: [CoverSuggestion] {
        let query = coverSuggestionQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelIDs = Set(modelFiles.map { $0.standardizedFileURL.path })
        return coverSuggestions.filter { item in
            modelIDs.contains(item.id)
                && (query.isEmpty || item.fileName.localizedStandardContains(query))
        }
    }

    /// 只允许采用当前可见候选，防止搜索过滤后仍确认之前隐藏的选中项。
    func acceptCoverSuggestion() {
        guard !isSaving,
              let selected = visibleCoverSuggestions.first(where: { $0.id == selectedCoverSuggestionID }) else { return }
        useAsCover(selected.imageURL)
        showsCoverPrompt = false
    }

    func dismissCoverSuggestions() {
        coverGeneration += 1
        coverTask?.cancel()
        coverTask = nil
        showsCoverPrompt = false
        coverSuggestions = []
        selectedCoverSuggestionID = nil
        cleanupTemporaryCovers()
    }

    /// 保存前保留用户选择的临时封面；其余候选只归当前表单所有，不清理用户提供的文件。
    private func cleanupTemporaryCovers(all: Bool = false) {
        guard !isSaving else { return }
        let removable = temporaryCovers.filter { all || !imageFiles.contains($0) }
        for url in removable {
            try? FileManager.default.removeItem(at: url)
            temporaryCovers.remove(url)
        }
    }

    private func requestCoverSuggestions(_ urls: [URL]) {
        dismissCoverSuggestions()
        let generation = coverGeneration
        let candidates = urls.filter { ["3mf", "stl", "obj"].contains($0.pathExtension.lowercased()) }
        guard !candidates.isEmpty else { return }
        coverTask = Task { [weak self] in
            var found: [CoverSuggestion] = []
            // 被取消或表单已经关闭时，连同刚编码完成的候选一起回收。
            defer {
                if Task.isCancelled || self?.coverGeneration != generation {
                    for item in found { try? FileManager.default.removeItem(at: item.imageURL) }
                }
            }
            for url in candidates {
                guard !Task.isCancelled else { return }
                guard let preview = await ModelFilePreviewStore.shared.coverPreview(for: url) else { continue }
                do {
                    let encoded = try await DisplayImageEncoder.shared.compress(data: preview.imageData)
                    try Task.checkCancellation()
                    let destination = FileManager.default.temporaryDirectory
                        .appendingPathComponent("makershelf-cover-\(UUID().uuidString).webp")
                    let saved = try encoded.write(to: destination)
                    found.append(CoverSuggestion(id: url.standardizedFileURL.path, fileName: url.lastPathComponent,
                                                 plateCount: preview.plateCount, imageURL: saved,
                                                 previewLabel: url.pathExtension.lowercased() == "3mf"
                                                     ? "3MF 包内预览" : "\(url.pathExtension.uppercased()) 几何预览"))
                } catch {
                    if Task.isCancelled { return }
                    AppLog.write(.warning, .image, "封面候选生成失败", detail: "\(url.lastPathComponent)\n\(AppLog.errorDescription(error))")
                }
            }
            guard !Task.isCancelled, let self, self.coverGeneration == generation else { return }
            self.temporaryCovers.formUnion(found.map(\.imageURL))
            let modelIDs = Set(self.modelFiles.map { $0.standardizedFileURL.path })
            self.coverSuggestions = found.filter { modelIDs.contains($0.id) }
            self.coverSuggestionQuery = ""
            self.selectedCoverSuggestionID = self.coverSuggestions.first?.id
            self.showsCoverPrompt = !self.coverSuggestions.isEmpty
            self.coverTask = nil
            if self.coverSuggestions.isEmpty { self.cleanupTemporaryCovers() }
        }
    }

    func save(using action: @escaping @MainActor (LocalModelDraft) async throws -> Void) {
        guard canSave else {
            errorMessage = modelFiles.isEmpty ? "请至少选择一个模型文件。" : "请填写模型名称。"
            return
        }
        isSaving = true
        // 保存快照已经确定，不再允许后台候选任务弹窗或修改封面。
        dismissCoverSuggestions()
        errorMessage = nil
        let snapshot = draft
        AppLog.write(.info, .importing, "开始保存本地模型", detail: "模型文件：\(snapshot.modelFiles.count)；图片：\(snapshot.imageFiles.count)")
        // 保存任务保留表单到复制退出，关闭窗口后也能回收临时封面，不会提前删掉正在读取的文件。
        saveTask = Task { [self] in
            var saved = false
            defer {
                isSaving = false
                saveTask = nil
                cleanupTemporaryCovers(all: saved || Task.isCancelled)
            }
            do {
                try await action(snapshot)
                saved = true
                AppLog.write(.info, .importing, "本地模型保存完成")
            } catch is CancellationError {
                AppLog.write(.info, .importing, "本地模型保存已取消")
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                AppLog.write(.error, .importing, "本地模型保存失败", detail: AppLog.errorDescription(error))
            }
        }
    }

    func cancelSave() {
        dismissCoverSuggestions()
        saveTask?.cancel()
        if saveTask == nil { cleanupTemporaryCovers(all: true) }
    }

    private func appendModelFiles(_ urls: [URL]) {
        let allowed: Set<String> = ["3mf", "stl", "obj", "step", "stp", "gcode", "amf"]
        let accepted = urls.filter { allowed.contains($0.pathExtension.lowercased()) }
        let previous = Set(modelFiles.map { $0.standardizedFileURL.path })
        Self.appendUnique(accepted, to: &modelFiles)
        let added = modelFiles.filter { !previous.contains($0.standardizedFileURL.path) }
        if !added.isEmpty { requestCoverSuggestions(added) }
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
