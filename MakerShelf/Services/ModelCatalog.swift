import Foundation

/// 模型查询和 JSON 解码均在 actor 中执行，避免占用主线程。
/// 目前是内存索引；真实大数据量接入时可保持接口不变，替换成 SQLite 分页查询。
actor ModelCatalog {
    private struct IndexedRecord {
        var model: ModelRecord
        let searchKey: String
    }
    private var index: [IndexedRecord] = []
    private var loaded = false
    private var cachedQuery: LibraryQuery?
    private var cachedResults: [ModelRecord] = []
    private var statistics = LibraryStatistics()
    private var authors: [String] = []
    private var categories: [String] = []
    private let persistURL: URL

    init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let folder = root.appendingPathComponent("MakerShelf", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        persistURL = folder.appendingPathComponent("library.json")
    }

    private func loadIfNeeded() throws {
        guard !loaded else { return }
        var records: [ModelRecord] = []
        if FileManager.default.fileExists(atPath: persistURL.path) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let stored = try? decoder.decode([ModelRecord].self, from: Data(contentsOf: persistURL)) {
                records = stored.filter { !$0.isDemo }
            }
        }
        index = records.map { IndexedRecord(model: $0, searchKey: Self.normalize("\($0.title) \($0.subtitle) \($0.author)")) }
        loaded = true
        updateStatistics()
    }

    func page(query: LibraryQuery, offset: Int, limit: Int) throws -> CatalogPage {
        try loadIfNeeded()
        try Task.checkCancellation()
        if cachedQuery != query {
            let term = Self.normalize(query.text.trimmingCharacters(in: .whitespacesAndNewlines))
            var matches: [ModelRecord] = []
            for (position, entry) in index.enumerated() {
                if position.isMultiple(of: 128) { try Task.checkCancellation() }
                let model = entry.model
                guard query.source == nil || query.source?.matches(model) == true,
                      query.category == "全部" || query.category == model.category,
                      query.author == "全部作者" || query.author == model.author,
                      query.status == .all || (query.status == .downloaded ? model.isDownloaded : !model.isDownloaded),
                      term.isEmpty || entry.searchKey.contains(term) else { continue }
                matches.append(model)
            }
            switch query.sort {
            case .recent: matches.sort { $0.sortIndex == $1.sortIndex ? $0.id < $1.id : $0.sortIndex < $1.sortIndex }
            case .name: matches.sort {
                let result = $0.title.localizedStandardCompare($1.title)
                return result == .orderedSame ? $0.id < $1.id : result == .orderedAscending
            }
            case .size: matches.sort { $0.sizeMB == $1.sizeMB ? $0.id < $1.id : $0.sizeMB > $1.sizeMB }
            }
            try Task.checkCancellation()
            cachedResults = matches
            cachedQuery = query
        }
        let start = min(max(0, offset), cachedResults.count)
        let end = min(start + max(0, limit), cachedResults.count)
        return CatalogPage(records: Array(cachedResults[start..<end]), total: cachedResults.count,
                           statistics: statistics, authors: authors, categories: categories)
    }

    func demoRecords(site: MakerSite) throws -> [ModelRecord] {
        try loadIfNeeded()
        return index.map(\.model).filter { $0.site == site && $0.isDemo }
    }

    func upsert(_ record: ModelRecord) throws {
        try loadIfNeeded()
        let entry = IndexedRecord(model: record, searchKey: Self.normalize("\(record.title) \(record.subtitle) \(record.author)"))
        if let position = index.firstIndex(where: { $0.model.id == record.id }) {
            index[position] = entry
        } else {
            index.append(entry)
        }
        cachedQuery = nil
        updateStatistics()
        try persist()
    }

    func markArchived(_ record: ModelRecord) throws {
        try upsert(record)
    }

    func markDemoArchived(id: String) throws {
        try loadIfNeeded()
        guard let position = index.firstIndex(where: { $0.model.id == id }) else { return }
        index[position].model.isDownloaded = true
        cachedQuery = nil
        updateStatistics()
        try persist()
    }

    private func persist() throws {
        let stored = index.map(\.model).filter { !$0.isDemo }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(stored).write(to: persistURL, options: .atomic)
    }

    private func updateStatistics() {
        let models = index.map(\.model)
        authors = Array(Set(models.map(\.author))).sorted()
        categories = Array(Set(models.map(\.category))).sorted()
        statistics = LibraryStatistics(total: models.count,
            downloaded: models.filter(\.isDownloaded).count,
            authorCount: authors.count,
            localCount: models.filter(\.isLocal).count,
            storedMB: models.filter(\.isDownloaded).reduce(0) { $0 + $1.sizeMB })
    }

    private static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "zh_CN"))
    }
}
