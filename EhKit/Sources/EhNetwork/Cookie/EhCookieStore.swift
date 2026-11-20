import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Cookie 持久化抽象（不依赖 EhStorage）。只保存 persistent cookie
public protocol EhCookiePersistence: Sendable {
    func load() -> [EhCookie]
    func save(_ cookies: [EhCookie])
}

/// 不落盘
public struct InMemoryCookiePersistence: EhCookiePersistence {
    public init() {}
    public func load() -> [EhCookie] { [] }
    public func save(_ cookies: [EhCookie]) {}
}

/// JSON 文件持久化（原子写）。对应 Android `CookieDatabase`（okhttp3-cookie.db）
public struct JSONFileCookiePersistence: EhCookiePersistence {
    public let fileURL: URL
    public init(fileURL: URL) { self.fileURL = fileURL }

    public func load() -> [EhCookie] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([EhCookie].self, from: data)) ?? []
    }

    public func save(_ cookies: [EhCookie]) {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            try enc.encode(cookies).write(to: fileURL, options: .atomic)
        } catch {
            // 持久化失败不影响内存中的 cookie
        }
    }
}

/// 闭包持久化，便于接入任意存储
public struct ClosureCookiePersistence: EhCookiePersistence {
    let loader: @Sendable () -> [EhCookie]
    let saver: @Sendable ([EhCookie]) -> Void
    public init(load: @escaping @Sendable () -> [EhCookie], save: @escaping @Sendable ([EhCookie]) -> Void) {
        loader = load
        saver = save
    }
    public func load() -> [EhCookie] { loader() }
    public func save(_ cookies: [EhCookie]) { saver(cookies) }
}

/// Cookie 仓库。对应 Android `EhCookieStore extends CookieRepository`（+ `CookieSet` / `CookieDatabase`）。
/// 线程安全（内部加锁），所有方法同步可在任意线程调用
public final class EhCookieStore: @unchecked Sendable {
    public static let keyMemberId = "ipb_member_id"
    public static let keyPassHash = "ipb_pass_hash"
    public static let keyIgneous = "igneous"
    /// `EhConfig.KEY_CONTENT_WARNING`
    public static let keyContentWarning = "nw"
    /// `EhConfig.KEY_UCONFIG`
    public static let keyUConfig = "uconfig"

    public static let domainE = "e-hentai.org"
    public static let domainEx = "exhentai.org"
    public static let domainForums = "forums.e-hentai.org"
    static let hostE = URL(string: "https://e-hentai.org/")!
    static let hostEx = URL(string: "https://exhentai.org/")!

    /// `sTipsCookie`：nw=1（不显示内容警告），domain e-hentai.org，永久
    public static let tipsCookie = EhCookie.longLived(name: keyContentWarning, value: "1", domain: domainE)

    private struct Key: Hashable {
        let name: String, domain: String, path: String
        init(_ c: EhCookie) { name = c.name; domain = c.domain; path = c.path }
    }

    private let lock = NSLock()
    /// domain → (name, domain, path) → cookie
    private var map: [String: [Key: EhCookie]] = [:]
    private let persistence: EhCookiePersistence
    private let now: @Sendable () -> Date

    public init(persistence: EhCookiePersistence = InMemoryCookiePersistence(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.persistence = persistence
        self.now = now
        let nowMs = Self.millis(now())
        for c in persistence.load() where !c.isExpired(nowMillis: nowMs) {
            map[c.domain, default: [:]][Key(c)] = c
        }
    }

    private static func millis(_ d: Date) -> Int64 { Int64(d.timeIntervalSince1970 * 1000) }

    // MARK: 基本操作（对应 CookieRepository）

    /// 对应 `addCookie`：过期 cookie 表示删除
    public func add(_ cookie: EhCookie) {
        lock.lock()
        defer { lock.unlock() }
        addLocked(cookie)
        persistLocked()
    }

    public func add(_ cookies: [EhCookie]) {
        lock.lock()
        defer { lock.unlock() }
        for c in cookies { addLocked(c) }
        persistLocked()
    }

    private func addLocked(_ cookie: EhCookie) {
        if cookie.isExpired(nowMillis: Self.millis(now())) {
            map[cookie.domain]?[Key(cookie)] = nil
        } else {
            map[cookie.domain, default: [:]][Key(cookie)] = cookie
        }
    }

    private func persistLocked() {
        let all = map.values.flatMap(\.values).filter(\.persistent)
            .sorted { ($0.domain, $0.path, $0.name) < ($1.domain, $1.path, $1.name) }
        persistence.save(all)
    }

    /// 对应 OkHttp `CookieJar.saveFromResponse`
    public func store(setCookieHeaders headers: [String], for url: URL) {
        let d = now()
        let cookies = headers.compactMap { EhCookie.parse($0, url: url, now: d) }
        guard !cookies.isEmpty else { return }
        add(cookies)
    }

    /// 对应 `getCookies(HttpUrl)`：匹配的 cookie，按 path 长度降序；顺带清理过期项
    public func cookies(for url: URL) -> [EhCookie] {
        guard let host = url.host?.lowercased() else { return [] }
        lock.lock()
        defer { lock.unlock() }
        let nowMs = Self.millis(now())
        var accepted: [EhCookie] = []
        var removedPersistent = false
        for (domain, set) in map where EhCookie.domainMatch(host, domain) {
            for (k, c) in set {
                if c.isExpired(nowMillis: nowMs) {
                    map[domain]?[k] = nil
                    if c.persistent { removedPersistent = true }
                } else if c.matches(url) {
                    accepted.append(c)
                }
            }
        }
        if removedPersistent { persistLocked() }
        // RFC 6265 5.4：path 长的在前；同长度按名字稳定排序
        accepted.sort { $0.path.count != $1.path.count ? $0.path.count > $1.path.count : $0.name < $1.name }
        return accepted
    }

    /// 对应 `EhCookieStore.loadForRequest`：e-hentai.org 及子域去掉 nw / uconfig，追加 nw=1
    public func cookiesForRequest(_ url: URL) -> [EhCookie] {
        let cookies = cookies(for: url)
        guard let host = url.host?.lowercased(), EhCookie.domainMatch(host, Self.domainE) else { return cookies }
        var result = cookies.filter { $0.name != Self.keyContentWarning && $0.name != Self.keyUConfig }
        result.append(Self.tipsCookie)
        return result
    }

    /// 请求用 Cookie 头；无 cookie 返回 nil
    public func cookieHeader(for url: URL) -> String? {
        let c = cookiesForRequest(url)
        return c.isEmpty ? nil : c.map(\.pair).joined(separator: "; ")
    }

    /// 对应 `contains(HttpUrl, String)`
    public func contains(_ url: URL, name: String) -> Bool {
        cookies(for: url).contains { $0.name == name }
    }

    public var allCookies: [EhCookie] {
        lock.lock()
        defer { lock.unlock() }
        return map.values.flatMap(\.values)
    }

    /// 对应 `clear()`
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        map.removeAll()
        persistence.save([])
    }

    public func remove(name: String, domain: String) {
        lock.lock()
        defer { lock.unlock() }
        let d = EhCookie.canonicalDomain(domain)
        map[d] = map[d]?.filter { $0.key.name != name }
        persistLocked()
    }

    // MARK: 登录相关（对应 EhCookieStore / EhUtils / 各登录页）

    /// 对应 `hasSignedIn`：e-hentai.org 上同时有 ipb_member_id 与 ipb_pass_hash
    public var hasSignedIn: Bool {
        let c = cookies(for: Self.hostE)
        return c.contains { $0.name == Self.keyMemberId } && c.contains { $0.name == Self.keyPassHash }
    }

    /// 对应 `signOut()`：清空全部 cookie
    public func signOut() { clear() }

    /// 对应 `CookieSignInScene.storeCookie`：先登出，再为 e-hentai / exhentai / forums 三个域写入
    /// ipb_member_id、ipb_pass_hash、（非空时）igneous；domain cookie、永久
    public func setLoginCookies(memberId: String, passHash: String, igneous: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        map.removeAll()
        for domain in [Self.domainE, Self.domainEx, Self.domainForums] {
            addLocked(.longLived(name: Self.keyMemberId, value: memberId, domain: domain))
            addLocked(.longLived(name: Self.keyPassHash, value: passHash, domain: domain))
            if let igneous, !igneous.isEmpty {
                addLocked(.longLived(name: Self.keyIgneous, value: igneous, domain: domain))
            }
        }
        persistLocked()
    }

    /// 对应 `EhCookieStore.newCookie(cookie, newDomain, forcePersistent, forceLongLive, forceNotHostOnly)`
    public static func newCookie(_ c: EhCookie, domain newDomain: String, forcePersistent: Bool,
                                 forceLongLive: Bool, forceNotHostOnly: Bool) -> EhCookie {
        var n = EhCookie(name: c.name, value: c.value, domain: newDomain, path: c.path,
                         secure: c.secure, httpOnly: c.httpOnly, hostOnly: c.hostOnly && !forceNotHostOnly)
        if forceLongLive {
            n.expiresAt = EhCookie.maxDate
            n.persistent = true
        } else if c.persistent {
            n.expiresAt = c.expiresAt
            n.persistent = true
        } else if forcePersistent {
            n.expiresAt = EhCookie.maxDate
            n.persistent = true
        }
        return n
    }

    /// 对应 `WebViewSignInScene.onPageFinished`：把 WebView 中 https://e-hentai.org/ 可见的全部 cookie
    /// 以 domain cookie、永久的形式同时复制到 exhentai.org 与 e-hentai.org。
    /// 返回是否已拿到 ipb_member_id 与 ipb_pass_hash（即登录成功，可关闭登录页）
    @discardableResult
    public func importWebViewLoginCookies(_ webCookies: [EhCookie]) -> Bool {
        let visible = webCookies.filter { $0.matches(Self.hostE) }
        var getId = false, getHash = false
        var toAdd: [EhCookie] = []
        for c in visible {
            if c.name == Self.keyMemberId { getId = true } else if c.name == Self.keyPassHash { getHash = true }
            toAdd.append(Self.newCookie(c, domain: Self.domainEx, forcePersistent: true, forceLongLive: true, forceNotHostOnly: true))
            toAdd.append(Self.newCookie(c, domain: Self.domainE, forcePersistent: true, forceLongLive: true, forceNotHostOnly: true))
        }
        add(toAdd)
        return getId && getHash
    }

    /// 对应 `UConfigActivity.onDestroy`：WebView 中 uconfig 页的 cookie（`a=1; b=2` 形式）在表里站间共享，
    /// 分别按 e-hentai.org / exhentai.org 解析后改为 domain cookie、永久
    public func importSharedSiteCookies(cookieHeader: String) {
        var toAdd: [EhCookie] = []
        for piece in cookieHeader.split(separator: ";") {
            for url in [Self.hostE, Self.hostEx] {
                if let c = EhCookie.parse(String(piece), url: url, now: now()) {
                    toAdd.append(.longLived(name: c.name, value: c.value, domain: c.domain, path: c.path))
                }
            }
        }
        add(toAdd)
    }

    /// 对应 `MainActivity` / `IdentityCookiePreference`：从表里站 cookie 中取身份信息
    public func identityCookies() -> (memberId: String?, passHash: String?, igneous: String?) {
        var id: String?, hash: String?, ig: String?
        for c in cookies(for: Self.hostE) + cookies(for: Self.hostEx) {
            switch c.name {
            case Self.keyMemberId: id = c.value
            case Self.keyPassHash: hash = c.value
            case Self.keyIgneous: ig = c.value
            default: break
            }
        }
        return (id, hash, ig)
    }

    /// iOS 补充（Android 无对应自动逻辑）：把 e-hentai.org 的登录 cookie 复制到 exhentai.org（已存在的不覆盖）。
    /// 账号密码登录只拿到 .e-hentai.org 的 cookie，需要访问里站时可调用
    public func copyLoginCookiesToEx() {
        let e = cookies(for: Self.hostE)
        let ex = Set(cookies(for: Self.hostEx).map(\.name))
        let names = [Self.keyMemberId, Self.keyPassHash, Self.keyIgneous]
        let toAdd = e.filter { names.contains($0.name) && !ex.contains($0.name) }
            .map { Self.newCookie($0, domain: Self.domainEx, forcePersistent: true, forceLongLive: true, forceNotHostOnly: true) }
        if !toAdd.isEmpty { add(toAdd) }
    }
}

// MARK: - HTTPCookie 互转（供 WKWebView 同步）

extension EhCookie {
    /// 转为 `HTTPCookie`。非 hostOnly 的 domain 带前导点
    public var httpCookie: HTTPCookie? {
        var props: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: hostOnly ? domain : "." + domain,
            .path: path,
        ]
        if persistent, expiresAt != Int64.min {
            props[.expires] = Date(timeIntervalSince1970: TimeInterval(expiresAt) / 1000)
        } else if persistent {
            props[.expires] = Date(timeIntervalSince1970: 0)
        }
        if secure { props[.secure] = "TRUE" }
        if httpOnly { props[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        return HTTPCookie(properties: props)
    }

    /// 从 `HTTPCookie` 构造（WKWebView 导出）
    public init(httpCookie c: HTTPCookie) {
        let hostOnly = !c.domain.hasPrefix(".")
        let persistent = c.expiresDate != nil
        let exp = c.expiresDate.map { Int64($0.timeIntervalSince1970 * 1000) } ?? EhCookie.maxDate
        self.init(name: c.name, value: c.value, domain: c.domain, path: c.path.isEmpty ? "/" : c.path,
                  expiresAt: exp, persistent: persistent, secure: c.isSecure, httpOnly: c.isHTTPOnly, hostOnly: hostOnly)
    }
}

extension EhCookieStore {
    /// 导出为 HTTPCookie（url 为 nil 时导出全部）
    public func exportHTTPCookies(for url: URL? = nil) -> [HTTPCookie] {
        let list = url.map { cookies(for: $0) } ?? allCookies
        return list.compactMap(\.httpCookie)
    }

    /// 从 HTTPCookie 原样导入
    public func importHTTPCookies(_ cookies: [HTTPCookie]) {
        add(cookies.map(EhCookie.init(httpCookie:)))
    }

    /// WKWebView 登录页结束时调用，见 `importWebViewLoginCookies(_:)`
    @discardableResult
    public func importWebViewLoginCookies(httpCookies: [HTTPCookie]) -> Bool {
        importWebViewLoginCookies(httpCookies.map(EhCookie.init(httpCookie:)))
    }
}
