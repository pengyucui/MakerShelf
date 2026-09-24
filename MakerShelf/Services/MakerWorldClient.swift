import Foundation
import CryptoKit

actor MakerWorldClient {
    private let session: URLSession
    private var lastRequest = Date.distantPast

    init(session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 45
        config.httpMaximumConnectionsPerHost = 3
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        return URLSession(configuration: config)
    }()) {
        self.session = session
    }

    enum LoginStep: Sendable {
        case success(token: String, refreshToken: String?)
        case emailCode
        case tfa(key: String)
    }

    func login(site: MakerSite, account: String, password: String) async throws -> LoginStep {
        let body: [String: String] = ["account": account, "password": password, "apiError": ""]
        let result = try await postFull(site: site, path: "user-service/user/login", body: body, session: nil)
        return try parseLogin(result.json, cookies: result.cookies)
    }

    func login(site: MakerSite, account: String, code: String, password: String? = nil) async throws -> LoginStep {
        var body: [String: String] = ["account": account, "code": code]
        if let password, !password.isEmpty { body["password"] = password }
        let result = try await postFull(site: site, path: "user-service/user/login", body: body, session: nil)
        return try parseLogin(result.json, cookies: result.cookies)
    }

    func sendVerificationCode(site: MakerSite, account: String) async throws {
        if account.contains("@") {
            _ = try await postJSON(site: site, path: "user-service/user/sendemail/code",
                                   body: ["email": account, "type": "codeLogin"], session: nil)
            return
        }
        do {
            _ = try await postJSON(site: site, path: "user-service/user/sendsmscode",
                                   body: ["phone": account, "type": "codeLogin"], session: nil)
        } catch {
            _ = try await postJSON(site: site, path: "api/v1/user-service/user/sendsmscode",
                                   body: ["phone": account, "type": "codeLogin"], session: nil, useV1: false)
        }
    }

    func loginTFA(site: MakerSite, tfaKey: String, tfaCode: String) async throws -> LoginStep {
        let result = try await postFull(site: site, path: "api/sign-in/tfa",
                                        body: ["tfaKey": tfaKey, "tfaCode": tfaCode], session: nil, useV1: false)
        return try parseLogin(result.json, cookies: result.cookies)
    }

    func profile(site: MakerSite, session snapshot: SiteSession) async throws -> (uid: String, name: String, handle: String?, avatar: String?) {
        // 只问网站自己的接口。云端接口不认网页令牌，回退过去会得到 401，被误报成登录过期。
        let webPaths = ["design-user-service/my/preference", "design-user-service/my/profile", "user-service/my/profile"]
        var lastError: Error = ShelfError.sessionExpired(site)
        for path in webPaths {
            do {
                let json = try await fetchJSON(site: site, path: path, session: snapshot, channel: .site, fallbackToCloud: false)
                if let parsed = Self.parseProfile(json) { return parsed }
            } catch { lastError = error }
        }
        throw lastError
    }

    /// 用该站点自己的 refreshToken 换新的访问令牌。不携带另一个站点的 Cookie。
    func refresh(_ session: SiteSession) async throws -> SiteSession {
        let refreshToken = session.refreshToken
            ?? session.cookies.first {
                session.site.belongs(cookieDomain: $0.domain) && $0.name.lowercased().contains("refresh")
            }?.value
        guard let refreshToken, !refreshToken.isEmpty else { throw ShelfError.sessionExpired(session.site) }
        var carrier = session
        carrier.token = refreshToken
        let result = try await perform(site: session.site, path: "user-service/user/refreshtoken",
                                       method: "POST", query: [:], body: ["refreshToken": refreshToken],
                                       session: carrier, channel: .site)
        guard let token = Self.findToken(in: result.json), Self.isUsableToken(token) else {
            throw ShelfError.sessionExpired(session.site)
        }
        var next = session
        next.token = token
        if let rotated = Self.findString(result.json, keys: ["refreshToken", "refresh_token"]), !rotated.isEmpty {
            next.refreshToken = rotated
        }
        next.updatedAt = Date()
        return next
    }

    func design(site: MakerSite, id: Int, session snapshot: SiteSession?) async throws -> ModelRecord {
        let json = try await fetchJSON(site: site, path: "design-service/design/\(id)", session: snapshot)
        guard let record = Self.record(fromDesign: json, site: site) else { throw ShelfError.emptyImport }
        return record
    }

    func list(_ request: ImportRequest, session snapshot: SiteSession?, offset: Int, limit: Int) async throws -> ImportPreview {
        switch request.target {
        case .model(let url):
            guard let identity = MakerURL.designIdentity(from: url) else { throw ShelfError.invalidLink }
            let record = try await design(site: identity.0, id: identity.1, session: snapshot)
            return ImportPreview(records: [record], notice: "已解析模型链接，准备归档文件、介绍和图片。", total: 1, hasMore: false)
        case .currentUser:
            guard let snapshot else { throw ShelfError.notLoggedIn(request.site) }
            return try await currentUserList(site: request.site, content: request.content,
                                             session: snapshot, offset: offset, limit: limit)
        case .user(let raw):
            guard let resolved = MakerURL.userReference(from: raw, site: request.site) else { throw ShelfError.missingUser }
            if resolved.0 != request.site { throw ShelfError.wrongSite }
            guard request.content == .published else { throw ShelfError.favoritesRequireCurrentUser }
            // 作者主页与发布列表都是公开数据。这里不携带网页登录会话，避免同源接口回退到
            // api.bambulab.com / api.bambulab.cn 时把网页令牌误作云端 Bearer 令牌而返回 401。
            return try await publishedList(site: request.site, reference: resolved.1,
                                           session: nil, offset: offset, limit: limit)
        }
    }

    func downloadDesign(record: ModelRecord, session snapshot: SiteSession?, format: String,
                        folder: URL, progress: @escaping @Sendable (Double, String) async -> Void) async throws -> ArchiveResult {
        guard let designId = record.designId else { throw ShelfError.downloadFailed("缺少模型编号，无法下载。") }
        try Task.checkCancellation()
        await progress(0.04, "获取文件信息")
        let json = try await fetchJSON(site: record.site, path: "design-service/design/\(designId)", session: snapshot)
        guard var detailed = Self.record(fromDesign: json, site: record.site) else { throw ShelfError.emptyImport }
        detailed.isDownloaded = record.isDownloaded
        detailed.sortIndex = record.sortIndex
        let writer = ArchiveWriter(root: folder, record: detailed)
        try writer.prepare()

        let files = Self.downloadableFiles(from: json, record: detailed, format: format)
        if files.isEmpty { throw ShelfError.downloadFailed("未找到可下载的模型文件。请确认已登录，且该模型允许当前账号下载。") }

        var warnings: [String] = []
        var savedFiles: [ModelFile] = []
        let fileShare = 0.62
        for (index, item) in files.enumerated() {
            try Task.checkCancellation()
            let base = 0.08 + fileShare * Double(index) / Double(files.count)
            await progress(base, "下载模型 \(index + 1)/\(files.count)：\(item.name)")
            do {
                let dest = writer.modelsDirectory.appendingPathComponent(PathSafety.component(item.name))
                if FileManager.default.fileExists(atPath: dest.path),
                   (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 > 0 {
                    savedFiles.append(ModelFile(id: item.id, name: dest.lastPathComponent, kind: item.kind,
                                                sizeBytes: item.sizeBytes, relativePath: writer.relative(dest), remoteHint: nil))
                    continue
                }
                try await downloadFile(item: item, site: record.site, session: snapshot, destination: dest) { fraction in
                    await progress(base + fileShare / Double(files.count) * fraction, "下载模型 \(index + 1)/\(files.count)：\(item.name)")
                }
                let size = (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? item.sizeBytes
                savedFiles.append(ModelFile(id: item.id, name: dest.lastPathComponent, kind: item.kind,
                                            sizeBytes: size, relativePath: writer.relative(dest), remoteHint: nil))
            } catch {
                warnings.append("模型文件 \(item.name) 失败：\(error.localizedDescription)")
            }
        }
        if savedFiles.isEmpty { throw ShelfError.downloadFailed(warnings.first ?? "模型文件下载失败。") }

        await progress(0.74, "保存介绍")
        let html = detailed.descriptionHTML ?? detailed.summary
        let imageURLs = Self.imageURLs(html: html, record: detailed)
        var localImages: [String] = []
        var replacements: [(String, String)] = []
        let imageShare = 0.18
        for (index, raw) in imageURLs.enumerated() {
            try Task.checkCancellation()
            guard let url = PathSafety.remoteURL(raw) else { continue }
            // 图片列表的顺序可能变化，文件名包含来源摘要，防止把上次同一序号的另一张图当作缓存。
            let imageKey = SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16)
            let webp = writer.imagesDirectory.appendingPathComponent(String(format: "%02d", index) + "-\(imageKey).webp")
            await progress(0.76 + imageShare * Double(index) / Double(max(imageURLs.count, 1)), "保存图片 \(index + 1)/\(imageURLs.count)")
            do {
                let saved = try await saveDisplayImage(from: url, to: webp, referer: record.site)
                localImages.append(writer.relative(saved))
                replacements.append((raw, "images/\(saved.lastPathComponent)"))
            } catch {
                try Task.checkCancellation()
                AppLog.write(.warning, .image, "展示图归档失败",
                             detail: "模型：\(record.id)；图片序号：\(index + 1)\n\(AppLog.errorDescription(error))")
                warnings.append("图片 \(index + 1) 失败：\(error.localizedDescription)")
            }
        }
        try Task.checkCancellation()
        let rewritten = writer.rewriteHTML(html, replacements: replacements)
        try rewritten.write(to: writer.descriptionURL, atomically: true, encoding: .utf8)
        detailed.files = savedFiles
        detailed.localImagePaths = localImages
        detailed.localCoverPath = localImages.first
        detailed.archiveFolder = writer.relative(writer.folder)
        detailed.descriptionHTML = rewritten
        detailed.fileCount = savedFiles.count
        detailed.sizeMB = Double(savedFiles.reduce(0) { $0 + $1.sizeBytes }) / 1_048_576
        detailed.isDownloaded = true
        detailed.archivedAt = Date()
        detailed.warnings = warnings
        try writer.writeMetadata(detailed)
        await progress(1, warnings.isEmpty ? "已完成" : "部分完成")
        return ArchiveResult(record: detailed, warnings: warnings)
    }

    private func currentUserList(site: MakerSite, content: UserContent, session snapshot: SiteSession,
                                 offset: Int, limit: Int) async throws -> ImportPreview {
        let path: String
        let notice: String
        switch content {
        case .favorites:
            path = "design-service/my/favorites/v2/like"
            notice = "正在读取当前账号收藏的模型。"
        case .published:
            path = "design-service/my/design/published"
            notice = "正在读取当前账号发布的模型。"
        }
        let json = try await fetchJSON(site: site, path: path, session: snapshot,
                                       query: ["offset": "\(offset)", "limit": "\(limit)"])
        return try Self.importPreview(from: json, site: site, offset: offset, notice: notice)
    }

    private func publishedList(site: MakerSite, reference: String, session snapshot: SiteSession?,
                               offset: Int, limit: Int) async throws -> ImportPreview {
        let user = try await resolveUser(site: site, reference: reference, session: snapshot)
        var query = ["offset": "\(offset)", "limit": "\(limit)"]
        if !user.handle.isEmpty { query["handle"] = "@\(user.handle)" }
        let json = try await fetchJSON(site: site, path: "design-service/published/\(user.uid)/design",
                                       session: snapshot, query: query)
        let display = user.handle.isEmpty ? reference : user.handle
        return try Self.importPreview(from: json, site: site, offset: offset,
                                      notice: "正在读取 @\(display) 发布的模型。")
    }

    private func resolveUser(site: MakerSite, reference raw: String,
                             session snapshot: SiteSession?) async throws -> ResolvedMakerUser {
        let reference = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        guard !reference.isEmpty else { throw ShelfError.missingUser }
        if reference.allSatisfy({ $0.isNumber }) {
            return ResolvedMakerUser(uid: reference, handle: "")
        }

        // 发布列表接口只接受数字 UID；使用站点公开用户搜索解析用户名与显示名称。
        let json = try await fetchJSON(site: site, path: "search-service/search/user", session: snapshot,
                                       query: ["keyword": reference, "offset": "0", "limit": "20"])
        let rows = Self.userRows(from: json)
        let matchesReference: (String?) -> Bool = { candidate in
            guard let candidate else { return false }
            let normalized = candidate.trimmingCharacters(in: CharacterSet(charactersIn: "@"))
            return normalized.caseInsensitiveCompare(reference) == .orderedSame
        }
        let exact = rows.first { rawRow in
            let row = Self.userNode(from: rawRow)
            let handle = Self.string(row, keys: ["handle", "userHandle", "uniqueCode"])
            let name = Self.string(row, keys: ["name", "nickname", "displayName"])
            return matchesReference(handle) || matchesReference(name)
        }
        guard let rawRow = exact ?? (rows.count == 1 ? rows[0] : nil) else {
            throw ShelfError.userNotFound
        }
        let row = Self.userNode(from: rawRow)
        guard let uid = Self.string(row, keys: ["uid", "userId", "user_id"]) else {
            throw ShelfError.userNotFound
        }
        let rawHandle = Self.string(row, keys: ["handle", "userHandle", "uniqueCode"]) ?? reference
        let handle = rawHandle.trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        return ResolvedMakerUser(uid: uid, handle: handle)
    }

    private static func importPreview(from json: Any, site: MakerSite, offset: Int,
                                      notice: String) throws -> ImportPreview {
        let hits = Self.hits(from: json)
        let total = Self.total(from: json) ?? max(offset + hits.count, hits.count)
        let records = hits.compactMap { Self.record(fromHit: $0, site: site) }
        if records.isEmpty && offset == 0 { throw ShelfError.emptyImport }
        return ImportPreview(records: records, notice: "\(notice) 已列出 \(offset + records.count)/\(total) 个。",
                             total: total, hasMore: offset + records.count < total)
    }

    /// 下载后用 libwebp 收成 WebP。编码失败时回退 JPEG；仍失败才保留原文件，成功转码的动图只留第一帧。
    private func saveDisplayImage(from remote: URL, to webp: URL, referer: MakerSite) async throws -> URL {
        try Task.checkCancellation()
        let ext = remote.pathExtension.lowercased().filter { $0.isLetter || $0.isNumber }
        let fallbackExt = ext.isEmpty ? "img" : String(ext.prefix(4))
        let fallback = webp.deletingPathExtension().appendingPathExtension(fallbackExt)
        // JPEG 和原格式回退同样可以复用，继续任务时不反复下载和编码已经完成的图片。
        for candidate in [webp, webp.deletingPathExtension().appendingPathExtension("jpg"), fallback] {
            if ((try? candidate.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0 { return candidate }
        }
        // 暂停后立即恢复可能与旧压缩任务重叠，每次下载使用独立临时文件。
        let temp = webp.deletingLastPathComponent().appendingPathComponent(".image-\(UUID().uuidString).download")
        defer { try? FileManager.default.removeItem(at: temp) }
        try await downloadBinary(from: remote, to: temp, session: nil, authorized: false, referer: referer) { _ in }
        do {
            let encoded = try await DisplayImageEncoder.shared.compress(from: temp)
            try Task.checkCancellation()
            if encoded.fileExtension != "webp" { AppLog.write(.warning, .image, "WebP 编码回退到 JPEG") }
            return try encoded.write(to: webp)
        } catch {
            // 取消不能被当作编码失败，否则旧任务仍会把原图写回正式归档。
            try Task.checkCancellation()
            AppLog.write(.warning, .image, "图片压缩失败，保留原文件", detail: AppLog.errorDescription(error))
            let data = try Data(contentsOf: temp, options: .mappedIfSafe)
            try data.write(to: fallback, options: .atomic)
            return fallback
        }
    }

    private func downloadFile(item: Downloadable, site: MakerSite, session snapshot: SiteSession?,
                              destination: URL, progress: @escaping @Sendable (Double) async -> Void) async throws {
        if let url = item.directURL {
            try await downloadBinary(from: url, to: destination, session: snapshot, authorized: item.needsAuth, progress: progress)
            return
        }
        if let designId = item.designId, let key = item.fileKey {
            try await downloadListedModelFile(designId: designId, key: key, name: item.name, site: site,
                                              session: snapshot, destination: destination, progress: progress)
            return
        }
        if let profileId = item.profileId, let modelId = item.modelId, let snapshot {
            do {
                let payload = try await fetchJSON(site: site, path: "iot-service/api/user/profile/\(profileId)",
                                             session: snapshot, query: ["model_id": modelId])
                if let raw = Self.string(payload, keys: ["url", "downloadUrl", "fileUrl"]), let url = URL(string: raw) {
                    try await downloadBinary(from: url, to: destination, session: nil, authorized: false, progress: progress)
                    return
                }
            } catch { }
        }
        if let instanceId = item.instanceId {
            var components = URLComponents(string: "https://\(site.apiHost)/v1/design-service/instance/\(instanceId)/f3mf")
            components?.queryItems = [URLQueryItem(name: "type", value: "download")]
            guard let downloadURL = components?.url else { throw ShelfError.downloadFailed("无法构造下载地址。") }
            try await downloadBinary(from: downloadURL, to: destination, session: snapshot, authorized: true, progress: progress)
            return
        }
        throw ShelfError.downloadFailed("没有可用的下载地址：\(item.name)")
    }

    /// 原始 STL、STEP 等文件在模型详情里经常只有编号，没有直链。向站点要一次下载地址或文件本体。
    private func downloadListedModelFile(designId: Int, key: String, name: String, site: MakerSite,
                                         session snapshot: SiteSession?, destination: URL,
                                         progress: @escaping @Sendable (Double) async -> Void) async throws {
        let queries: [[String: String]] = [
            ["type": "download", "key": key],
            ["type": "download", "unikey": key]
        ]
        let bases = [
            "https://\(site.domain)/api/v1/design-service/design/\(designId)/model",
            "https://\(site.apiHost)/v1/design-service/design/\(designId)/model"
        ]
        var lastError: Error = ShelfError.downloadFailed("没有可用的下载地址：\(name)")
        for base in bases {
            for query in queries {
                do {
                    try await fetchListedModelFile(base: base, query: query, site: site, session: snapshot,
                                                   destination: destination, progress: progress)
                    return
                } catch let error as ShelfError where error.isSessionExpired {
                    throw error
                } catch {
                    lastError = error
                }
            }
        }
        throw lastError
    }

    private func fetchListedModelFile(base: String, query: [String: String], site: MakerSite,
                                      session snapshot: SiteSession?, destination: URL,
                                      progress: @escaping @Sendable (Double) async -> Void) async throws {
        var components = URLComponents(string: base)
        components?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components?.url else { throw ShelfError.downloadFailed("无法构造模型文件地址。") }
        try await throttle()
        var request = URLRequest(url: url)
        request.setValue(snapshot?.userAgent ?? "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        request.setValue("https://\(site.domain)/", forHTTPHeaderField: "Referer")
        apply(snapshot, to: &request)
        let (temp, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: temp) }
        guard let http = response as? HTTPURLResponse else { throw ShelfError.downloadFailed("模型文件响应无效。") }
        if http.statusCode == 401 { throw ShelfError.sessionExpired(site) }
        guard (200..<300).contains(http.statusCode) else { throw ShelfError.http(http.statusCode, "模型文件下载失败") }
        let header = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let handle = try FileHandle(forReadingFrom: temp)
        let prefix = try handle.read(upToCount: 1) ?? Data()
        try handle.close()
        if prefix.first == UInt8(ascii: "<") {
            throw ShelfError.downloadFailed("站点返回了网页而不是模型文件。")
        }
        if header.contains("json") || prefix.first == UInt8(ascii: "{") || prefix.first == UInt8(ascii: "[") {
            let data = try Data(contentsOf: temp)
            let json = try JSONSerialization.jsonObject(with: data)
            guard let raw = Self.findString(json, keys: ["url", "downloadUrl", "fileUrl", "modelUrl"]),
                  let fileURL = Self.modelFileURL(raw) else {
                throw ShelfError.downloadFailed("站点没有返回模型文件地址。")
            }
            try await downloadBinary(from: fileURL, to: destination, session: nil, authorized: false, referer: site, progress: progress)
            return
        }
        try Task.checkCancellation()
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temp, to: destination)
        await progress(1)
    }

    private static func modelFileURL(_ raw: String?) -> URL? {
        guard var raw, !raw.isEmpty else { return nil }
        if raw.hasPrefix("//") { raw = "https:" + raw }
        if let url = URL(string: raw), url.scheme == "https" || url.scheme == "http" { return url }
        let path = raw.hasPrefix("/") ? String(raw.dropFirst()) : raw
        return URL(string: "https://makerworld.bblmw.com/\(path)")
    }

    private func downloadBinary(from url: URL, to destination: URL, session snapshot: SiteSession?,
                                authorized: Bool, referer: MakerSite? = nil,
                                progress: @escaping @Sendable (Double) async -> Void) async throws {
        try await throttle()
        var request = URLRequest(url: url)
        request.setValue(snapshot?.userAgent ?? "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        if let referer {
            request.setValue("https://\(referer.domain)/", forHTTPHeaderField: "Referer")
        }
        if authorized {
            apply(snapshot, to: &request)
        }
        let (temp, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse else { throw ShelfError.downloadFailed("下载响应无效。") }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw snapshot == nil ? ShelfError.notLoggedIn(.international) : ShelfError.downloadFailed("没有下载权限或登录已过期。")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ShelfError.http(http.statusCode, "下载失败")
        }
        try Task.checkCancellation()
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temp, to: destination)
        await progress(1)
    }

    private enum Channel { case site, cloud }

    private func fetchJSON(site: MakerSite, path: String, session snapshot: SiteSession?,
                      query: [String: String] = [:], channel: Channel = .site,
                      fallbackToCloud: Bool = true) async throws -> Any {
        do {
            return try await perform(site: site, path: path, method: "GET", query: query, body: nil,
                                     session: snapshot, channel: channel).json
        } catch {
            // 网站返回 401 时不再改打云端：云端会用同一枚网页令牌再回一个 401，把真实原因盖掉。
            if fallbackToCloud, channel == .site, (error as? ShelfError)?.isSessionExpired != true {
                return try await perform(site: site, path: path, method: "GET", query: query, body: nil,
                                         session: snapshot, channel: .cloud).json
            }
            throw error
        }
    }

    private func postJSON(site: MakerSite, path: String, body: [String: String],
                          session snapshot: SiteSession?, useV1: Bool = true) async throws -> Any {
        try await postFull(site: site, path: path, body: body, session: snapshot, useV1: useV1).json
    }

    private func postFull(site: MakerSite, path: String, body: [String: String],
                          session snapshot: SiteSession?, useV1: Bool = true) async throws -> APIResult {
        try await perform(site: site, path: path, method: "POST", query: [:], body: body, session: snapshot,
                          channel: useV1 ? .cloud : .cloud)
    }

    private struct APIResult {
        var json: Any
        var cookies: [HTTPCookie]
    }

    private func perform(site: MakerSite, path: String, method: String, query: [String: String],
                         body: [String: String]?, session snapshot: SiteSession?, channel: Channel) async throws -> APIResult {
        try await throttle()
        let root = channel == .site ? "https://\(site.domain)/api/v1/" : "https://\(site.apiHost)/v1/"
        var components = URLComponents(string: root + path)
        if !query.isEmpty { components?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = components?.url else { throw ShelfError.invalidLink }
        var request = URLRequest(url: url)
        request.httpMethod = method
        Self.applyClientHeaders(&request, site: site, channel: channel, userAgent: snapshot?.userAgent, hasBody: body != nil)
        apply(snapshot, to: &request)
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ShelfError.downloadFailed("站点响应无效。") }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: Self.headerMap(http), for: url)
        if http.statusCode == 401 { throw snapshot == nil ? ShelfError.notLoggedIn(site) : ShelfError.sessionExpired(site) }
        if http.statusCode == 429 { throw ShelfError.rateLimited }
        if http.statusCode == 404 { throw ShelfError.http(404, "接口不存在或内容不可访问") }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.loginError(status: http.statusCode, data: data)
        }
        let json: Any = data.isEmpty ? [:] : (try JSONSerialization.jsonObject(with: data))
        return APIResult(json: json, cookies: cookies)
    }

    private func parseLogin(_ json: Any, cookies: [HTTPCookie] = []) throws -> LoginStep {
        let token = Self.findToken(in: json) ?? cookies.map(\.value).first(where: { Self.isUsableToken($0) })
            ?? cookies.first(where: { ["token", "accessToken", "access_token"].contains($0.name) })?.value
        let refresh = Self.findString(json, keys: ["refreshToken", "refresh_token"])
            ?? cookies.first(where: { $0.name.lowercased().contains("refresh") })?.value
        if let token, Self.isUsableToken(token) {
            return .success(token: token, refreshToken: refresh)
        }
        let type = (Self.findString(json, keys: ["loginType", "login_type"]) ?? "").lowercased()
        if ["verifycode", "codelogin", "smscode", "emailcode", "phonecode", "sms", "email"].contains(type) {
            return .emailCode
        }
        if type == "tfa" || type == "mfa" {
            if let key = Self.findString(json, keys: ["tfaKey", "tfa_key"]), !key.isEmpty {
                return .tfa(key: key)
            }
            throw ShelfError.loginFailed("该账号开启了验证器，但未返回验证密钥。请改用验证器 App 中的 6 位代码，或在网页登录。")
        }
        if let message = Self.findString(json, keys: ["error", "message", "error_msg", "msg"]), !message.isEmpty {
            throw ShelfError.loginFailed(message)
        }
        if Self.boolValue(json, key: "success") == false {
            throw ShelfError.loginFailed("账号或密码不正确。请确认中文站 / 国际站是否选对。")
        }
        let keys = (json as? [String: Any])?.keys.sorted().joined(separator: ", ") ?? "无"
        throw ShelfError.loginFailed("登录未返回令牌（loginType=\(type.isEmpty ? "空" : type)，字段：\(keys)）。请确认站点选择后重试。")
    }

    private func apply(_ snapshot: SiteSession?, to request: inout URLRequest) {
        guard let snapshot else { return }
        let cookies = snapshot.cookies.filter { snapshot.site.belongs(cookieDomain: $0.domain) }
        if let token = snapshot.token, Self.isSessionToken(token) {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let header = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        if !header.isEmpty { request.setValue(header, forHTTPHeaderField: "Cookie") }
        if let csrf = cookies.first(where: { $0.name.lowercased() == "bbl_csrf_token" })?.value {
            let value = csrf.split(separator: ".").first.map(String.init) ?? csrf
            request.setValue(value, forHTTPHeaderField: "x-csrf-token")
        }
    }

    private static func applyClientHeaders(_ request: inout URLRequest, site: MakerSite, channel: Channel,
                                           userAgent: String?, hasBody: Bool) {
        if hasBody { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if channel == .site {
            request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
            request.setValue(userAgent ?? "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
            request.setValue("makerworld", forHTTPHeaderField: "x-bbl-app-source")
            request.setValue("MakerWorld", forHTTPHeaderField: "x-bbl-client-name")
            request.setValue("web", forHTTPHeaderField: "x-bbl-client-type")
            request.setValue("00.00.00.01", forHTTPHeaderField: "x-bbl-client-version")
            request.setValue("https://\(site.domain)", forHTTPHeaderField: "Origin")
            request.setValue("https://\(site.domain)/", forHTTPHeaderField: "Referer")
            request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        } else {
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(userAgent ?? "bambu_network_agent/01.09.05.01", forHTTPHeaderField: "User-Agent")
            request.setValue("MakerWorld", forHTTPHeaderField: "X-BBL-Client-Name")
            request.setValue("web", forHTTPHeaderField: "X-BBL-Client-Type")
            request.setValue("00.00.00.01", forHTTPHeaderField: "X-BBL-Client-Version")
            request.setValue("zh-CN", forHTTPHeaderField: "X-BBL-Language")
        }
    }

    static func isJWT(_ token: String) -> Bool {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.hasPrefix("eyJ") && value.split(separator: ".").count >= 3
    }

    static func isSessionToken(_ token: String) -> Bool {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if isJWT(value) { return true }
        if value.hasPrefix("AQB") && value.count >= 40 { return true }
        return value.count >= 40
    }

    static func isUsableToken(_ token: String) -> Bool { isSessionToken(token) }

    static func findToken(in json: Any) -> String? {
        findString(json, keys: ["accessToken", "access_token", "token", "authToken", "jwt"])
    }

    static func findString(_ json: Any, keys: [String]) -> String? {
        if let value = string(json, keys: keys) { return value }
        guard let dict = json as? [String: Any] else { return nil }
        for nested in ["data", "user", "result", "payload", "account"] {
            if let child = dict[nested], let value = findString(child, keys: keys) { return value }
        }
        return nil
    }

    static func boolValue(_ json: Any, key: String) -> Bool? {
        guard let dict = json as? [String: Any] else { return nil }
        if let value = dict[key] as? Bool { return value }
        if let value = dict[key] as? Int { return value != 0 }
        if let value = dict[key] as? String {
            return ["true", "1", "yes", "success"].contains(value.lowercased())
        }
        return nil
    }

    static func headerMap(_ http: HTTPURLResponse) -> [String: String] {
        var fields: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            fields["\(key)"] = "\(value)"
        }
        return fields
    }

    static func loginError(status: Int, data: Data) -> ShelfError {
        if let json = try? JSONSerialization.jsonObject(with: data) {
            let code = int(json, keys: ["code"])
            if code == 1 {
                return .loginFailed("验证码已过期或不存在。请点「重新发送验证码」，只用最新一封邮件或短信里的 6 位数字。")
            }
            if code == 2 {
                return .loginFailed("验证码不正确。请核对 6 位数字；若已开启验证器，请改用验证器代码。")
            }
            if let message = string(json, keys: ["error", "message", "error_msg", "msg"]), !message.isEmpty {
                if message.contains("密码") || message.localizedCaseInsensitiveContains("password") || message.localizedCaseInsensitiveContains("account") {
                    return .loginFailed("\(message) 请确认账号密码，以及中文站 / 国际站是否选对。")
                }
                return .loginFailed(message)
            }
        }
        return .loginFailed("站点返回 \(status)。请确认账号密码和站点选择。")
    }

    static func apiMessage(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return string(json, keys: ["error", "message", "error_msg", "msg"])
    }

    private func throttle() async throws {
        let delta = Date().timeIntervalSince(lastRequest)
        if delta < 0.18 { try await Task.sleep(for: .milliseconds(Int((0.18 - delta) * 1_000))) }
        lastRequest = Date()
    }
}

/// 公开作者列表接口使用数字 UID，handle 仅用于接口提示与界面展示。
private struct ResolvedMakerUser {
    var uid: String
    var handle: String
}

private struct Downloadable {
    var id: String
    var name: String
    var kind: String
    var sizeBytes: Int
    var directURL: URL?
    var instanceId: Int?
    var profileId: Int?
    var modelId: String?
    var designId: Int?
    var fileKey: String?
    var needsAuth: Bool
}

private struct ArchiveWriter {
    let root: URL
    let folder: URL
    var modelsDirectory: URL { folder.appendingPathComponent("models", isDirectory: true) }
    var imagesDirectory: URL { folder.appendingPathComponent("images", isDirectory: true) }
    var descriptionURL: URL { folder.appendingPathComponent("description.html") }
    var metadataURL: URL { folder.appendingPathComponent("metadata.json") }

    init(root: URL, record: ModelRecord) {
        self.root = root
        let author = PathSafety.component("\(record.author)_\(record.authorId ?? "user")")
        let model = PathSafety.component("\(record.title)_\(record.designId.map(String.init) ?? record.id)")
        folder = root.appendingPathComponent(record.site.title, isDirectory: true)
            .appendingPathComponent(author, isDirectory: true)
            .appendingPathComponent(model, isDirectory: true)
    }

    func prepare() throws {
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
    }

    func relative(_ url: URL) -> String {
        PathSafety.relative(from: url, toRoot: root)
    }

    func rewriteHTML(_ html: String, replacements: [(String, String)]) -> String {
        var result = html
        for (from, to) in replacements.sorted(by: { $0.0.count > $1.0.count }) {
            result = result.replacingOccurrences(of: from, with: to)
            result = result.replacingOccurrences(of: from.replacingOccurrences(of: "&", with: "&amp;"), with: to)
        }
        return """
        <!doctype html><meta charset="utf-8"><title>description</title>
        <style>body{font:14px/1.6 -apple-system,sans-serif;max-width:720px;margin:24px;color:#28372F}img{max-width:100%;height:auto}</style>
        \(result)
        """
    }

    func writeMetadata(_ record: ModelRecord) throws {
        // 归档本身保存完整资料，更新或重装后不再依赖唯一的 library.json 恢复分类、封面及介绍。
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: metadataURL, options: .atomic)
    }
}

extension MakerWorldClient {
    static func record(fromDesign json: Any, site: MakerSite) -> ModelRecord? {
        guard let dict = json as? [String: Any], let id = int(dict, keys: ["id"]) else { return nil }
        let creator = dict["designCreator"] as? [String: Any]
        let ext = dict["designExtension"] as? [String: Any]
        let pictures = ((ext?["design_pictures"] as? [[String: Any]]) ?? []).compactMap {
            string($0, keys: ["url", "imageUrl", "coverUrl"]) ?? string($0["image"] as? [String: Any], keys: ["url"])
        }
        let cover = string(dict, keys: ["coverUrl", "cover", "cover_url", "thumbnail", "image"])
            ?? string(dict["cover"] as? [String: Any], keys: ["url"])
        let instances = dict["instances"] as? [[String: Any]] ?? []
        let instancePictures = instances.flatMap { inst -> [String] in
            let shots = (inst["pictures"] as? [[String: Any]] ?? []).compactMap { string($0, keys: ["url", "imageUrl"]) }
            return [string(inst, keys: ["cover"])].compactMap { $0 } + shots
        }
        let files = (ext?["model_files"] as? [[String: Any]]) ?? []
        let categories = (dict["categories"] as? [[String: Any]])?.compactMap { string($0, keys: ["name"]) } ?? []
        let instance = instances.first(where: { ($0["isDefault"] as? Bool) == true }) ?? instances.first
        let filaments = instance?["instanceFilaments"] as? [[String: Any]] ?? []
        let material = filaments.compactMap { $0["type"] as? String }.uniqued().joined(separator: " · ")
        let seconds = instance.flatMap { int($0, keys: ["prediction"]) }
        let size = files.reduce(0) { $0 + (int($1, keys: ["modelSize"]) ?? 0) }
        let slug = string(dict, keys: ["slug"])
        let summaryCandidates = [string(dict, keys: ["summary"]), string(dict, keys: ["summaryTranslated"]),
                                 string(dict, keys: ["description"]), string(dict, keys: ["content"])]
        let summary = summaryCandidates.compactMap { $0 }.max(by: { $0.count < $1.count }) ?? ""
        let title = string(dict, keys: ["title"]) ?? "未命名模型"
        let author = string(creator, keys: ["name"]) ?? "未知作者"
        let authorId = string(creator, keys: ["uid"])
        return ModelRecord(
            id: "\(site.rawValue):\(id)",
            title: title,
            subtitle: slug ?? title,
            author: author,
            imageName: "",
            category: categories.first ?? "未分类",
            site: site,
            sizeMB: Double(size) / 1_048_576,
            fileCount: max(files.count + instances.count, 1),
            isDownloaded: false,
            backgroundHex: "E9EDE4",
            summary: summary,
            material: material.isEmpty ? "—" : material,
            printTime: seconds.map(Self.formatDuration) ?? "—",
            sortIndex: -Int(Date().timeIntervalSince1970),
            designId: id,
            modelId: string(dict, keys: ["modelId"]),
            authorId: authorId,
            authorHandle: string(creator, keys: ["handle"]),
            coverURL: cover,
            galleryURLs: Self.uniqueURLs([cover].compactMap { $0 } + pictures + instancePictures + Self.htmlImageURLs(summary)),
            sourceURL: MakerURL.modelPage(site: site, designId: id, slug: slug).absoluteString,
            license: string(dict, keys: ["license"]),
            descriptionHTML: summary,
            defaultInstanceId: int(dict, keys: ["defaultInstanceId"]) ?? int(instance, keys: ["id"])
        )
    }

    static func record(fromHit json: Any, site: MakerSite) -> ModelRecord? {
        guard let dict = json as? [String: Any] else { return nil }
        let nested = dict["design"] as? [String: Any]
            ?? dict["designInfo"] as? [String: Any]
            ?? dict["model"] as? [String: Any]
            ?? dict
        return record(fromDesign: nested, site: site)
    }

    static func hits(from json: Any) -> [[String: Any]] {
        if let rows = json as? [[String: Any]] { return rows }
        guard let dict = json as? [String: Any] else { return [] }
        for key in ["hits", "designs", "list", "items"] {
            if let rows = dict[key] as? [[String: Any]] { return rows }
        }
        // 中文站与国际站的外层字段可能不同，递归兼容 data/result/payload 包装。
        for key in ["data", "result", "payload"] {
            if let child = dict[key] {
                let rows = hits(from: child)
                if !rows.isEmpty { return rows }
            }
        }
        return []
    }

    static func userRows(from json: Any) -> [[String: Any]] {
        if let rows = json as? [[String: Any]] { return rows }
        guard let dict = json as? [String: Any] else { return [] }
        for key in ["users", "hits", "list", "items"] {
            if let rows = dict[key] as? [[String: Any]] { return rows }
        }
        for key in ["data", "result", "payload"] {
            if let child = dict[key] {
                let rows = userRows(from: child)
                if !rows.isEmpty { return rows }
            }
        }
        return []
    }

    static func userNode(from row: [String: Any]) -> [String: Any] {
        row["user"] as? [String: Any]
            ?? row["profile"] as? [String: Any]
            ?? row["account"] as? [String: Any]
            ?? row
    }

    static func total(from json: Any) -> Int? {
        guard let dict = json as? [String: Any] else { return nil }
        if let value = int(dict, keys: ["total", "totalCount", "count"]) { return value }
        for key in ["data", "result", "payload"] {
            if let child = dict[key], let value = total(from: child) { return value }
        }
        return nil
    }

    static func parseProfile(_ json: Any) -> (uid: String, name: String, handle: String?, avatar: String?)? {
        var nodes: [[String: Any]] = []
        if let dict = json as? [String: Any] {
            nodes.append(dict)
            for key in ["user", "profile", "data", "account"] {
                if let nested = dict[key] as? [String: Any] { nodes.append(nested) }
            }
        }
        for node in nodes {
            let handle = string(node, keys: ["handle", "userHandle", "uniqueCode", "nickName"])
            if let uid = string(node, keys: ["uid", "userId", "user_id"]) ?? handle {
                let name = string(node, keys: ["name", "nickname", "displayName", "accountName"]) ?? handle ?? "已连接用户"
                return (uid, name, handle ?? string(node, keys: ["handle", "userHandle"]), string(node, keys: ["avatar", "avatarUrl", "headImg"]))
            }
        }
        return nil
    }

    fileprivate static func downloadableFiles(from json: Any, record: ModelRecord, format: String) -> [Downloadable] {
        guard let dict = json as? [String: Any] else { return [] }
        let ext = dict["designExtension"] as? [String: Any]
        let rawFiles = Self.flattenModelFiles((ext?["model_files"] as? [[String: Any]]) ?? [])
        let instances = dict["instances"] as? [[String: Any]] ?? []
        let preferSTL = format.contains("STL")
        let prefer3MF = format.contains("3MF")
        var items: [Downloadable] = []
        if !preferSTL {
            for instance in instances {
                guard let instanceId = int(instance, keys: ["id"]) else { continue }
                let title = string(instance, keys: ["title"]) ?? "print-profile"
                items.append(Downloadable(id: "instance-\(instanceId)", name: "\(PathSafety.component(title)).3mf",
                                          kind: "3mf", sizeBytes: 0, directURL: nil, instanceId: instanceId,
                                          profileId: int(instance, keys: ["profileId"]), modelId: record.modelId,
                                          designId: record.designId, fileKey: nil, needsAuth: true))
            }
        }
        for file in rawFiles {
            let name = string(file, keys: ["modelName", "name"]) ?? "model"
            let kind = (string(file, keys: ["modelType"]) ?? URL(fileURLWithPath: name).pathExtension).lowercased()
            if prefer3MF && kind != "3mf" { continue }
            if preferSTL && !(kind == "stl" || kind == "zip") { continue }
            let url = modelFileURL(string(file, keys: ["modelUrl", "url", "downloadUrl", "fileUrl"]))
            let key = string(file, keys: ["unikey", "key", "modelKey", "fileKey"])
            items.append(Downloadable(id: key ?? name, name: name, kind: kind.isEmpty ? "bin" : kind,
                                      sizeBytes: int(file, keys: ["modelSize"]) ?? 0, directURL: url, instanceId: nil,
                                      profileId: nil, modelId: record.modelId, designId: record.designId,
                                      fileKey: key, needsAuth: url == nil))
        }
        if preferSTL && items.isEmpty {
            for instance in instances {
                guard let instanceId = int(instance, keys: ["id"]) else { continue }
                items.append(Downloadable(id: "instance-\(instanceId)", name: "profile-\(instanceId).3mf", kind: "3mf",
                                          sizeBytes: 0, directURL: nil, instanceId: instanceId,
                                          profileId: int(instance, keys: ["profileId"]), modelId: record.modelId,
                                          designId: record.designId, fileKey: nil, needsAuth: true))
            }
        }
        return items
    }

    private static func flattenModelFiles(_ files: [[String: Any]]) -> [[String: Any]] {
        var result: [[String: Any]] = []
        for file in files {
            if let children = file["children"] as? [[String: Any]], !children.isEmpty {
                result.append(contentsOf: flattenModelFiles(children))
            } else {
                result.append(file)
            }
        }
        return result
    }

    static func int(_ json: Any?, keys: [String]) -> Int? {
        guard let dict = json as? [String: Any] else { return nil }
        for key in keys {
            if let value = dict[key] as? Int { return value }
            if let value = dict[key] as? Double { return Int(value) }
            if let value = dict[key] as? String, let parsed = Int(value) { return parsed }
        }
        return nil
    }

    static func string(_ json: Any?, keys: [String]) -> String? {
        guard let dict = json as? [String: Any] else { return nil }
        for key in keys {
            if let value = dict[key] as? String, !value.isEmpty { return value }
            if let value = dict[key] as? Int { return String(value) }
        }
        return nil
    }

    static func htmlImageURLs(_ html: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"(?i)<img\b[^>]*src=["']([^"']+)["']"#) else { return [] }
        let ns = html as NSString
        return regex.matches(in: html, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            guard match.numberOfRanges > 1 else { return nil }
            return ns.substring(with: match.range(at: 1)).replacingOccurrences(of: "&amp;", with: "&")
        }
    }

    static func imageURLs(html: String, record: ModelRecord) -> [String] {
        uniqueURLs(record.galleryURLs + [record.coverURL].compactMap { $0 } + htmlImageURLs(html))
    }

    static func uniqueURLs(_ urls: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in urls {
            guard let url = PathSafety.remoteURL(raw.replacingOccurrences(of: "&amp;", with: "&")) else { continue }
            if seen.insert(url.absoluteString).inserted { result.append(url.absoluteString) }
        }
        return result
    }

    static func formatDuration(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 { return "\(hours) 小时 \(minutes) 分钟" }
        return "\(max(minutes, 1)) 分钟"
    }
}

private extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
