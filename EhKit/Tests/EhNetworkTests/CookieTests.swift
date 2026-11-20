import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import EhNetwork

@Suite struct CookieParseTests {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let eURL = URL(string: "https://e-hentai.org/g/123/abc/")!

    @Test func basicHostOnly() throws {
        let c = try #require(EhCookie.parse("sk=abc123", url: eURL, now: now))
        #expect(c.name == "sk")
        #expect(c.value == "abc123")
        #expect(c.domain == "e-hentai.org")
        #expect(c.hostOnly)
        #expect(!c.persistent)
        #expect(c.expiresAt == EhCookie.maxDate)
        // 默认 path = 请求路径去掉最后一段
        #expect(c.path == "/g/123/abc")
    }

    @Test func domainAttribute() throws {
        let c = try #require(EhCookie.parse(
            "ipb_member_id=42; expires=Wed, 21 Oct 2037 07:28:00 GMT; path=/; domain=.e-hentai.org; HttpOnly; Secure",
            url: URL(string: "https://forums.e-hentai.org/index.php")!, now: now))
        #expect(c.domain == "e-hentai.org")
        #expect(!c.hostOnly)
        #expect(c.persistent)
        #expect(c.httpOnly)
        #expect(c.secure)
        #expect(c.path == "/")
        #expect(c.expiresAt == 2_139_722_880_000)
    }

    @Test func maxAgeWinsAndNonPositiveExpires() throws {
        let c = try #require(EhCookie.parse("a=1; Max-Age=3600; Expires=Wed, 21 Oct 2037 07:28:00 GMT", url: eURL, now: now))
        #expect(c.expiresAt == 1_700_000_000_000 + 3_600_000)
        let d = try #require(EhCookie.parse("a=1; max-age=0", url: eURL, now: now))
        #expect(d.isExpired(nowMillis: 1_700_000_000_000))
        let e = try #require(EhCookie.parse("a=1; max-age=-5", url: eURL, now: now))
        #expect(e.expiresAt == Int64.min)
    }

    @Test func expiresFormats() {
        #expect(EhCookie.parseExpires("Wed, 21 Oct 2037 07:28:00 GMT") == 2_139_722_880_000)
        #expect(EhCookie.parseExpires("Wednesday, 21-Oct-37 07:28:00 GMT") == 2_139_722_880_000)
        #expect(EhCookie.parseExpires("Wed Oct 21 07:28:00 2037") == 2_139_722_880_000)
        #expect(EhCookie.parseExpires("garbage") == nil)
    }

    @Test func rejectsMismatchedDomainAndBadPairs() {
        #expect(EhCookie.parse("a=1; domain=exhentai.org", url: eURL, now: now) == nil)
        #expect(EhCookie.parse("a=1; domain=org", url: eURL, now: now) == nil)
        #expect(EhCookie.parse("novalue", url: eURL, now: now) == nil)
        #expect(EhCookie.parse("=1", url: eURL, now: now) == nil)
        // 子域不能匹配父域上的 IP 字面量形式
        #expect(!EhCookie.domainMatch("1.2.3.4", "2.3.4"))
        #expect(EhCookie.domainMatch("forums.e-hentai.org", "e-hentai.org"))
        #expect(!EhCookie.domainMatch("fakee-hentai.org", "e-hentai.org"))
    }

    @Test func matching() {
        let domainCookie = EhCookie(name: "a", value: "1", domain: "e-hentai.org", path: "/", hostOnly: false)
        #expect(domainCookie.matches(URL(string: "https://forums.e-hentai.org/")!))
        #expect(domainCookie.matches(URL(string: "http://e-hentai.org")!))
        let hostOnly = EhCookie(name: "a", value: "1", domain: "e-hentai.org", path: "/", hostOnly: true)
        #expect(!hostOnly.matches(URL(string: "https://forums.e-hentai.org/")!))
        let pathCookie = EhCookie(name: "a", value: "1", domain: "e-hentai.org", path: "/g", hostOnly: false)
        #expect(pathCookie.matches(URL(string: "https://e-hentai.org/g/1/")!))
        #expect(pathCookie.matches(URL(string: "https://e-hentai.org/g")!))
        #expect(!pathCookie.matches(URL(string: "https://e-hentai.org/gallery")!))
        let secure = EhCookie(name: "a", value: "1", domain: "e-hentai.org", secure: true)
        #expect(!secure.matches(URL(string: "http://e-hentai.org/")!))
        #expect(secure.matches(URL(string: "https://e-hentai.org/")!))
    }

    @Test func setCookieSplitter() {
        let joined = "a=1; expires=Wed, 21 Oct 2037 07:28:00 GMT; path=/, b=2; domain=.e-hentai.org,c=3"
        #expect(SetCookieSplitter.split(joined) == [
            "a=1; expires=Wed, 21 Oct 2037 07:28:00 GMT; path=/", "b=2; domain=.e-hentai.org", "c=3",
        ])
        #expect(SetCookieSplitter.split("single=1") == ["single=1"])
    }

    @Test func toStringForWebView() {
        let c = EhCookie.longLived(name: "nw", value: "1", domain: "e-hentai.org")
        #expect(c.description == "nw=1; expires=Fri, 31 Dec 9999 23:59:59 GMT; domain=e-hentai.org; path=/")
    }
}

/// 记录保存内容的持久化
final class RecordingPersistence: EhCookiePersistence, @unchecked Sendable {
    let lock = NSLock()
    var initial: [EhCookie]
    var saved: [EhCookie] = []
    init(_ initial: [EhCookie] = []) { self.initial = initial }
    func load() -> [EhCookie] { initial }
    func save(_ cookies: [EhCookie]) { lock.withLock { saved = cookies } }
}

@Suite struct CookieStoreTests {
    let e = URL(string: "https://e-hentai.org/")!
    let ex = URL(string: "https://exhentai.org/")!
    let forums = URL(string: "https://forums.e-hentai.org/index.php")!

    @Test func storeAndHeaderOrdering() {
        let store = EhCookieStore()
        store.store(setCookieHeaders: ["a=1; path=/", "b=2; path=/g", "c=3; domain=e-hentai.org; path=/"],
                    for: URL(string: "https://e-hentai.org/g/1/x")!)
        let list = store.cookies(for: URL(string: "https://e-hentai.org/g/1/")!)
        #expect(list.map(\.name) == ["b", "a", "c"])
        // 子域：只有 domain cookie
        #expect(store.cookies(for: forums).map(\.name) == ["c"])
    }

    @Test func loadForRequestTipsCookie() {
        let store = EhCookieStore()
        store.add(EhCookie.longLived(name: "nw", value: "0", domain: "e-hentai.org"))
        store.add(EhCookie.longLived(name: "uconfig", value: "x", domain: "e-hentai.org"))
        store.add(EhCookie.longLived(name: "sk", value: "s", domain: "e-hentai.org"))
        store.add(EhCookie.longLived(name: "uconfig", value: "y", domain: "exhentai.org"))
        let header = store.cookieHeader(for: e)
        #expect(header == "sk=s; nw=1")
        // 里站不处理
        #expect(store.cookieHeader(for: ex) == "uconfig=y")
        // 论坛属于 e-hentai.org 子域：domain cookie 可见，同样过滤并附加 nw=1
        #expect(store.cookieHeader(for: forums) == "sk=s; nw=1")
        // 无关站点
        #expect(store.cookieHeader(for: URL(string: "https://example.com/")!) == nil)
    }

    @Test func expiryRemovesAndOverwrite() {
        let store = EhCookieStore()
        store.store(setCookieHeaders: ["a=1; max-age=100"], for: e)
        store.store(setCookieHeaders: ["a=2; max-age=100"], for: e)
        #expect(store.cookies(for: e).map(\.value) == ["2"])
        store.store(setCookieHeaders: ["a=deleted; max-age=0"], for: e)
        #expect(store.cookies(for: e).isEmpty)
    }

    @Test func hasSignedInAndSignOut() {
        let store = EhCookieStore()
        #expect(!store.hasSignedIn)
        store.store(setCookieHeaders: ["ipb_member_id=1; domain=.e-hentai.org; path=/"], for: forums)
        #expect(!store.hasSignedIn)
        store.store(setCookieHeaders: ["ipb_pass_hash=h; domain=.e-hentai.org; path=/"], for: forums)
        #expect(store.hasSignedIn)
        store.signOut()
        #expect(!store.hasSignedIn)
        #expect(store.allCookies.isEmpty)
    }

    @Test func setLoginCookiesThreeDomains() {
        let store = EhCookieStore()
        store.add(EhCookie.longLived(name: "old", value: "x", domain: "e-hentai.org"))
        store.setLoginCookies(memberId: "42", passHash: "hash", igneous: "ig")
        #expect(store.hasSignedIn)
        #expect(!store.allCookies.contains { $0.name == "old" })
        for d in ["e-hentai.org", "exhentai.org", "forums.e-hentai.org"] {
            let names = Set(store.allCookies.filter { $0.domain == d }.map(\.name))
            #expect(names == ["ipb_member_id", "ipb_pass_hash", "igneous"])
        }
        #expect(store.allCookies.allSatisfy { $0.persistent && !$0.hostOnly && $0.expiresAt == EhCookie.maxDate })
        let id = store.identityCookies()
        #expect(id.memberId == "42" && id.passHash == "hash" && id.igneous == "ig")

        store.setLoginCookies(memberId: "1", passHash: "2", igneous: "")
        #expect(!store.allCookies.contains { $0.name == "igneous" })
        #expect(store.allCookies.count == 6)
    }

    @Test func webViewImportCopiesToBothSites() {
        let store = EhCookieStore()
        let web = [
            EhCookie(name: "ipb_member_id", value: "7", domain: "e-hentai.org", path: "/", hostOnly: false),
            EhCookie(name: "ipb_session_id", value: "s", domain: "forums.e-hentai.org", path: "/", hostOnly: true),
            EhCookie(name: "sk", value: "k", domain: "e-hentai.org", path: "/", hostOnly: true),
        ]
        #expect(!store.importWebViewLoginCookies(web))
        // forums 的 host-only cookie 对 e-hentai.org 不可见，不复制
        #expect(!store.allCookies.contains { $0.name == "ipb_session_id" })
        let exCookies = store.cookies(for: ex)
        #expect(Set(exCookies.map(\.name)) == ["ipb_member_id", "sk"])
        #expect(exCookies.allSatisfy { !$0.hostOnly && $0.persistent && $0.expiresAt == EhCookie.maxDate })
        // forceNotHostOnly：e-hentai.org 的 sk 也对子域可见
        #expect(store.cookies(for: forums).contains { $0.name == "sk" })

        let done = store.importWebViewLoginCookies([
            EhCookie(name: "ipb_member_id", value: "7", domain: "e-hentai.org", hostOnly: false),
            EhCookie(name: "ipb_pass_hash", value: "p", domain: "e-hentai.org", hostOnly: false),
        ])
        #expect(done)
        #expect(store.hasSignedIn)
        #expect(store.contains(ex, name: "ipb_pass_hash"))
    }

    @Test func sharedSiteCookiesForUConfig() {
        let store = EhCookieStore()
        store.importSharedSiteCookies(cookieHeader: "uconfig=tl_m; sk=abc")
        for url in [e, ex] {
            let c = store.cookies(for: url)
            #expect(Set(c.map(\.name)) == ["uconfig", "sk"])
            #expect(c.allSatisfy { $0.persistent && !$0.hostOnly })
        }
    }

    @Test func copyLoginCookiesToEx() {
        let store = EhCookieStore()
        store.store(setCookieHeaders: [
            "ipb_member_id=1; domain=.e-hentai.org; path=/; max-age=1000",
            "ipb_pass_hash=2; domain=.e-hentai.org; path=/; max-age=1000",
        ], for: forums)
        store.add(EhCookie.longLived(name: "ipb_pass_hash", value: "keep", domain: "exhentai.org"))
        store.copyLoginCookiesToEx()
        let ex = Dictionary(uniqueKeysWithValues: store.cookies(for: self.ex).map { ($0.name, $0.value) })
        #expect(ex == ["ipb_member_id": "1", "ipb_pass_hash": "keep"])
    }

    @Test func persistenceOnlyPersistent() {
        let p = RecordingPersistence()
        let store = EhCookieStore(persistence: p)
        store.store(setCookieHeaders: ["session=1", "persist=2; max-age=1000"], for: e)
        #expect(p.saved.map(\.name) == ["persist"])

        // 重新加载：过期项丢弃
        let expired = EhCookie(name: "old", value: "x", domain: "e-hentai.org", expiresAt: 1000, persistent: true)
        let reloaded = EhCookieStore(persistence: RecordingPersistence(p.saved + [expired]))
        #expect(reloaded.allCookies.map(\.name) == ["persist"])
    }

    @Test func jsonFilePersistence() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ehcookie-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("cookies.json")
        let s1 = EhCookieStore(persistence: JSONFileCookiePersistence(fileURL: file))
        s1.setLoginCookies(memberId: "1", passHash: "2")
        let s2 = EhCookieStore(persistence: JSONFileCookiePersistence(fileURL: file))
        #expect(s2.hasSignedIn)
        #expect(s2.allCookies.count == 6)
    }

    @Test func httpCookieRoundTrip() throws {
        // Apple 平台的 HTTPCookie 把有效期限制在 400 天内（RFC 6265bis），所以用 30 天后的整秒时间
        let expiresAt = (Int64(Date().timeIntervalSince1970) + 30 * 86_400) * 1000
        let c = EhCookie(name: "a", value: "1", domain: "e-hentai.org", path: "/", expiresAt: expiresAt,
                         persistent: true, secure: true, httpOnly: false, hostOnly: false)
        let h = try #require(c.httpCookie)
        #expect(h.domain == ".e-hentai.org")
        #expect(h.isSecure)
        let back = EhCookie(httpCookie: h)
        #expect(back == c)

        let session = EhCookie(name: "s", value: "v", domain: "exhentai.org", hostOnly: true)
        let hs = try #require(session.httpCookie)
        #expect(hs.domain == "exhentai.org")
        #expect(hs.expiresDate == nil)
        #expect(EhCookie(httpCookie: hs) == session)
    }

    @Test func newCookieSemantics() {
        let session = EhCookie(name: "a", value: "1", domain: "e-hentai.org", hostOnly: true)
        let n1 = EhCookieStore.newCookie(session, domain: "exhentai.org", forcePersistent: false, forceLongLive: false, forceNotHostOnly: false)
        #expect(n1.hostOnly && !n1.persistent && n1.domain == "exhentai.org")
        let n2 = EhCookieStore.newCookie(session, domain: "exhentai.org", forcePersistent: true, forceLongLive: false, forceNotHostOnly: true)
        #expect(!n2.hostOnly && n2.persistent && n2.expiresAt == EhCookie.maxDate)
        let p = EhCookie(name: "a", value: "1", domain: "e-hentai.org", expiresAt: 5_000_000_000_000, persistent: true)
        let n3 = EhCookieStore.newCookie(p, domain: "exhentai.org", forcePersistent: true, forceLongLive: false, forceNotHostOnly: false)
        #expect(n3.expiresAt == 5_000_000_000_000)
    }
}
