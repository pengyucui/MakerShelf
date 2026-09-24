import Foundation
import Observation

/// 恢复任务独立于设置页面生命周期，切换页面不会丢失进度；更换根目录或退出应用会取消旧扫描。
@MainActor @Observable
final class ArchiveRecoveryStore {
    private(set) var isRunning = false
    private(set) var message: String?
    private(set) var warningCount = 0
    private(set) var warnings: [String] = []
    private(set) var errorMessage: String?
    @ObservationIgnored private let scanner = ArchiveRecoveryScanner()
    @ObservationIgnored private let catalog: ModelCatalog
    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let preferences: PreferencesStore
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var checkedStartup = false
    @ObservationIgnored private var activeRoot: URL?

    init(catalog: ModelCatalog, library: LibraryStore, preferences: PreferencesStore) {
        self.catalog = catalog
        self.library = library
        self.preferences = preferences
    }

    func restoreIfNeeded() async {
        guard !checkedStartup else { return }
        checkedStartup = true
        guard preferences.archiveURL != nil, !isRunning else { return }
        if await catalog.needsArchiveRecovery(), !Task.isCancelled, !isRunning {
            restore()
        }
    }

    func selectAndRestore() {
        guard !isRunning else { return }
        preferences.selectArchiveFolder(onSelected: { [weak self] in self?.restore() })
    }

    func restore() {
        guard !isRunning else { return }
        guard let root = preferences.archiveURL else {
            errorMessage = "请先选择原来的模型归档总目录。"
            return
        }
        generation += 1
        let token = generation
        activeRoot = root.standardizedFileURL
        isRunning = true
        message = "正在扫描已有归档…"
        errorMessage = nil
        warningCount = 0
        warnings = []
        AppLog.write(.info, .storage, "开始恢复已有归档", detail: "目录：\(root.lastPathComponent)")
        task = Task { [self] in
            defer {
                if token == generation { isRunning = false; task = nil; activeRoot = nil }
            }
            do {
                let scan = try await scanner.scan(root: root)
                try Task.checkCancellation()
                // 目录切换后不得把旧根目录的相对路径写进当前模型库。
                guard token == generation, preferences.archiveURL?.standardizedFileURL == root.standardizedFileURL else { return }
                warningCount = scan.warningCount
                warnings = scan.warnings
                guard !scan.records.isEmpty else {
                    message = scan.metadataCount == 0
                        ? "没有找到 MakerShelf 归档资料。请选择原来包含“本地模型”“中文站”或“国际站”的总目录。"
                        : "找到 \(scan.metadataCount) 份资料，但没有可恢复的模型；请查看下方提示或运行日志。"
                    return
                }
                message = "找到 \(scan.records.count) 个模型，正在恢复模型库…"
                let result = try await catalog.restoreArchives(scan.records, legacyIDs: scan.legacyIDs)
                // 索引一旦提交成功就刷新列表；此后取消不会回滚已经完成的恢复。
                await ImagePipeline.shared.clearCache()
                // 持久化已成功时，即使用户刚好点击取消，也应刷新到已提交的模型库。
                await Task { @MainActor [library] in await library.refresh(debounce: false) }.value
                guard token == generation else { return }
                message = "已找回 \(result.added) 个模型，更新 \(result.updated) 个，\(result.unchanged) 个已存在。原文件未复制或修改。"
                if let backup = result.backupName {
                    warnings.insert("原模型库索引无法读取，已先备份为 \(backup)，再从归档重建。", at: 0)
                    warningCount += 1
                }
                AppLog.write(.info, .storage, "已有归档恢复完成", detail: message ?? "")
            } catch is CancellationError {
                if token == generation { message = "已取消恢复，原归档文件保持不变。" }
            } catch {
                guard token == generation else { return }
                message = nil
                errorMessage = "恢复失败：\(error.localizedDescription)"
                AppLog.write(.error, .storage, "已有归档恢复失败", detail: AppLog.errorDescription(error))
            }
        }
    }

    func cancel() { task?.cancel() }

    func directoryChanged() {
        // 选择器成功回调可能已针对新目录开始恢复，因此仅取消仍属于旧目录的任务。
        guard activeRoot != preferences.archiveURL?.standardizedFileURL else { return }
        task?.cancel()
        generation += 1
        task = nil
        activeRoot = nil
        isRunning = false
        message = nil
        errorMessage = nil
        warnings = []
        warningCount = 0
    }
}
