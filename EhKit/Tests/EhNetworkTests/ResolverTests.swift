import Foundation
import Testing
@testable import EhNetwork

/// 记录调用次数的桩
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _doh = 0, _sys = 0
    var doh: Int { lock.withLock { _doh } }
    var sys: Int { lock.withLock { _sys } }
    func hitDoH() { lock.withLock { _doh += 1 } }
    func hitSys() { lock.withLock { _sys += 1 } }
}

@Suite struct ResolverTests {
    static func makeResolver(_ options: EhResolverOptions, counter: Counter, dohFails: Bool = false) -> EhResolver {
        EhResolver(
            options: options,
            dohLookup: { _, _ in
                counter.hitDoH()
                if dohFails { throw EhTransportError.unresolvedHost("doh") }
                return ([EhIPAddress("9.9.9.9")!], 120)
            },
            systemLookup: { _ in
                counter.hitSys()
                return [EhIPAddress("8.8.8.8")!]
            }
        )
    }

    @Test func builtInTableCopiedVerbatim() {
        #expect(EhBuiltInHosts.eHosts["e-hentai.org"]?.count == 6)
        #expect(EhBuiltInHosts.eHosts["ehgt.org"]?.count == 6)
        #expect(EhBuiltInHosts.exHosts["exhentai.org"]?.count == 12)
        #expect(EhBuiltInHosts.exHosts["s.exhentai.org"]?.count == 6)
        #expect(Set(EhBuiltInHosts.eHosts.keys) == ["e-hentai.org", "repo.e-hentai.org", "forums.e-hentai.org",
                                                    "upld.e-hentai.org", "ehgt.org", "raw.githubusercontent.com"])
        #expect(Set(EhBuiltInHosts.exHosts.keys) == ["exhentai.org", "upld.exhentai.org", "s.exhentai.org"])
        // 所有 IP 可解析
        for ips in Array(EhBuiltInHosts.eHosts.values.joined()) + Array(EhBuiltInHosts.exHosts.values.joined()) {
            #expect(EhIPAddress(ips) != nil)
        }
        #expect(EhBuiltInHosts.table(builtIn: false, builtInEx: true).keys.contains("exhentai.org"))
        #expect(!EhBuiltInHosts.table(builtIn: false, builtInEx: true).keys.contains("e-hentai.org"))
        #expect(EhBuiltInHosts.isEhHost("s.exhentai.org"))
        #expect(EhBuiltInHosts.isEhHost("ehgt.org"))
        #expect(!EhBuiltInHosts.isEhHost("notexhentai.org"))
    }

    @Test func orderUserHostsFirst() async throws {
        let c = Counter()
        let r = Self.makeResolver(.init(userHosts: ["e-hentai.org": ["1.1.1.1"]], dnsOverHttps: true, shuffle: false), counter: c)
        let res = try await r.resolve("E-Hentai.org")
        #expect(res.source == .userHosts)
        #expect(res.addresses.map(\.description) == ["1.1.1.1"])
        #expect(c.doh == 0 && c.sys == 0)
    }

    @Test func builtInThenSwitches() async throws {
        let c = Counter()
        let r = Self.makeResolver(.init(builtInHosts: true, builtInExHosts: false, shuffle: false), counter: c)
        let e = try await r.resolve("e-hentai.org")
        #expect(e.source == .builtIn)
        #expect(e.addresses.first?.description == "104.20.18.168")
        // 里站开关关闭 → 系统解析
        let ex = try await r.resolve("exhentai.org")
        #expect(ex.source == .system)
        #expect(c.sys == 1)

        await r.update(options: .init(builtInHosts: false, builtInExHosts: true, shuffle: false))
        #expect(try await r.resolve("exhentai.org").source == .builtIn)
        #expect(try await r.resolve("e-hentai.org").source == .system)
    }

    @Test func dohThenSystemAndCache() async throws {
        let c = Counter()
        let r = Self.makeResolver(.init(builtInHosts: false, builtInExHosts: false, dnsOverHttps: true, shuffle: false), counter: c)
        let a = try await r.resolve("example.org")
        #expect(a.source == .doh)
        #expect(a.addresses.map(\.description) == ["9.9.9.9"])
        _ = try await r.resolve("example.org")
        #expect(c.doh == 1) // 命中缓存
        await r.clearCache()
        _ = try await r.resolve("example.org")
        #expect(c.doh == 2)
        #expect(c.sys == 0)
    }

    @Test func dohFailureFallsBackToSystem() async throws {
        let c = Counter()
        let r = Self.makeResolver(.init(builtInHosts: false, builtInExHosts: false, dnsOverHttps: true), counter: c, dohFails: true)
        let a = try await r.resolve("example.org")
        #expect(a.source == .system)
        #expect(c.doh == 1 && c.sys == 1)
    }

    @Test func ipLiteralAndSystemCache() async throws {
        let c = Counter()
        let r = Self.makeResolver(.init(builtInHosts: false, builtInExHosts: false), counter: c)
        #expect(try await r.resolve("1.2.3.4").source == .literal)
        #expect(try await r.resolve("[::1]").addresses.first?.family == .v6)
        _ = try await r.resolve("example.org")
        _ = try await r.resolve("example.org")
        #expect(c.sys == 1)
        #expect(c.doh == 0)
    }

    @Test func realSystemResolverLocalhost() async throws {
        let addrs = try await SystemResolver.lookup("localhost")
        #expect(!addrs.isEmpty)
    }
}

@Suite struct RoutingTests {
    func url(_ s: String) -> URL { URL(string: s)! }

    @Test func routes() {
        var cfg = EhNetworkConfig()
        cfg.domainFronting = true
        let r = { (u: String, vpn: Bool) in RoutingTransport.route(for: self.url(u), config: cfg, vpnActive: vpn, networkFrameworkAvailable: true) }
        #expect(r("https://e-hentai.org/", false) == .domainFronting)
        #expect(r("https://s.exhentai.org/t/x.jpg", false) == .domainFronting)
        // VPN 下 DF 关闭，但仍命中内置 hosts → 自定义 DNS
        #expect(r("https://e-hentai.org/", true) == .customDNS)
        // 非 E 站且无映射
        #expect(r("https://abc.hath.network/h/x.jpg", false) == .urlSession)
        // raw.githubusercontent.com 在内置表里 → 自定义 DNS
        #expect(r("https://raw.githubusercontent.com/x", false) == .customDNS)
        #expect(r("https://1.2.3.4/", false) == .urlSession)
        // http 不做 DF（无 TLS），但有内置映射
        #expect(r("http://e-hentai.org/", false) == .customDNS)

        cfg.dfHostPolicy = .all
        #expect(r("https://abc.hath.network/h/x.jpg", false) == .domainFronting)
        cfg.dfHostPolicy = .ehDomains

        cfg.proxyType = .socks
        cfg.proxyHost = "127.0.0.1"
        cfg.proxyPort = 1080
        #expect(r("https://e-hentai.org/", false) == .urlSession)
        // 端口非法 → 回落系统代理，DF 正常
        cfg.proxyPort = 0
        #expect(cfg.proxy == .system)
        #expect(r("https://e-hentai.org/", false) == .domainFronting)

        cfg.domainFronting = false
        cfg.builtInHosts = false
        cfg.builtInExHosts = false
        #expect(r("https://e-hentai.org/", false) == .urlSession)
        cfg.dnsOverHttps = true
        #expect(r("https://example.com/", false) == .customDNS)
        cfg.dnsOverHttps = false
        cfg.userHosts = ["example.com": ["1.1.1.1"]]
        #expect(r("https://example.com/", false) == .customDNS)

        // 无 Network.framework
        #expect(RoutingTransport.route(for: url("https://e-hentai.org/"), config: EhNetworkConfig(), vpnActive: false,
                                       networkFrameworkAvailable: false) == .urlSession)
    }

    @Test func proxyDictionary() {
        #expect(URLSessionTransport.proxyDictionary(.system) == nil)
        #expect(URLSessionTransport.proxyDictionary(.direct)?.isEmpty == true)
        let http = URLSessionTransport.proxyDictionary(.http(host: "10.0.0.1", port: 8080))
        #expect(http?["HTTPSProxy"] as? String == "10.0.0.1")
        #expect(http?["HTTPSPort"] as? Int == 8080)
        let socks = URLSessionTransport.proxyDictionary(.socks(host: "h", port: 1))
        #expect(socks?["SOCKSEnable"] as? Int == 1)
    }
}
