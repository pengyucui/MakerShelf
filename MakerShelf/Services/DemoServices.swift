import Foundation

protocol ModelSourceProviding: Sendable {
    func preview(_ request: ImportRequest, offset: Int, limit: Int) async throws -> ImportPreview
}

protocol DownloadExecuting: Sendable {
    func run(model: ModelRecord, startingAt: Double,
             progress: @escaping @Sendable (Double, String) async -> Void) async throws -> ArchiveResult
}

struct MakerWorldSource: ModelSourceProviding {
    let client: MakerWorldClient
    let sessions: @Sendable (MakerSite) async -> SiteSession?

    func preview(_ request: ImportRequest, offset: Int, limit: Int) async throws -> ImportPreview {
        let session = await sessions(request.site)
        return try await client.list(request, session: session, offset: offset, limit: limit)
    }
}

struct ArchiveDownloadExecutor: DownloadExecuting {
    let client: MakerWorldClient
    let sessionFor: @Sendable (MakerSite) async -> SiteSession?
    let archiveURL: @Sendable () async throws -> URL
    let preferredFormat: @Sendable () async -> String

    func run(model: ModelRecord, startingAt: Double,
             progress: @escaping @Sendable (Double, String) async -> Void) async throws -> ArchiveResult {
        let session = await sessionFor(model.site)
        if session == nil { throw ShelfError.notLoggedIn(model.site) }
        let folder = try await archiveURL()
        let format = await preferredFormat()
        await progress(max(startingAt, 0.02), "准备归档目录")
        return try await client.downloadDesign(record: model, session: session, format: format, folder: folder, progress: progress)
    }
}

/// 仅用于无网络时的结构对照，正式运行路径不再调用。
struct DemoModelSource: ModelSourceProviding {
    let catalog: ModelCatalog
    func preview(_ request: ImportRequest, offset: Int, limit: Int) async throws -> ImportPreview {
        try await Task.sleep(for: .milliseconds(250))
        let records = try await catalog.demoRecords(site: request.site)
        let count: Int
        if case .model = request.target { count = 1 } else { count = min(3, records.count) }
        return ImportPreview(records: Array(records.prefix(count)),
                             notice: "以下是固定示例，尚未解析你输入的链接或账号。",
                             total: count, hasMore: false)
    }
}

struct DemoDownloadExecutor: DownloadExecuting {
    func run(model: ModelRecord, startingAt: Double,
             progress: @escaping @Sendable (Double, String) async -> Void) async throws -> ArchiveResult {
        var current = startingAt
        while current < 1 {
            try await Task.sleep(for: .milliseconds(200))
            try Task.checkCancellation()
            current = min(1, current + 0.02)
            await progress(current, "演示进度")
        }
        var record = model
        record.isDownloaded = true
        return ArchiveResult(record: record, warnings: [])
    }
}
