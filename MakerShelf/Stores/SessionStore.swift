import Darwin
import Foundation
import LocalAuthentication
import Observation
import Security

@MainActor @Observable
final class SessionStore {
    private(set) var states: [MakerSite: ConnectionState] = [
        .china: .disconnected, .international: .disconnected
    ]
    private(set) var keychainWarnings: [MakerSite: String] = [:]
    private var persistenceRetrySites: Set<MakerSite> = []
    @ObservationIgnored private var snapshots: [MakerSite: SiteSession] = [:]
    @ObservationIgnored private let client: MakerWorldClient
    @ObservationIgnored private var loadedSites: Set<MakerSite> = []
    @ObservationIgnored private var restoringSites: Set<MakerSite> = []
    @ObservationIgnored private var didRestoreAll = false
    @ObservationIgnored private var restoringAll = false

    init(client: MakerWorldClient) {
        self.client = client
    }

    func snapshot(_ site: MakerSite) -> SiteSession? { snapshots[site] }
    func isConnected(_ site: MakerSite) -> Bool { states[site]?.isConnected == true }
    func canRetryPersistence(_ site: MakerSite) -> Bool { persistenceRetrySites.contains(site) && snapshots[site] != nil }
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

        let loaded: KeychainStore.Loaded
        do {
            loaded = try KeychainStore.load(site)
        } catch {
            states[site] = .failed("无法读取钥匙串，请查看运行日志。")
            keychainWarnings[site] = "无法读取已保存的登录状态。"
            AppLog.write(.error, .account, "钥匙串读取失败", detail: "\(site.title)\n\(AppLog.errorDescription(error))")
            return false
        }
        if let persistenceError = loaded.persistenceError {
            persistenceRetrySites.insert(site)
            keychainWarnings[site] = "登录状态已读取，但持久访问权限未保存；下次启动可能再次请求授权，请查看运行日志。"
            AppLog.write(.error, .account, "钥匙串持久访问配置失败", detail: "\(site.title)\n\(AppLog.errorDescription(persistenceError))")
        } else {
            keychainWarnings[site] = nil
            persistenceRetrySites.remove(site)
        }
        guard let stored = loaded.session else {
            states[site] = .disconnected
            return false
        }
        snapshots[site] = stored
        states[site] = .connecting
        do {
            let (active, profile) = try await restoredProfile(stored, site: site)
            var next = active
            next.userId = profile.uid
            next.displayName = profile.name
            next.handle = profile.handle ?? next.handle
            next.avatarURL = profile.avatar
            snapshots[site] = next
            states[site] = .connected(name: profile.name, handle: next.handle)
            AppLog.write(.info, .account, "站点登录状态已恢复", detail: site.title)
            return true
        } catch {
            snapshots[site] = nil
            states[site] = .expired
            AppLog.write(.warning, .account, "站点登录状态恢复失败", detail: "\(site.title)\n\(AppLog.errorDescription(error))")
            return false
        }
    }

    /// 先用现有令牌读资料。网站明确拒绝时，再用这个站点自己的 refreshToken 换一次后重试。
    private func restoredProfile(_ stored: SiteSession, site: MakerSite) async throws -> (SiteSession, (uid: String, name: String, handle: String?, avatar: String?)) {
        do {
            return (stored, try await client.profile(site: site, session: stored))
        } catch let error as ShelfError where error.isSessionExpired {
            let refreshed = try await client.refresh(stored)
            try? KeychainStore.save(refreshed, for: site)
            AppLog.write(.info, .account, "已刷新站点访问令牌", detail: site.title)
            return (refreshed, try await client.profile(site: site, session: refreshed))
        }
    }

    func restoreStoredSessions() async {
        guard !didRestoreAll, !restoringAll else { return }
        restoringAll = true
        defer { restoringAll = false }
        for site in MakerSite.allCases {
            _ = await restoreIfNeeded(site)
        }
        didRestoreAll = MakerSite.allCases.allSatisfy { loadedSites.contains($0) }
    }

    func beginConnecting(_ site: MakerSite) { states[site] = .connecting }

    func failConnecting(_ site: MakerSite, message: String) {
        states[site] = .failed(message)
        // 登录组件的原始消息可能带有会话内容，只记录站点和阶段。
        AppLog.write(.error, .account, "站点登录窗口连接失败", detail: site.title)
    }

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
        let resolved = MakerSite.from(url: pageURL ?? site.webRoot) ?? site
        let relevant = cookies.filter { Self.isAuthCookie($0) && resolved.belongs(cookieDomain: $0.domain) }
        let namedToken = relevant.first { ["token", "accesstoken", "access_token"].contains($0.name.lowercased()) }?.value
        let token = Self.jwts(in: listed + Array(storage.values)).first
            ?? Self.extractToken(cookies: relevant, localStorage: storage)
            ?? namedToken.flatMap { $0.removingPercentEncoding ?? $0 }
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
            AppLog.write(.error, .account, "网页登录状态无法同步到接口", detail: resolved.title)
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
        do {
            try KeychainStore.save(session, for: resolved)
            keychainWarnings[site] = nil
            keychainWarnings[resolved] = nil
            persistenceRetrySites.remove(site)
            persistenceRetrySites.remove(resolved)
        } catch {
            persistenceRetrySites.formUnion([site, resolved])
            keychainWarnings[site] = "登录已连接，但未能保存到钥匙串；下次启动可能需要重新登录。"
            keychainWarnings[resolved] = keychainWarnings[site]
            AppLog.write(.error, .account, "登录状态保存失败", detail: "\(resolved.title)\n\(AppLog.errorDescription(error))")
        }
        states[site] = .connected(name: profile.name, handle: profile.handle)
        states[resolved] = .connected(name: profile.name, handle: profile.handle)
        AppLog.write(.info, .account, "站点登录已连接", detail: resolved.title)
    }

    func disconnect(_ site: MakerSite) {
        do {
            try KeychainStore.delete(site)
        } catch {
            // 删除失败时保留连接和重试入口，避免界面显示已断开、重启后账号却再次恢复。
            persistenceRetrySites.remove(site)
            keychainWarnings[site] = "未能删除已保存的登录状态，请再次断开连接或查看运行日志。"
            AppLog.write(.error, .account, "钥匙串登录状态删除失败",
                         detail: "\(site.title)\n\(AppLog.errorDescription(error))")
            return
        }
        AppLog.write(.info, .account, "断开站点连接", detail: site.title)
        snapshots[site] = nil
        keychainWarnings[site] = nil
        persistenceRetrySites.remove(site)
        loadedSites.insert(site)
        states[site] = .disconnected
    }

    /// 本次会话仍有效时，允许用户重试保存，避免取消系统确认后只能退出并重新登录。
    func retryPersistence(_ site: MakerSite) {
        guard let session = snapshots[site] else { return }
        do {
            try KeychainStore.save(session, for: site)
            keychainWarnings[site] = nil
            persistenceRetrySites.remove(site)
            AppLog.write(.info, .account, "登录状态已重新保存", detail: site.title)
        } catch {
            keychainWarnings[site] = "登录状态仍未能持久保存，请查看运行日志中的系统错误码。"
            AppLog.write(.error, .account, "登录状态重新保存失败",
                         detail: "\(site.title)\n\(AppLog.errorDescription(error))")
        }
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

/// 所有调用由会话存储串行发起；存储方式根据当前 App 的实际签名授权选择。
@MainActor
enum KeychainStore {
    private static let service = "com.makershelf.local"

    private enum Backend: String {
        case dataProtection = "数据保护钥匙串"
        case login = "登录钥匙串"
    }

    private struct SigningIdentity {
        let supportsDataProtection: Bool
        let fingerprint: String?
    }

    private static let signing = signingIdentity()
    private static var backend: Backend = {
        let value: Backend = signing.supportsDataProtection ? .dataProtection : .login
        AppLog.write(.info, .account, "已选择登录状态存储方式",
                     detail: "\(value.rawValue)；签名包含钥匙串访问组授权：\(signing.supportsDataProtection ? "是" : "否")")
        return value
    }()

    struct Loaded {
        let session: SiteSession?
        let persistenceError: Error?
    }

    enum Failure: LocalizedError {
        case operation(String, OSStatus)
        case invalidData

        var errorDescription: String? {
            switch self {
            case .operation(let operation, let status):
                let reason = SecCopyErrorMessageString(status, nil) as String? ?? "未知系统错误"
                return "\(operation)失败（\(status)）：\(reason)"
            case .invalidData:
                return "钥匙串中的登录数据无法解码。"
            }
        }
    }

    private static func account(_ site: MakerSite) -> String { "makershelf.session.\(site.rawValue)" }

    /// 账号名带上当前签名，避免去改旧安装包创建、当前程序没有所有权的记录。
    private static func ownedAccount(_ site: MakerSite) -> String {
        let stamp = signing.fingerprint.map { String($0.prefix(12)) } ?? "app"
        return "makershelf.session.owned.\(site.rawValue).\(stamp)"
    }

    private static func ownedAccountKey(_ site: MakerSite) -> String {
        "makershelf.keychain.ownedAccount.\(site.rawValue)"
    }

    private static func suppressLegacyKey(_ site: MakerSite) -> String {
        "makershelf.keychain.suppressLegacy.\(site.rawValue)"
    }

    /// 读取实际运行代码的签名，而不是仅检查工程里的 entitlements 文件。
    /// 临时签名没有 App ID / 访问组时，不能向数据保护钥匙串新增或更新条目。
    private static func signingIdentity() -> SigningIdentity {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any] else {
            return SigningIdentity(supportsDataProtection: false, fingerprint: nil)
        }
        let entitlements = values[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
        let appID = entitlements["com.apple.application-identifier"] as? String
            ?? entitlements["application-identifier"] as? String ?? ""
        let groups = entitlements["keychain-access-groups"] as? [String] ?? []
        let fingerprint = (values[kSecCodeInfoUnique as String] as? Data).map {
            $0.map { String(format: "%02x", $0) }.joined() + ":" + Bundle.main.bundleURL.path
        }
        return SigningIdentity(supportsDataProtection: !appID.isEmpty || groups.contains { !$0.isEmpty },
                               fingerprint: fingerprint)
    }

    /// 数据保护钥匙串继续用原来的账号键。登录钥匙串的新记录使用带签名的账号键。
    private static func query(site: MakerSite, backend: Backend, returnData: Bool = false) -> [String: Any] {
        query(account: account(site), backend: backend, returnData: returnData)
    }

    private static func query(account: String, backend: Backend, returnData: Bool = false) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        query[kSecUseDataProtectionKeychain as String] = backend == .dataProtection
        if returnData {
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
        }
        return query
    }

    /// 只有确认为缺少授权时才回退；用户拒绝、钥匙串锁定等错误仍按原样报告。
    static func save(_ session: SiteSession, for site: MakerSite) throws {
        do {
            try write(session, for: site, backend: backend)
        } catch {
            guard useLoginKeychain(after: error) else { throw error }
            try write(session, for: site, backend: .login)
        }
        // 正式签名写入数据保护钥匙串后，能删掉的旧登录记录就删掉；没有所有权时保留，避免 -25244 把保存判失败。
        if backend == .dataProtection { bestEffortRemoveLoginCopies(site) }
    }

    private static func write(_ session: SiteSession, for site: MakerSite, backend: Backend) throws {
        let data = try JSONEncoder().encode(session)
        if backend == .login {
            try writeLogin(data, site: site)
            return
        }
        var identity = query(site: site, backend: backend)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updated = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        switch updated {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            identity[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            identity[kSecAttrSynchronizable as String] = false
            identity[kSecAttrLabel as String] = "MakerShelf \(site.title)"
            identity.merge(attributes) { _, new in new }
            let added = SecItemAdd(identity as CFDictionary, nil)
            guard added == errSecSuccess else { throw Failure.operation("\(backend.rawValue)保存", added) }
        default:
            throw Failure.operation("\(backend.rawValue)更新", updated)
        }
    }

    /// 只写当前签名名下的新记录。不删除旧记录：临时签名没有旧项的所有权，删除会返回 -25244。
    private static func writeLogin(_ data: Data, site: MakerSite) throws {
        let account = ownedAccount(site)
        switch probe(account) {
        case .allowed:
            let status = SecItemUpdate(query(account: account, backend: .login) as CFDictionary,
                                       [kSecValueData as String: data] as CFDictionary)
            guard status == errSecSuccess else { throw Failure.operation("登录钥匙串更新", status) }
        case .notFound:
            try addLoginItem(data, account: account, site: site)
        case .interactionRequired, .unavailable:
            throw Failure.operation("登录钥匙串更新", errSecInteractionNotAllowed)
        case .failure(let status):
            throw Failure.operation("登录钥匙串检查", status)
        }
        rememberOwned(site)
    }

    static func load(_ site: MakerSite) throws -> Loaded {
        guard backend == .dataProtection else { return try loadLoginKeychain(site) }
        do {
            if let session = try read(query(site: site, backend: .dataProtection, returnData: true), source: "数据保护记录读取") {
                return Loaded(session: session, persistenceError: nil)
            }
        } catch {
            guard useLoginKeychain(after: error) else { throw error }
            return try loadLoginKeychain(site)
        }
        let login = try loadLoginKeychain(site)
        guard let legacy = login.session, login.persistenceError == nil else { return login }
        do {
            try write(legacy, for: site, backend: .dataProtection)
            try remove(site, backend: .login)
            return Loaded(session: legacy, persistenceError: nil)
        } catch {
            if useLoginKeychain(after: error) { return login }
            return Loaded(session: legacy, persistenceError: error)
        }
    }

    private static func loadLoginKeychain(_ site: MakerSite) throws -> Loaded {
        if let session = try readIfTrusted(ownedAccount(site)) {
            rememberOwned(site)
            return Loaded(session: session, persistenceError: nil)
        }
        if let remembered = UserDefaults.standard.string(forKey: ownedAccountKey(site)),
           remembered != ownedAccount(site) {
            if let adopted = try adopt(from: remembered, site: site) { return adopted }
        }
        if UserDefaults.standard.bool(forKey: suppressLegacyKey(site)) {
            return Loaded(session: nil, persistenceError: nil)
        }
        if let adopted = try adopt(from: account(site), site: site) { return adopted }
        return Loaded(session: nil, persistenceError: nil)
    }

    /// 从旧账号读出一次会话，再写入当前签名名下的新记录。读得到就不再尝试删除旧记录。
    private static func adopt(from sourceAccount: String, site: MakerSite) throws -> Loaded? {
        let interactive: Bool
        switch probe(sourceAccount) {
        case .notFound:
            return nil
        case .allowed:
            interactive = false
        case .interactionRequired, .unavailable:
            interactive = true
        case .failure(let status):
            throw Failure.operation("登录记录检查", status)
        }
        guard let session = try read(dataQuery(sourceAccount, interactive: interactive), source: "登录记录读取") else {
            return nil
        }
        do {
            let data = try JSONEncoder().encode(session)
            try addLoginItem(data, account: ownedAccount(site), site: site)
            rememberOwned(site)
            AppLog.write(.info, .account, "已写入当前 App 自己的钥匙串记录", detail: site.title)
            return Loaded(session: session, persistenceError: nil)
        } catch {
            AppLog.write(.error, .account, "当前 App 钥匙串记录保存失败",
                         detail: "\(site.title)\n\(AppLog.errorDescription(error))")
            return Loaded(session: session, persistenceError: error)
        }
    }

    private static func readIfTrusted(_ account: String) throws -> SiteSession? {
        switch probe(account) {
        case .notFound, .interactionRequired, .unavailable:
            return nil
        case .allowed:
            return try read(dataQuery(account, interactive: false), source: "登录记录读取")
        case .failure(let status):
            throw Failure.operation("登录记录检查", status)
        }
    }

    private static func addLoginItem(_ data: Data, account: String, site: MakerSite) throws {
        var item = noUI(query(account: account, backend: .login))
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "MakerShelf \(site.title)"
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        // 不附带自定义访问控制。当前进程创建的记录默认归自己所有；再设一层 ACL 会让系统多弹一次授权。
        let added = SecItemAdd(item as CFDictionary, nil)
        if added == errSecDuplicateItem {
            let updated = SecItemUpdate(query(account: account, backend: .login) as CFDictionary,
                                        [kSecValueData as String: data] as CFDictionary)
            guard updated == errSecSuccess else { throw Failure.operation("登录钥匙串保存", updated) }
            return
        }
        guard added == errSecSuccess else { throw Failure.operation("登录钥匙串保存", added) }
    }

    private static func rememberOwned(_ site: MakerSite) {
        UserDefaults.standard.set(ownedAccount(site), forKey: ownedAccountKey(site))
        UserDefaults.standard.set(false, forKey: suppressLegacyKey(site))
    }

    private enum Probe {
        case allowed
        case interactionRequired
        case unavailable
        case notFound
        case failure(OSStatus)
    }

    /// 只取属性和条目引用，不取密钥内容。直接要密钥时，即使声明禁止界面，macOS 仍可能弹出授权。
    private static func probe(_ account: String) -> Probe {
        var lookup = query(account: account, backend: .login)
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        lookup[kSecReturnAttributes as String] = true
        lookup[kSecReturnRef as String] = true
        lookup = noUI(lookup)
        var item: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &item)
        switch status {
        case errSecItemNotFound:
            return .notFound
        case errSecInteractionNotAllowed:
            return .interactionRequired
        case errSecSuccess:
            guard let values = item as? [String: Any],
                  let reference = values[kSecValueRef as String] else { return .unavailable }
            let keychainItem = unsafeDowncast(reference as AnyObject, to: SecKeychainItem.self)
            switch LoginKeychainACL.allowsCurrentApp(keychainItem) {
            case .allowed: return .allowed
            case .rejected: return .interactionRequired
            case .unknown: return .unavailable
            }
        default:
            return .failure(status)
        }
    }

    private static func dataQuery(_ account: String, interactive: Bool) -> [String: Any] {
        var lookup = query(account: account, backend: .login, returnData: true)
        if !interactive { lookup = noUI(lookup) }
        return lookup
    }

    private static func noUI(_ query: [String: Any]) -> [String: Any] {
        var query = query
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        query[kSecUseAuthenticationUI as String] = authenticationUIFail
        return query
    }

    private static let authenticationUIFail: CFString = {
        let fallback = "u_AuthUIF" as CFString
        guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW),
              let symbol = dlsym(handle, "kSecUseAuthenticationUIFail") else { return fallback }
        return symbol.assumingMemoryBound(to: CFString?.self).pointee ?? fallback
    }()

    private static func useLoginKeychain(after error: Error) -> Bool {
        guard backend == .dataProtection,
              let failure = error as? Failure,
              case .operation(_, let status) = failure, status == errSecMissingEntitlement else { return false }
        backend = .login
        AppLog.write(.warning, .account, "数据保护钥匙串缺少授权，改用登录钥匙串",
                     detail: "系统错误码：\(status)。当前进程后续读取和保存使用登录钥匙串，不再重复尝试迁移。")
        return true
    }

    static func delete(_ site: MakerSite) throws {
        bestEffortRemoveLoginCopies(site)
        UserDefaults.standard.set(true, forKey: suppressLegacyKey(site))
        UserDefaults.standard.removeObject(forKey: ownedAccountKey(site))
        if backend == .dataProtection { try remove(site, backend: .dataProtection) }
    }

    /// 旧记录往往不是当前临时签名创建的。删不掉时留下它，并用标记避免下次再读它。
    private static func bestEffortRemoveLoginCopies(_ site: MakerSite) {
        var accounts = [ownedAccount(site), account(site)]
        if let remembered = UserDefaults.standard.string(forKey: ownedAccountKey(site)) {
            accounts.append(remembered)
        }
        for account in Set(accounts) {
            let status = SecItemDelete(noUI(query(account: account, backend: .login)) as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound && status != errSecInvalidOwnerEdit {
                AppLog.write(.warning, .account, "登录钥匙串记录未能删除",
                             detail: "\(site.title) \(account) \(status)")
            }
        }
    }

    private static func remove(_ site: MakerSite, backend: Backend) throws {
        let status = SecItemDelete(query(site: site, backend: backend) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound || status == errSecInvalidOwnerEdit else {
            throw Failure.operation("\(backend.rawValue)删除", status)
        }
    }

    private static func read(_ query: [String: Any], source: String) throws -> SiteSession? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure.operation(source, status) }
        guard let data = item as? Data,
              let session = try? JSONDecoder().decode(SiteSession.self, from: data) else {
            throw Failure.invalidData
        }
        return session
    }
}

/// 在取密钥之前检查解密 ACL。路径相同但签名不同的旧授权仍会弹窗，所以要核对当前可执行文件。
private enum LoginKeychainACL {
    enum Decision { case allowed, rejected, unknown }

    static func allowsCurrentApp(_ item: SecKeychainItem) -> Decision {
        guard let copyAccess = symbol("SecKeychainItemCopyAccess", as: CopyAccess.self),
              let copyACLs = symbol("SecAccessCopyMatchingACLList", as: CopyACLList.self),
              let copyContents = symbol("SecACLCopyContents", as: CopyACLContents.self),
              let validate = symbol("SecTrustedApplicationValidateWithPath", as: ValidatePath.self)
        else { return .unknown }

        var access: SecAccess?
        guard copyAccess(item, &access) == errSecSuccess, let access,
              let rawList = copyACLs(access, kSecACLAuthorizationDecrypt)?.takeRetainedValue(),
              let acls = rawList as? [SecACL], !acls.isEmpty else { return .unknown }

        let paths = [Bundle.main.bundlePath, Bundle.main.executablePath].compactMap { $0 }
        guard !paths.isEmpty else { return .unknown }
        var incomplete = false
        for acl in acls {
            var applications: CFArray?
            var description: CFString?
            var selector = SecKeychainPromptSelector()
            guard copyContents(acl, &applications, &description, &selector) == errSecSuccess else {
                incomplete = true
                continue
            }
            if selector.rawValue != 0 { continue }
            guard let applications else { return .allowed }
            guard let trusted = applications as? [SecTrustedApplication] else {
                incomplete = true
                continue
            }
            let results: [OSStatus] = trusted.flatMap { application in
                paths.map { path in path.withCString { validate(application, $0) } }
            }
            if results.contains(errSecSuccess) { return .allowed }
            if results.isEmpty { incomplete = true }
        }
        return incomplete ? .unknown : .rejected
    }

    private typealias CopyAccess = @convention(c) (SecKeychainItem, UnsafeMutablePointer<SecAccess?>) -> OSStatus
    private typealias CopyACLList = @convention(c) (SecAccess, CFTypeRef) -> Unmanaged<CFArray>?
    private typealias CopyACLContents = @convention(c) (
        SecACL, UnsafeMutablePointer<CFArray?>, UnsafeMutablePointer<CFString?>,
        UnsafeMutablePointer<SecKeychainPromptSelector>) -> OSStatus
    private typealias ValidatePath = @convention(c) (SecTrustedApplication, UnsafePointer<CChar>) -> OSStatus

    private static let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW)

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let security, let pointer = dlsym(security, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }
}
