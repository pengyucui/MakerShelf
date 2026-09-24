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
            // 索引损坏必须明确报错，不能静默当作空库并在下一次保存时覆盖旧数据。
            records = try decoder.decode([ModelRecord].self, from: Data(contentsOf: persistURL)).filter { !$0.isDemo }
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

    /// 正常升级复用原索引；只有索引为空或无法读取时，才需要从已授权归档重建。
    func needsArchiveRecovery() -> Bool {
        do { try loadIfNeeded(); return index.isEmpty }
        catch { return true }
    }

    /// 合并扫描到的归档，一次原子写入；同 ID 更新路径及资料，不新增重复卡片。
    /// 未扫描到的现有记录保持不变，磁盘提交失败时内存也回到原状态。
    func restoreArchives(_ records: [ModelRecord], legacyIDs: Set<String>) throws -> ArchiveRecoveryResult {
        guard !records.isEmpty else {
            return ArchiveRecoveryResult(added: 0, updated: 0, unchanged: 0, backupName: nil)
        }
        try Task.checkCancellation()
        let oldIndex = index
        let wasLoaded = loaded
        var backupName: String?
        do {
            do { try loadIfNeeded() }
            catch {
                // 先保留无法解析的原始索引，再允许恢复。备份失败时终止，避免丢失仅在旧索引里的资料。
                let backup = persistURL.deletingLastPathComponent()
                    .appendingPathComponent("library-before-recovery-\(UUID().uuidString).json")
                try FileManager.default.copyItem(at: persistURL, to: backup)
                backupName = backup.lastPathComponent
                index = []
                loaded = true
            }
            var positions: [String: Int] = [:]
            for (position, entry) in index.enumerated() { positions[entry.model.id] = position }
            var result = ArchiveRecoveryResult(added: 0, updated: 0, unchanged: 0, backupName: backupName)
            for record in records {
                try Task.checkCancellation()
                if let position = positions[record.id] {
                    let current = index[position].model
                    // 扫描期间可能完成新的下载或编辑；同目录下明确更新的记录不能被旧扫描快照覆盖。
                    // ISO8601 归档只保存整秒，允许一秒精度差，避免把同一次保存误判成新版本。
                    if current.archiveFolder == record.archiveFolder,
                       let currentDate = current.archivedAt, let archivedDate = record.archivedAt,
                       currentDate.timeIntervalSince(archivedDate) > 1 {
                        result.unchanged += 1
                        continue
                    }
                    var merged = record
                    if legacyIDs.contains(record.id) {
                        // 精简资料不应清空当前索引独有的分类、摘要等；只修复归档相关的可变字段。
                        merged = index[position].model
                        merged.files = record.files
                        merged.archiveFolder = record.archiveFolder
                        merged.localCoverPath = record.localCoverPath
                        merged.localImagePaths = record.localImagePaths
                        merged.fileCount = record.fileCount
                        merged.sizeMB = record.sizeMB
                        merged.isDownloaded = true
                        merged.archivedAt = record.archivedAt
                        if let html = record.descriptionHTML { merged.descriptionHTML = html }
                    }
                    if index[position].model == merged { result.unchanged += 1; continue }
                    index[position] = IndexedRecord(model: merged, searchKey: Self.normalize("\(merged.title) \(merged.subtitle) \(merged.author)"))
                    result.updated += 1
                } else {
                    positions[record.id] = index.count
                    index.append(IndexedRecord(model: record, searchKey: Self.normalize("\(record.title) \(record.subtitle) \(record.author)")))
                    result.added += 1
                }
            }
            try Task.checkCancellation()
            if result.added + result.updated > 0 { try persist() }
            cachedQuery = nil
            updateStatistics()
            return result
        } catch {
            index = oldIndex
            loaded = wasLoaded
            cachedQuery = nil
            updateStatistics()
            throw error
        }
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
