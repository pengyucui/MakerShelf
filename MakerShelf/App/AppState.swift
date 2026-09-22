import Foundation
import Observation

enum AppSection: String, CaseIterable, Identifiable {
    case library = "模型库", downloads = "下载任务", settings = "设置"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .library: return "square.grid.2x2"; case .downloads: return "arrow.down.to.line"; case .settings: return "gearshape" }
    }
}

enum AppSheet: Identifiable {
    case importModels
    case editLocal(ModelRecord)

    var id: String {
        switch self {
        case .importModels: return "import"
        case .editLocal(let model): return "edit-\(model.id)"
        }
    }
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case accounts = "站点账号", storage = "存储与下载"
    var id: String { rawValue }
}

@MainActor @Observable
final class AppState {
    var section: AppSection = .library
    var settingsTab: SettingsTab = .accounts
    var sheet: AppSheet?
    var notice: String?
    var library: LibraryStore
    let downloads: DownloadStore
    let preferences: PreferencesStore
    let sessions: SessionStore
    let provider: any ModelSourceProviding
    private let catalog: ModelCatalog
    private let localImporter = LocalModelImporter()

    init() {
        let catalog = ModelCatalog()
        let library = LibraryStore(catalog: catalog)
        let preferences = PreferencesStore()
        let client = MakerWorldClient()
        let sessions = SessionStore(client: client)
        self.catalog = catalog
        self.library = library
        self.preferences = preferences
        self.sessions = sessions
        self.provider = MakerWorldSource(client: client, sessions: { site in await sessions.snapshot(site) })
        self.downloads = DownloadStore(
            executor: ArchiveDownloadExecutor(
                client: client,
                sessionFor: { site in await sessions.snapshot(site) },
                archiveURL: { try await preferences.scopedArchiveURL() },
                preferredFormat: { await preferences.preferredFormat }
            ),
            concurrency: preferences.maxConcurrentDownloads
        ) { record in
            await library.upsert(record)
        }
    }

    func download(_ model: ModelRecord) {
        guard !model.isLocal else {
            notice = "本地模型已经保存在归档目录中。"
            return
        }
        Task { [weak self] in
            guard let self else { return }
            guard await sessions.restoreIfNeeded(model.site) else {
                LoginPresenter.open(site: model.site, sessions: sessions) { [weak self] in
                    self?.notice = "已连接 \(self?.sessions.displayName(model.site) ?? "")"
                }
                notice = "请先连接\(model.site.title)，再下载该模型。"
                return
            }
            enqueueReady([model])
        }
    }

    func enqueue(_ models: [ModelRecord]) {
        Task { [weak self] in
            guard let self else { return }
            let requiredSites = Set(models.filter { !$0.isLocal }.map(\.site))
            for site in requiredSites where !sessions.isConnected(site) {
                guard await sessions.restoreIfNeeded(site) else {
                    LoginPresenter.open(site: site, sessions: sessions) { [weak self] in
                        self?.notice = "已连接 \(self?.sessions.displayName(site) ?? "")，请再次加入下载队列。"
                    }
                    notice = "站点连接已断开或尚未登录，请连接后再导入。"
                    return
                }
            }
            enqueueReady(models)
        }
    }

    private func enqueueReady(_ models: [ModelRecord]) {
        do { _ = try preferences.scopedArchiveURL() }
        catch {
            sheet = nil
            settingsTab = .storage
            section = .settings
            notice = error.localizedDescription
            return
        }
        let added = downloads.enqueue(models)
        for model in models { Task { await library.upsert(model) } }
        sheet = nil
        section = .downloads
        notice = added == 0 ? "所选模型已经在队列中。" : "已添加 \(added) 个下载任务。"
    }

    func createLocalModel(_ draft: LocalModelDraft) async throws {
        let root = try preferences.scopedArchiveURL()
        let record = try await localImporter.importModel(draft, archiveRoot: root)
        try await catalog.upsert(record)
        await library.refresh(debounce: false)
        sheet = nil
        section = .library
        notice = "“\(record.title)”已添加到本地模型库。"
    }

    func editLocalModel(_ existing: ModelRecord, draft: LocalModelDraft) async throws {
        let root = try preferences.scopedArchiveURL()
        let record = try await localImporter.updateModel(existing, with: draft, archiveRoot: root)
        try await catalog.upsert(record)
        // 归档内图片可能沿用相同文件名；清除缩略图缓存后再刷新，避免继续显示旧封面。
        await ImagePipeline.shared.clearCache()
        await library.refresh(debounce: false)
        sheet = nil
        notice = "“\(record.title)”的修改已保存。"
    }

    func shutdown() {
        downloads.shutdown()
        preferences.stopAccess()
    }
}
