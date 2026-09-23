import Foundation
import Observation

@MainActor @Observable
final class ImportStore {
    var source: ImportSource = .user
    var site: MakerSite = .china
    var target: UserTarget = .current
    var content: UserContent = .favorites
    var input = ""
    private(set) var preview: ImportPreview?
    var selectedIDs: Set<String> = []
    private(set) var loading = false
    private(set) var loadingMore = false
    var errorMessage: String?
    private(set) var requiredSite: MakerSite?
    @ObservationIgnored private let provider: any ModelSourceProviding
    @ObservationIgnored private var requestTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    private let pageSize = 20

    init(provider: any ModelSourceProviding) { self.provider = provider }

    var selectedModels: [ModelRecord] {
        preview?.records.filter { selectedIDs.contains($0.id) } ?? []
    }

    /// 单个公开模型和作者公开作品都可以先预览；真正下载文件时仍由下载队列检查登录会话。
    var canPreviewWithoutLogin: Bool {
        source == .link || (source == .user && target == .specified && content == .published)
    }

    /// 粘贴主页链接时采用链接所属站点，避免默认选中中文站而拒绝国际站主页。
    var effectiveSite: MakerSite {
        guard source == .user, target == .specified,
              let url = specifiedURL,
              let detected = MakerSite.from(url: url) else { return site }
        return detected
    }

    /// 兼容从地址栏复制后省略 `https://` 的 MakerWorld 主页地址。
    private var specifiedURL: URL? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: value), MakerSite.from(url: url) != nil { return url }
        let lowered = value.lowercased()
        let knownHost = MakerSite.allCases.contains { current in
            lowered.hasPrefix("\(current.domain)/") || lowered.hasPrefix("www.\(current.domain)/")
        }
        guard knownHost else { return nil }
        return URL(string: "https://\(value)")
    }

    func cancel() {
        generation += 1
        requestTask?.cancel()
        requestTask = nil
        loading = false
        loadingMore = false
    }

    func edit() {
        cancel()
        preview = nil
        errorMessage = nil
        requiredSite = nil
    }

    func loadPreview(connectedSites: Set<MakerSite>) {
        cancel()
        errorMessage = nil
        requiredSite = nil
        let request: ImportRequest
        do { request = try buildRequest() }
        catch {
            errorMessage = error.localizedDescription
            AppLog.write(.warning, .importing, "导入参数校验失败", detail: AppLog.errorDescription(error))
            return
        }
        if !canPreviewWithoutLogin && !connectedSites.contains(request.site) {
            requiredSite = request.site
            errorMessage = "请先连接\(request.site.title)。"
            AppLog.write(.warning, .importing, "导入需要站点登录", detail: request.site.title)
            return
        }
        let token = generation
        loading = true
        AppLog.write(.info, .importing, "开始读取导入清单", detail: "站点：\(request.site.title)；来源：\(source.rawValue)")
        requestTask = Task { [weak self, provider] in
            do {
                let result = try await provider.preview(request, offset: 0, limit: 20)
                try Task.checkCancellation()
                guard let self, token == self.generation else { return }
                self.preview = result
                self.selectedIDs = Set(result.records.map(\.id))
                self.loading = false
                AppLog.write(.info, .importing, "导入清单已获取", detail: "模型数：\(result.records.count)；还有下一页：\(result.hasMore)")
            } catch is CancellationError {
                if let self, token == self.generation { self.loading = false }
            } catch {
                guard let self, token == self.generation else { return }
                self.loading = false
                self.errorMessage = error.localizedDescription
                AppLog.write(.error, .importing, "读取导入清单失败", detail: AppLog.errorDescription(error))
                if let shelf = error as? ShelfError, case .notLoggedIn(let site) = shelf {
                    self.requiredSite = site
                }
            }
        }
    }

    func loadMore() {
        guard let preview, preview.hasMore, !loading, !loadingMore else { return }
        let request: ImportRequest
        do { request = try buildRequest() }
        catch {
            errorMessage = error.localizedDescription
            AppLog.write(.warning, .importing, "导入分页参数校验失败", detail: AppLog.errorDescription(error))
            return
        }
        let token = generation
        loadingMore = true
        requestTask = Task { [weak self, provider] in
            do {
                let page = try await provider.preview(request, offset: preview.records.count, limit: 20)
                try Task.checkCancellation()
                guard let self, token == self.generation else { return }
                var merged = preview.records
                let existing = Set(merged.map(\.id))
                merged.append(contentsOf: page.records.filter { !existing.contains($0.id) })
                self.preview = ImportPreview(records: merged, notice: page.notice, total: page.total, hasMore: page.hasMore)
                self.selectedIDs.formUnion(page.records.map(\.id))
                self.loadingMore = false
                AppLog.write(.info, .importing, "导入清单下一页已获取", detail: "本页：\(page.records.count)；累计：\(merged.count)")
            } catch is CancellationError {
                if let self, token == self.generation { self.loadingMore = false }
            } catch {
                guard let self, token == self.generation else { return }
                self.loadingMore = false
                self.errorMessage = error.localizedDescription
                AppLog.write(.error, .importing, "读取导入清单下一页失败", detail: AppLog.errorDescription(error))
            }
        }
    }

    private func buildRequest() throws -> ImportRequest {
        guard source != .local else { throw ShelfError.emptyImport }
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if source == .link {
            guard let url = URL(string: value), MakerURL.designIdentity(from: url) != nil else { throw ShelfError.invalidLink }
            let detected = MakerSite.from(url: url)!
            return ImportRequest(site: detected, target: .model(url), content: .published)
        }
        if target == .current {
            return ImportRequest(site: site, target: .currentUser, content: content)
        }
        guard content == .published else { throw ShelfError.favoritesRequireCurrentUser }
        guard !value.isEmpty else { throw ShelfError.missingUser }
        if let url = specifiedURL, let detected = MakerSite.from(url: url) {
            return ImportRequest(site: detected, target: .user(url.absoluteString), content: content)
        }
        if value.contains("://") { throw ShelfError.missingUser }
        return ImportRequest(site: site, target: .user(value), content: content)
    }
}
