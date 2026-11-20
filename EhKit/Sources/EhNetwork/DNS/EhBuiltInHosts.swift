import Foundation

/// 内置 IP 表。对应 Android `EhHosts.builtInHosts`（逐项照搬，含注释掉的条目说明、重复 IP 保留原样）
public enum EhBuiltInHosts {
    /// 受「内置 hosts」开关（`Settings.getBuiltInHosts`）控制
    public static let eHosts: [String: [String]] = [
        "e-hentai.org": [
            "104.20.18.168",
            "104.20.19.168",
            "172.66.132.196",
            "172.66.140.62",
            "104.20.18.168",
            "172.67.2.238",
            // "194.126.173.115"
        ],
        "repo.e-hentai.org": ["104.20.18.168", "104.20.19.168", "172.67.2.238"],
        "forums.e-hentai.org": ["172.66.132.196", "172.66.140.62"],
        "upld.e-hentai.org": ["89.149.221.236", "95.211.208.236"],
        "ehgt.org": [
            // "109.236.85.28", "62.112.8.21", "89.39.106.43",
            "185.132.132.79",
            "62.112.8.152",
            "185.132.132.76",
            "2a00:7c80:0:123::3a85",
            "2a00:7c80:0:12d::38a1",
            "2a00:7c80:0:13b::37a4",
        ],
        "raw.githubusercontent.com": ["151.101.0.133", "151.101.64.133", "151.101.128.133", "151.101.192.133"],
    ]

    /// 受「内置里站 hosts」开关（`Settings.getBuiltEXHosts`）控制
    public static let exHosts: [String: [String]] = [
        "exhentai.org": [
            "178.175.128.251",
            "178.175.128.252",
            "178.175.128.253",
            "178.175.128.254",
            "178.175.129.251",
            "178.175.129.252",
            "178.175.129.253",
            "178.175.129.254",
            "178.175.132.19",
            "178.175.132.20",
            "178.175.132.21",
            "178.175.132.22",
        ],
        "upld.exhentai.org": ["178.175.132.22", "178.175.129.254", "178.175.128.254"],
        "s.exhentai.org": [
            // "178.175.129.251", "178.175.129.252",
            "178.175.129.253",
            "178.175.129.254",
            // "178.175.128.251", "178.175.128.252",
            "178.175.128.253",
            "178.175.128.254",
            // "178.175.132.19", "178.175.132.20",
            "178.175.132.21",
            "178.175.132.22",
        ],
    ]

    /// 按两个开关组合出的内置表（与 Android static 块逻辑一致：开关关闭则对应条目不存在）
    public static func table(builtIn: Bool, builtInEx: Bool) -> [String: [String]] {
        var map: [String: [String]] = [:]
        if builtIn { map.merge(eHosts) { $1 } }
        if builtInEx { map.merge(exHosts) { $1 } }
        return map
    }

    public static func lookup(_ host: String, builtIn: Bool, builtInEx: Bool) -> [EhIPAddress]? {
        let h = host.lowercased()
        var ips: [String]?
        if builtIn { ips = eHosts[h] }
        if ips == nil, builtInEx { ips = exHosts[h] }
        guard let ips else { return nil }
        let addrs = ips.compactMap(EhIPAddress.init)
        return addrs.isEmpty ? nil : addrs
    }

    /// E-Hentai 系列域名（DF 默认只对这些域名生效）
    public static let ehDomainSuffixes = ["e-hentai.org", "exhentai.org", "ehgt.org", "ehwiki.org", "ehtracker.org"]

    /// host 是否属于 E-Hentai 系列（自身或子域）
    public static func isEhHost(_ host: String) -> Bool {
        let h = host.lowercased()
        return ehDomainSuffixes.contains { h == $0 || h.hasSuffix("." + $0) }
    }
}
