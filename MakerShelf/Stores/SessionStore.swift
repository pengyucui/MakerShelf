import Foundation
import Observation
import Security

@MainActor @Observable
final class SessionStore {
    private(set) var states: [MakerSite: ConnectionState] = [
        .china: .disconnected, .international: .disconnected
    ]
    @ObservationIgnored private var snapshots: [MakerSite: SiteSession] = [:]
    @ObservationIgnored private let client: MakerWorldClient
    @ObservationIgnored private var loadedSites: Set<MakerSite> = []
    @ObservationIgnored private var restoringSites: Set<MakerSite> = []
    @ObservationIgnored private var didRestoreAll = false

    init(client: MakerWorldClient) {
        self.client = client
    }

    func snapshot(_ site: MakerSite) -> SiteSession? { snapshots[site] }
    func isConnected(_ site: MakerSite) -> Bool { states[site]?.isConnected == true }
    func hasLoaded(_ site: MakerSite) -> Bool { loadedSites.contains(site) }
    var hasLoadedAnySite: Bool { !loadedSites.isEmpty }
    func connectedSites() -> Set<MakerSite> { Set(MakerSite.allCases.filter(isConnected)) }

    func displayName(_ site: MakerSite) -> String {
        switch states[site] {
        case .connected(let name, let handle):
            if let handle, !handle.isEmpty { return "\(name) · @\(handle)" }
            return name
        case .connecting: return "正在验证登录"
        case .expired: return "登录已过期"
        case .failed(let message): return message
        default: return "未连接"
        }
    }

    /// 只在用户进入账号页或执行联网操作时读取对应钥匙串记录。
    /// 每个站点在进程内只读一次，之后使用内存会话；打开模型库不会访问钥匙串。
    @discardableResult
    func restoreIfNeeded(_ site: MakerSite) async -> Bool {
        if loadedSites.contains(site) { return isConnected(site) }
        guard !restoringSites.contains(site) else { return isConnected(site) }
        restoringSites.insert(site)
        defer {
            restoringSites.remove(site)
            loadedSites.insert(site)
        }

        guard let stored = KeychainStore.load(site) else {
            states[site] = .disconnected
            return false
        }
        snapshots[site] = stored
        states[site] = .connecting
        do {
            let profile = try await client.profile(site: site, session: stored)
            var next = stored
            next.userId = profile.uid
            next.displayName = profile.name
            next.handle = profile.handle ?? next.handle
            next.avatarURL = profile.avatar
            snapshots[site] = next
            states[site] = .connected(name: profile.name, handle: next.handle)
            return true
        } catch {
            snapshots[site] = nil
            states[site] = .expired
            return false
        }
    }

    func restoreStoredSessions() async {
        guard !didRestoreAll else { return }
        for site in MakerSite.allCases {
            _ = await restoreIfNeeded(site)
        }
        didRestoreAll = true
    }

    func beginConnecting(_ site: MakerSite) { states[site] = .connecting }

    func failConnecting(_ site: MakerSite, message: String) { states[site] = .failed(message) }

    func cancelConnecting(_ site: MakerSite) {
        if states[site] == .connecting { states[site] = .disconnected }
    }

    func complete(captureData: Data, site: MakerSite) async -> Bool {
        states[site] = .connecting
        guard let dict = try? JSONSerialization.jsonObject(with: captureData) as? [String: Any] else {
            states[site] = .failed("登录窗口没有返回会话。")
            return false
        }
        if dict["cancelled"] as? Bool == true {
            states[site] = .disconnected
            return false
        }
        let pageURL = URL(string: dict["url"] as? String ?? "")
        let cookieDicts = dict["cookies"] as? [[String: Any]] ?? []
        let cookies: [HTTPCookie] = cookieDicts.compactMap { rec in
            guard let name = rec["name"] as? String, let value = rec["value"] as? String else { return nil }
            return HTTPCookie(properties: [
                .name: name,
                .value: value,
                .domain: rec["domain"] as? String ?? site.domain,
                .path: rec["path"] as? String ?? "/"
            ])
        }
        var storage: [String: String] = [:]
        if let raw = dict["storage"] as? [String: Any] {
            for (key, value) in raw { storage[key] = "\(value)" }
        }
        let listed = (dict["tokens"] as? [String]) ?? []
        let relevant = cookies.filter { Self.isAuthCookie($0) }
        let namedToken = relevant.first { ["token", "accesstoken", "access_token"].contains($0.name.lowercased()) }?.value
        let token = Self.jwts(in: listed + Array(storage.values)).first
            ?? Self.extractToken(cookies: relevant, localStorage: storage)
            ?? namedToken.flatMap { $0.removingPercentEncoding ?? $0 }
        let resolved = MakerSite.from(url: pageURL ?? site.webRoot) ?? site
        let pageUser = Self.profile(from: pageURL)
        var pageProfile: HarvestedProfile?
        if let json = dict["profile"], let parsed = MakerWorldClient.parseProfile(json) {
            pageProfile = HarvestedProfile(uid: parsed.uid, name: parsed.name, handle: parsed.handle, avatar: parsed.avatar)
        }
        if pageProfile == nil, let handle = dict["handle"] as? String, !handle.isEmpty {
            pageProfile = HarvestedProfile(uid: handle, name: handle, handle: handle, avatar: nil)
        }
        pageProfile = pageProfile ?? pageUser
        var session = SiteSession(
            site: resolved, token: token, refreshToken: Self.namedCookie(relevant, "refreshToken") ?? storage["refreshToken"],
            userId: pageProfile?.uid, handle: pageProfile?.handle, displayName: pageProfile?.name,
            avatarURL: pageProfile?.avatar,
            cookies: relevant.map { CookieRecord(name: $0.name, value: $0.value, domain: $0.domain, path: $0.path) },
            userAgent: dict["userAgent"] as? String,
            updatedAt: Date()
        )
        do {
            let profile = try await client.profile(site: resolved, session: session)
            apply(profile, to: &session, site: site, resolved: resolved)
            return true
        } catch {
            if let profile = pageProfile {
                apply((profile.uid, profile.name, profile.handle, profile.avatar), to: &session, site: site, resolved: resolved)
                return true
            }
            if relevant.contains(where: { $0.name.lowercased() == "token" || $0.name.lowercased() == "is_mw_user" }) {
                let name = pageUser?.name ?? "已登录用户"
                apply((pageUser?.uid ?? "web", name, pageUser?.handle, nil), to: &session, site: site, resolved: resolved)
                return true
            }
            let names = cookies.map(\.name).sorted().joined(separator: ",")
            states[site] = .failed("网页会话未同步到接口。当前页 \(pageURL?.path ?? "-")，Cookie \(cookies.count) 个（\(names.prefix(180))），令牌 \(listed.count) 个。请停在个人主页再试一次。")
            return false
        }
    }

    private func apply(_ profile: (uid: String, name: String, handle: String?, avatar: String?),
                       to session: inout SiteSession, site: MakerSite, resolved: MakerSite) {
        session.userId = profile.uid
        session.displayName = profile.name
        session.handle = profile.handle
        session.avatarURL = profile.avatar
        session.site = resolved
        snapshots[site] = session
        snapshots[resolved] = session
        loadedSites.insert(site)
        loadedSites.insert(resolved)
        KeychainStore.save(session)
        states[site] = .connected(name: profile.name, handle: profile.handle)
        states[resolved] = .connected(name: profile.name, handle: profile.handle)
    }

    func disconnect(_ site: MakerSite) {
        snapshots[site] = nil
        loadedSites.insert(site)
        KeychainStore.delete(site)
        states[site] = .disconnected
    }
}

extension SessionStore {
    struct HarvestedProfile {
        var uid: String
        var name: String
        var handle: String?
        var avatar: String?
    }

    static func isAuthCookie(_ cookie: HTTPCookie) -> Bool {
        let host = cookie.domain.lowercased()
        let name = cookie.name.lowercased()
        guard host.contains("makerworld") || host.contains("bambulab") || host.contains("bblmw") else { return false }
        return !name.hasPrefix("__cf") && name != "cf_clearance" && !name.hasPrefix("_ga") && !name.hasPrefix("_gid")
    }

    static func namedCookie(_ cookies: [HTTPCookie], _ name: String) -> String? {
        cookies.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    static func profile(from url: URL?) -> HarvestedProfile? {
        guard let url else { return nil }
        guard let handle = url.pathComponents.first(where: { $0.hasPrefix("@") }).map({ String($0.dropFirst()) }),
              !handle.isEmpty else { return nil }
        return HarvestedProfile(uid: handle, name: handle, handle: handle, avatar: nil)
    }

    static func extractToken(cookies: [HTTPCookie], localStorage: [String: String]) -> String? {
        let decoded = cookies.map { $0.value.removingPercentEncoding ?? $0.value }
        return jwts(in: decoded + Array(localStorage.values)).first
    }

    static func jwts(in texts: [String]) -> [String] {
        let pattern = #"eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#
        var found: [String] = []
        for text in texts {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) {
                if let swiftRange = Range(match.range, in: text) {
                    let token = String(text[swiftRange])
                    if MakerWorldClient.isJWT(token) { found.append(token) }
                }
            }
        }
        return Array(Set(found)).sorted { $0.count > $1.count }
    }

}

enum KeychainStore {
    private static let service = "com.makershelf.local"

    private static func account(_ site: MakerSite) -> String { "makershelf.session.\(site.rawValue)" }

    /// 数据保护钥匙串由当前 App 身份独占，读取时不再弹出「允许 / 始终允许」。
    /// 旧版写入的文件钥匙串条目会在第一次成功读取后迁移过来。
    private static func query(site: MakerSite, dataProtection: Bool, returnData: Bool = false) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(site)
        ]
        if dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        if returnData {
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
        }
        return query
    }

    static func save(_ session: SiteSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        var identity = query(site: session.site, dataProtection: true)
        let status = SecItemUpdate(identity as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status != errSecSuccess {
            if status != errSecItemNotFound {
                SecItemDelete(identity as CFDictionary)
            }
            identity[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            identity[kSecAttrSynchronizable as String] = false
            identity[kSecAttrLabel as String] = "MakerShelf \(session.site.title)"
            identity[kSecValueData as String] = data
            SecItemAdd(identity as CFDictionary, nil)
        }
        deleteLegacy(session.site)
    }

    static func load(_ site: MakerSite) -> SiteSession? {
        if let session = decode(query(site: site, dataProtection: true, returnData: true)) {
            return session
        }
        guard let session = decode(query(site: site, dataProtection: false, returnData: true)) else {
            return nil
        }
        save(session)
        return session
    }

    static func delete(_ site: MakerSite) {
        SecItemDelete(query(site: site, dataProtection: true) as CFDictionary)
        deleteLegacy(site)
    }

    private static func deleteLegacy(_ site: MakerSite) {
        SecItemDelete(query(site: site, dataProtection: false) as CFDictionary)
    }

    private static func decode(_ query: [String: Any]) -> SiteSession? {
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(SiteSession.self, from: data)
    }
}
