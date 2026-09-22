import Foundation

/// 站点是模型身份的一部分；两个站点即使模型编号相同也不能互相覆盖。
enum MakerSite: String, Codable, CaseIterable, Identifiable, Sendable {
    case china = "cn", international = "global"
    var id: String { rawValue }
    var title: String { self == .china ? "中文站" : "国际站" }
    var domain: String { self == .china ? "makerworld.com.cn" : "makerworld.com" }
    var apiHost: String { self == .china ? "api.bambulab.cn" : "api.bambulab.com" }
    var apiRoot: URL { URL(string: "https://\(apiHost)/v1")! }
    var webAPIRoot: URL { URL(string: "https://\(domain)/api/v1")! }
    var webRoot: URL { URL(string: "https://\(domain)")! }
    var loginURL: URL {
        URL(string: self == .china ? "https://makerworld.com.cn/zh" : "https://makerworld.com/zh")!
    }
    var localePath: String { self == .china ? "zh" : "en" }

    static func from(url: URL) -> MakerSite? {
        guard let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = url.host?.lowercased() else { return nil }
        return allCases.first { host == $0.domain || host == "www.\($0.domain)" }
    }

    func belongs(cookieDomain: String) -> Bool {
        let host = cookieDomain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        switch self {
        case .china:
            return host.contains("bambulab.cn") || host.contains("makerworld.com.cn") || host.contains("bblmw.cn")
        case .international:
            return (host.contains("bambulab.com") && !host.contains("bambulab.cn"))
                || (host.contains("makerworld.com") && !host.contains("makerworld.com.cn"))
                || host.contains("bblmw.com")
        }
    }
}

enum ArtworkSource: Hashable, Sendable {
    case bundled(String)
    case remote(URL)
    case file(URL)
}

struct ModelFile: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var name: String
    var kind: String
    var sizeBytes: Int
    var relativePath: String?
    var remoteHint: String?
}

/// 模型来源独立于站点。这样本地创建的模型不会被误判为演示数据，
/// 也不需要伪装成中文站或国际站内容。
enum ModelOrigin: String, Codable, Sendable {
    case demo
    case makerWorld
    case local
}

struct ModelRecord: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let author: String
    let imageName: String
    let category: String
    let site: MakerSite
    var origin: ModelOrigin
    var sizeMB: Double
    var fileCount: Int
    var isDownloaded: Bool
    let backgroundHex: String
    let summary: String
    let material: String
    let printTime: String
    var sortIndex: Int
    var designId: Int?
    var modelId: String?
    var authorId: String?
    var authorHandle: String?
    var coverURL: String?
    var localCoverPath: String?
    var galleryURLs: [String]
    var localImagePaths: [String]
    var sourceURL: String?
    var license: String?
    var descriptionHTML: String?
    var archiveFolder: String?
    var files: [ModelFile]
    var archivedAt: Date?
    var warnings: [String]
    var defaultInstanceId: Int?

    var isDemo: Bool { origin == .demo }
    var isLocal: Bool { origin == .local || id.hasPrefix("local:") }
    /// 已写入归档目录的模型都可以在本地编辑资料、文件和展示图片。
    var canEditLocally: Bool { isDownloaded && !isDemo && archiveFolder != nil }
    var sourceLabel: String { isLocal ? "本地模型" : site.title }
    /// 使用真实文件种类，避免将 STL、本地文件或尚未解析的模型一律标成 3MF。
    var fileFormatLabel: String {
        let kinds = Set(files.map { $0.kind.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            .filter { !$0.isEmpty })
        if kinds.count == 1 { return kinds.first ?? "模型文件" }
        return kinds.isEmpty ? "模型文件" : "多种格式"
    }
    var sourceHeading: String { isLocal ? "LOCAL MODEL" : "MAKERWORLD \(site.title)" }
    var plainSummary: String { Self.stripHTML(summary, collapseWhitespace: true) }

    var introductionHTML: String {
        // 已归档介绍中的图片地址已改写为本地路径，优先使用它才能离线阅读插图。
        if let descriptionHTML, !descriptionHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return descriptionHTML
        }
        return summary
    }

    init(id: String, title: String, subtitle: String, author: String, imageName: String, category: String,
         site: MakerSite, origin: ModelOrigin? = nil, sizeMB: Double, fileCount: Int, isDownloaded: Bool, backgroundHex: String,
         summary: String, material: String, printTime: String, sortIndex: Int, designId: Int? = nil,
         modelId: String? = nil, authorId: String? = nil, authorHandle: String? = nil, coverURL: String? = nil,
         localCoverPath: String? = nil, galleryURLs: [String] = [], localImagePaths: [String] = [],
         sourceURL: String? = nil, license: String? = nil, descriptionHTML: String? = nil,
         archiveFolder: String? = nil, files: [ModelFile] = [], archivedAt: Date? = nil,
         warnings: [String] = [], defaultInstanceId: Int? = nil) {
        self.id = id; self.title = title; self.subtitle = subtitle; self.author = author
        self.imageName = imageName; self.category = category; self.site = site
        self.origin = origin ?? (designId == nil ? .demo : .makerWorld); self.sizeMB = sizeMB
        self.fileCount = fileCount; self.isDownloaded = isDownloaded; self.backgroundHex = backgroundHex
        self.summary = summary; self.material = material; self.printTime = printTime; self.sortIndex = sortIndex
        self.designId = designId; self.modelId = modelId; self.authorId = authorId; self.authorHandle = authorHandle
        self.coverURL = coverURL; self.localCoverPath = localCoverPath; self.galleryURLs = galleryURLs
        self.localImagePaths = localImagePaths; self.sourceURL = sourceURL; self.license = license
        self.descriptionHTML = descriptionHTML; self.archiveFolder = archiveFolder; self.files = files
        self.archivedAt = archivedAt; self.warnings = warnings; self.defaultInstanceId = defaultInstanceId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        subtitle = try c.decode(String.self, forKey: .subtitle)
        author = try c.decode(String.self, forKey: .author)
        imageName = try c.decode(String.self, forKey: .imageName)
        category = try c.decode(String.self, forKey: .category)
        site = try c.decode(MakerSite.self, forKey: .site)
        let decodedDesignId = try c.decodeIfPresent(Int.self, forKey: .designId)
        origin = try c.decodeIfPresent(ModelOrigin.self, forKey: .origin)
            ?? (decodedDesignId == nil ? .demo : .makerWorld)
        sizeMB = try c.decode(Double.self, forKey: .sizeMB)
        fileCount = try c.decode(Int.self, forKey: .fileCount)
        isDownloaded = try c.decode(Bool.self, forKey: .isDownloaded)
        backgroundHex = try c.decode(String.self, forKey: .backgroundHex)
        summary = try c.decode(String.self, forKey: .summary)
        material = try c.decode(String.self, forKey: .material)
        printTime = try c.decode(String.self, forKey: .printTime)
        sortIndex = try c.decode(Int.self, forKey: .sortIndex)
        designId = decodedDesignId
        modelId = try c.decodeIfPresent(String.self, forKey: .modelId)
        authorId = try c.decodeIfPresent(String.self, forKey: .authorId)
        authorHandle = try c.decodeIfPresent(String.self, forKey: .authorHandle)
        coverURL = try c.decodeIfPresent(String.self, forKey: .coverURL)
        localCoverPath = try c.decodeIfPresent(String.self, forKey: .localCoverPath)
        galleryURLs = try c.decodeIfPresent([String].self, forKey: .galleryURLs) ?? []
        localImagePaths = try c.decodeIfPresent([String].self, forKey: .localImagePaths) ?? []
        sourceURL = try c.decodeIfPresent(String.self, forKey: .sourceURL)
        license = try c.decodeIfPresent(String.self, forKey: .license)
        descriptionHTML = try c.decodeIfPresent(String.self, forKey: .descriptionHTML)
        archiveFolder = try c.decodeIfPresent(String.self, forKey: .archiveFolder)
        files = try c.decodeIfPresent([ModelFile].self, forKey: .files) ?? []
        archivedAt = try c.decodeIfPresent(Date.self, forKey: .archivedAt)
        warnings = try c.decodeIfPresent([String].self, forKey: .warnings) ?? []
        defaultInstanceId = try c.decodeIfPresent(Int.self, forKey: .defaultInstanceId)
    }

    func artwork(archiveRoot: URL?) -> ArtworkSource {
        let localCandidates = ([localCoverPath].compactMap { $0 } + localImagePaths)
        if let path = Self.preferredStill(in: localCandidates) ?? localCandidates.first,
           let url = PathSafety.resolve(path, archiveRoot: archiveRoot),
           FileManager.default.fileExists(atPath: url.path) {
            return .file(url)
        }
        let remoteCandidates = ([coverURL].compactMap { $0 } + galleryURLs)
        if let raw = Self.preferredStill(in: remoteCandidates) ?? remoteCandidates.first,
           let url = PathSafety.remoteURL(raw) {
            return .remote(url)
        }
        if !imageName.isEmpty { return .bundled(imageName) }
        return .bundled("")
    }

    func gallery(archiveRoot: URL?) -> [ArtworkSource] {
        let local = localImagePaths.compactMap { path -> ArtworkSource? in
            guard let url = PathSafety.resolve(path, archiveRoot: archiveRoot),
                  FileManager.default.fileExists(atPath: url.path) else { return nil }
            return .file(url)
        }
        if !local.isEmpty { return local }
        let remote = galleryURLs.compactMap { PathSafety.remoteURL($0).map(ArtworkSource.remote) }
        if !remote.isEmpty { return remote }
        return [artwork(archiveRoot: archiveRoot)]
    }

    private static func preferredStill(in paths: [String]) -> String? {
        paths.first { path in
            let lower = path.lowercased()
            return !lower.contains(".gif") && !lower.contains(".webp")
        }
    }

    static func stripHTML(_ html: String, collapseWhitespace: Bool = true) -> String {
        var text = html.replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "(?i)</p>", with: "\n\n", options: .regularExpression)
            .replacingOccurrences(of: "(?i)</h[1-6]>", with: "\n\n", options: .regularExpression)
            .replacingOccurrences(of: "(?i)<li[^>]*>", with: "\n• ", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
        if collapseWhitespace {
            text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        } else {
            text = text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            text = text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum IntroBlock {
    case text(String)
    case image(ArtworkSource)
}

enum DescriptionBlocks {
    static func parse(_ source: String, archiveRoot: URL?, archiveFolder: String?, localImages: [String]) -> [IntroBlock] {
        // 归档 HTML 含有标题和样式包装；原生阅读只保留可见内容，不把 CSS 或脚本当作介绍文字。
        let html = source
            .replacingOccurrences(of: #"(?is)<(head|style|script|title)\b[^>]*>.*?</\1\s*>"#,
                                  with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?s)<!--.*?-->"#, with: "", options: .regularExpression)
        guard !html.isEmpty else { return [] }
        guard let regex = try? NSRegularExpression(pattern: #"(?is)<img\b[^>]*>"#) else {
            let text = ModelRecord.stripHTML(html, collapseWhitespace: false)
            return text.isEmpty ? [] : [.text(text)]
        }
        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        var blocks: [IntroBlock] = []
        var cursor = 0
        for match in matches {
            if match.range.location > cursor {
                let chunk = ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                if let text = visibleText(chunk) { blocks.append(.text(text)) }
            }
            let tag = ns.substring(with: match.range)
            if let src = imageSrc(tag),
               let source = resolveImage(src, archiveRoot: archiveRoot, archiveFolder: archiveFolder, localImages: localImages) {
                blocks.append(.image(source))
            }
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length, let text = visibleText(ns.substring(from: cursor)) {
            blocks.append(.text(text))
        }
        if blocks.isEmpty, let text = visibleText(html) {
            blocks.append(.text(text))
        }
        return blocks
    }

    private static func visibleText(_ html: String) -> String? {
        let text = ModelRecord.stripHTML(html, collapseWhitespace: false)
        return text.isEmpty ? nil : text
    }

    private static func imageSrc(_ tag: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"(?i)src\s*=\s*["']([^"']+)["']"#) else { return nil }
        let ns = tag as NSString
        guard let match = regex.firstMatch(in: tag, range: NSRange(location: 0, length: ns.length)), match.numberOfRanges > 1 else {
            return nil
        }
        return ns.substring(with: match.range(at: 1)).replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func resolveImage(_ src: String, archiveRoot: URL?, archiveFolder: String?,
                                     localImages: [String]) -> ArtworkSource? {
        let name = (src as NSString).lastPathComponent
        if let root = archiveRoot {
            var candidates: [String] = [src]
            if let folder = archiveFolder {
                candidates.append(contentsOf: [
                    folder + "/" + src,
                    folder + "/images/" + name,
                    (folder as NSString).appendingPathComponent(src)
                ])
            }
            candidates.append(contentsOf: localImages.filter { ($0 as NSString).lastPathComponent == name })
            for candidate in candidates {
                if let url = PathSafety.resolve(candidate, archiveRoot: root),
                   FileManager.default.fileExists(atPath: url.path) {
                    return .file(url)
                }
            }
        }
        if let url = PathSafety.remoteURL(src),
           let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) {
            return .remote(url)
        }
        return nil
    }
}

enum DownloadFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "全部状态", downloaded = "已下载", pending = "未下载"
    var id: String { rawValue }
}

enum ModelSort: String, CaseIterable, Identifiable, Sendable {
    case recent = "最近添加", name = "名称排序", size = "文件大小"
    var id: String { rawValue }
}

enum LibrarySource: String, CaseIterable, Identifiable, Sendable {
    case china = "中文站"
    case international = "国际站"
    case local = "本地模型"

    var id: String { rawValue }

    func matches(_ model: ModelRecord) -> Bool {
        switch self {
        case .china: return !model.isLocal && model.site == .china
        case .international: return !model.isLocal && model.site == .international
        case .local: return model.isLocal
        }
    }
}

enum LibraryLayout: String, CaseIterable { case grid, list }

struct LibraryQuery: Equatable, Sendable {
    var text = ""
    var source: LibrarySource?
    var category = "全部"
    var author = "全部作者"
    var status: DownloadFilter = .all
    var sort: ModelSort = .recent
}

struct LibraryStatistics: Sendable {
    var total = 0
    var downloaded = 0
    var authorCount = 0
    var localCount = 0
    var storedMB = 0.0
}

struct CatalogPage: Sendable {
    let records: [ModelRecord]
    let total: Int
    let statistics: LibraryStatistics
    let authors: [String]
    let categories: [String]
}

enum ImportSource: String, CaseIterable, Identifiable {
    case user = "用户主页", link = "模型链接", local = "本地模型"
    var id: String { rawValue }
}

/// 本地创建表单只保存轻量文字与用户选择的 URL。文件复制在后台 actor 中执行。
struct LocalModelDraft: Sendable {
    var title: String
    var subtitle: String
    var author: String
    var category: String
    var summary: String
    var material: String
    var printTime: String
    var modelFiles: [URL]
    var imageFiles: [URL]
}

enum UserTarget: String, CaseIterable, Identifiable {
    case current = "当前登录账号", specified = "指定用户（账号 / 作者）"
    var id: String { rawValue }
}

enum UserContent: String, CaseIterable, Identifiable, Sendable {
    case favorites = "收藏的模型", published = "发布的模型（作者作品）"
    var id: String { rawValue }
}

/// 导入意图与页面表单解耦，后续真实站点适配器可以复用同一契约。
struct ImportRequest: Sendable {
    enum Target: Sendable { case currentUser, user(String), model(URL) }
    let site: MakerSite
    let target: Target
    let content: UserContent
}

struct ImportPreview: Sendable {
    let records: [ModelRecord]
    let notice: String
    var total: Int
    var hasMore: Bool
}

struct ArchiveResult: Sendable {
    var record: ModelRecord
    var warnings: [String]
}

enum ConnectionState: Equatable, Sendable {
    case disconnected, connecting
    case connected(name: String, handle: String?)
    case expired, failed(String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

struct SiteSession: Codable, Sendable {
    var site: MakerSite
    var token: String?
    var refreshToken: String?
    var userId: String?
    var handle: String?
    var displayName: String?
    var avatarURL: String?
    var cookies: [CookieRecord]
    var userAgent: String?
    var updatedAt: Date

    var cookieHeader: String {
        cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }
}

struct CookieRecord: Codable, Sendable {
    var name: String
    var value: String
    var domain: String
    var path: String
}

enum ShelfError: LocalizedError {
    case invalidLink, missingUser, wrongSite, resourceMissing, invalidImage
    case notLoggedIn(MakerSite)
    case sessionExpired(MakerSite)
    case archiveFolderMissing
    case http(Int, String)
    case emptyImport
    case userNotFound
    case favoritesRequireCurrentUser
    case downloadFailed(String)
    case rateLimited
    case loginFailed(String)
    case needsVerification

    var errorDescription: String? {
        switch self {
        case .invalidLink: return "请输入有效的 MakerWorld 模型链接，地址需包含 /models/ 和模型编号。"
        case .missingUser: return "请输入用户名、用户 ID 或用户主页链接。"
        case .wrongSite: return "主页链接与所选站点不一致，请修改站点或链接。"
        case .resourceMissing: return "无法读取应用内的示例资源，请检查资源是否加入应用目标。"
        case .invalidImage: return "图片暂时无法显示。"
        case .notLoggedIn(let site): return "请先连接\(site.title)，再导入或下载该站点的内容。"
        case .sessionExpired(let site): return "\(site.title)登录已过期，请重新连接。"
        case .archiveFolderMissing: return "请先在设置中选择模型归档目录。"
        case .http(let code, let body): return "站点返回 \(code)：\(body)"
        case .emptyImport: return "没有获取到可导入的模型。请确认链接、用户或访问权限。"
        case .userNotFound: return "找不到该用户，请检查用户名、用户 ID、主页链接以及中文站 / 国际站选择。"
        case .favoritesRequireCurrentUser: return "收藏列表仅支持当前登录账号；指定作者可以读取其公开发布模型。"
        case .downloadFailed(let reason): return reason
        case .rateLimited: return "请求过于频繁，请稍后再试。"
        case .loginFailed(let reason): return reason
        case .needsVerification: return "账号需要邮箱验证码，请查收邮件后继续。"
        }
    }
}

enum MakerURL {
    static func designIdentity(from url: URL) -> (MakerSite, Int)? {
        guard let site = MakerSite.from(url: url),
              let position = url.pathComponents.firstIndex(of: "models"),
              position + 1 < url.pathComponents.count else { return nil }
        let token = url.pathComponents[position + 1]
        let digits = token.split(separator: "-").first.map(String.init) ?? token
        guard let designId = Int(digits) else { return nil }
        return (site, designId)
    }

    static func userReference(from raw: String, site: MakerSite) -> (MakerSite, String)? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if !value.contains("://") {
            let reference = value.hasPrefix("@") ? String(value.dropFirst()) : value
            return (site, reference.removingPercentEncoding ?? reference)
        }
        guard let url = URL(string: value), let detected = MakerSite.from(url: url) else { return nil }
        let components = url.pathComponents.map { $0.removingPercentEncoding ?? $0 }
        if let handle = components.first(where: { $0.hasPrefix("@") }) {
            let reference = String(handle.dropFirst())
            return (detected, reference)
        }
        if let userIndex = components.firstIndex(of: "u"),
           userIndex + 1 < components.count {
            return (detected, components[userIndex + 1])
        }
        if let last = components.last, last != "/" && !last.isEmpty && last != "zh" && last != "en" {
            return (detected, last.hasPrefix("@") ? String(last.dropFirst()) : last)
        }
        return nil
    }

    static func modelPage(site: MakerSite, designId: Int, slug: String?) -> URL {
        let tail = slug.flatMap { $0.isEmpty ? nil : "\(designId)-\($0)" } ?? "\(designId)"
        return site.webRoot.appendingPathComponent("\(site.localePath)/models/\(tail)")
    }
}

enum PathSafety {
    static func component(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = trimmed.replacingOccurrences(of: "[\\\\/:*?\"<>|]+", with: "_", options: .regularExpression)
        let collapsed = cleaned.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let clipped = String(collapsed.prefix(80)).trimmingCharacters(in: CharacterSet(charactersIn: " ._"))
        return clipped.isEmpty ? "item" : clipped
    }

    /// 将记录中的相对路径安全地拼接到归档根目录。绝对路径仅在仍位于当前归档根目录时接受，
    /// 同时拒绝 `..` 或符号链接造成的越界，避免读写归档目录以外的文件。
    static func resolve(_ stored: String, archiveRoot: URL?) -> URL? {
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let root = archiveRoot {
            let safeRoot = root.standardizedFileURL.resolvingSymlinksInPath()
            let candidate = (trimmed.hasPrefix("/")
                ? URL(fileURLWithPath: trimmed)
                : safeRoot.appendingPathComponent(trimmed))
                .standardizedFileURL
                .resolvingSymlinksInPath()
            let rootPath = safeRoot.path
            let candidatePath = candidate.path
            let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            guard candidatePath == rootPath || candidatePath.hasPrefix(rootPrefix) else { return nil }
            return candidate
        }
        if trimmed.hasPrefix("/") { return URL(fileURLWithPath: trimmed) }
        return nil
    }

    static func relative(from url: URL, toRoot root: URL) -> String {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let filePath = url.standardizedFileURL.resolvingSymlinksInPath().path
        var prefix = rootPath
        if prefix.hasSuffix("/") { prefix.removeLast() }
        if filePath == prefix { return "" }
        if filePath.hasPrefix(prefix + "/") {
            return String(filePath.dropFirst(prefix.count + 1))
        }
        return filePath
    }

    static func remoteURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("//") { return URL(string: "https:\(trimmed)") }
        return URL(string: trimmed)
    }
}
