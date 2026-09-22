import Foundation
import Observation

@MainActor @Observable
final class LibraryStore {
    var query = LibraryQuery()
    var layout: LibraryLayout = .grid
    /// 跨页面保存搜索焦点请求，不与筛选查询绑定，避免无意义地重新加载目录。
    var searchFocusRequest = 0
    private(set) var records: [ModelRecord] = []
    private(set) var total = 0
    private(set) var statistics = LibraryStatistics()
    private(set) var authors: [String] = []
    private(set) var categories: [String] = []
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var hasLoaded = false
    var errorMessage: String?
    var isLibraryEmpty: Bool { hasLoaded && statistics.total == 0 && records.isEmpty }

    @ObservationIgnored private let catalog: ModelCatalog
    @ObservationIgnored private var generation = 0
    private let pageSize = 120
    var hasMore: Bool { records.count < total }

    init(catalog: ModelCatalog) { self.catalog = catalog }

    /// 由 View 的 task(id:) 调用，条件变化时 SwiftUI 会取消上一轮查询。
    func refresh(debounce: Bool = true) async {
        generation += 1
        let token = generation
        let request = query
        isLoading = true
        isLoadingMore = false
        errorMessage = nil
        defer { if token == generation { isLoading = false; hasLoaded = true } }
        do {
            if debounce { try await Task.sleep(for: .milliseconds(250)) }
            let page = try await catalog.page(query: request, offset: 0, limit: pageSize)
            try Task.checkCancellation()
            guard token == generation, request == query else { return }
            records = page.records
            total = page.total
            statistics = page.statistics
            authors = page.authors
            categories = page.categories
        } catch is CancellationError {
            // 用户仍在输入时的取消属于正常流程，不弹出错误。
        } catch {
            guard token == generation else { return }
            errorMessage = error.localizedDescription
        }
    }

    func loadMore() async {
        guard hasMore, !isLoading, !isLoadingMore else { return }
        isLoadingMore = true
        let token = generation
        let request = query
        defer { if token == generation { isLoadingMore = false } }
        do {
            let page = try await catalog.page(query: request, offset: records.count, limit: pageSize)
            try Task.checkCancellation()
            guard token == generation, request == query else { return }
            records.append(contentsOf: page.records)
        } catch is CancellationError {
        } catch {
            if token == generation { errorMessage = error.localizedDescription }
        }
    }

    func upsert(_ record: ModelRecord) async {
        do {
            try await catalog.upsert(record)
            await refresh(debounce: false)
        } catch { errorMessage = error.localizedDescription }
    }
}
