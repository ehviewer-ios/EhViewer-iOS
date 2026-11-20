import Foundation

/// 连接参数、二维码内容与本机地址选择（纯逻辑，可在 Linux 测试）。
///
/// Android 端没有二维码：发送端（WiFiServerActivity）开热点并监听 54321，
/// 接收端（WiFiClientActivity）直接连接 DHCP 网关地址（即热点主机）的 54321 端口。
/// 这里定义的二维码格式为 iOS 新增，Android 现有版本不会扫描它。
public enum TransferEndpoint {
    /// 对应 `WiFiServerActivity.PORT` / `WiFiClientActivity.PORT`
    public static let defaultPort: UInt16 = 54321
    /// Bonjour 服务类型（iOS 扩展；需在 Info.plist 的 NSBonjourServices 中声明）
    public static let bonjourType = "_ehviewer._tcp"
    /// 二维码 URL scheme / host
    public static let qrScheme = "ehviewer"
    public static let qrHost = "wifi-transfer"
    /// 二维码格式版本
    public static let qrVersion = 1

    /// 二维码内容：`ehviewer://wifi-transfer?host=192.168.1.5&port=54321&v=1`
    public static func qrString(host: String, port: UInt16 = defaultPort) -> String {
        var c = URLComponents()
        c.scheme = qrScheme
        c.host = qrHost
        c.queryItems = [
            URLQueryItem(name: "host", value: host),
            URLQueryItem(name: "port", value: String(port)),
            URLQueryItem(name: "v", value: String(qrVersion)),
        ]
        return c.string ?? "\(qrScheme)://\(qrHost)?host=\(host)&port=\(port)&v=\(qrVersion)"
    }

    /// 解析二维码 / 手输内容。接受：
    /// - `ehviewer://wifi-transfer?host=…&port=…`
    /// - `host:port`、`host`（端口默认 54321）、`[ipv6]:port`
    /// - 任意带 host 的 URL（如 `tcp://host:port`、`http://host:port`）
    public static func parse(_ text: String) -> (host: String, port: UInt16)? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.contains("://"), let c = URLComponents(string: s) {
            if c.scheme?.lowercased() == qrScheme {
                let items = c.queryItems ?? []
                guard let host = items.first(where: { $0.name == "host" })?.value, !host.isEmpty else { return nil }
                let port = items.first(where: { $0.name == "port" })?.value.flatMap { UInt16($0) } ?? defaultPort
                return (host, port)
            }
            guard let host = c.host, !host.isEmpty else { return nil }
            let port = c.port.flatMap { UInt16(exactly: $0) } ?? defaultPort
            return (host, port)
        }
        if s.hasPrefix("[") {
            guard let close = s.firstIndex(of: "]") else { return nil }
            let host = String(s[s.index(after: s.startIndex)..<close])
            let rest = s[s.index(after: close)...]
            if rest.isEmpty { return (host, defaultPort) }
            guard rest.hasPrefix(":"), let port = UInt16(rest.dropFirst()) else { return nil }
            return (host, port)
        }
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        switch parts.count {
        case 1: return (s, defaultPort)
        case 2:
            guard !parts[0].isEmpty, let port = UInt16(parts[1]) else { return nil }
            return (String(parts[0]), port)
        default:
            return (s, defaultPort)  // 裸 IPv6
        }
    }

    // MARK: - 本机地址选择

    /// 一个网络接口上的 IPv4 地址
    public struct InterfaceAddress: Sendable, Hashable {
        public var name: String
        public var address: String
        public var netmask: String?

        public init(name: String, address: String, netmask: String? = nil) {
            self.name = name; self.address = address; self.netmask = netmask
        }
    }

    /// 选出用于二维码的本机 IPv4：en0（Wi-Fi）优先；其次 bridge*（iOS 个人热点主机）、其他 en* / wlan* / eth*；
    /// 排除回环、VPN（utun/ipsec）、蜂窝（pdp_ip）、AWDL 等；169.254 链路本地地址最后考虑。
    /// 对应 Android `getWifiApIpAddress`（取名字含 "wlan" 的接口）
    public static func pickPrimaryIPv4(_ list: [InterfaceAddress]) -> InterfaceAddress? {
        func rank(_ a: InterfaceAddress) -> Int? {
            let n = a.name
            if a.address.hasPrefix("127.") || a.address == "0.0.0.0" { return nil }
            for bad in ["lo", "utun", "ipsec", "pdp_ip", "awdl", "llw", "anpi", "ap", "gif", "stf"] where n.hasPrefix(bad) {
                return nil
            }
            var r: Int
            if n == "en0" { r = 0 }
            else if n.hasPrefix("bridge") { r = 1 }
            else if n.hasPrefix("en") || n.hasPrefix("wlan") || n.hasPrefix("wl") { r = 2 }
            else if n.hasPrefix("eth") { r = 3 }
            else { r = 4 }
            if a.address.hasPrefix("169.254.") { r += 10 }
            return r
        }
        return list.enumerated()
            .compactMap { i, a in rank(a).map { (r: $0, i: i, a: a) } }
            .min { ($0.r, $0.i) < ($1.r, $1.i) }?.a
    }

    /// 根据地址与掩码猜测网关（网段第一个地址，如 192.168.43.57/24 → 192.168.43.1）。
    /// Android 接收端连接的是 DHCP 网关（热点主机）；iOS 拿不到 DHCP 网关，用此近似连接 Android 热点
    public static func gatewayGuess(address: String, netmask: String?) -> String? {
        guard let ip = ipv4ToUInt32(address) else { return nil }
        let mask = netmask.flatMap(ipv4ToUInt32) ?? 0xFFFF_FF00
        let network = ip & mask
        let gw = network | 1
        if gw == ip { return nil }
        return uint32ToIPv4(gw)
    }

    static func ipv4ToUInt32(_ s: String) -> UInt32? {
        let parts = s.split(separator: ".")
        guard parts.count == 4 else { return nil }
        var v: UInt32 = 0
        for p in parts {
            guard let b = UInt8(p) else { return nil }
            v = v << 8 | UInt32(b)
        }
        return v
    }

    static func uint32ToIPv4(_ v: UInt32) -> String {
        "\(v >> 24).\((v >> 16) & 0xFF).\((v >> 8) & 0xFF).\(v & 0xFF)"
    }
}

/// 服务端启动后的信息（`TransferServer.start()` 的返回值）
public struct TransferServerInfo: Sendable, Hashable {
    /// 本机 IPv4（无可用网络时为 nil）
    public var host: String?
    public var port: UInt16
    /// Bonjour 服务名（未启用时为 nil）
    public var bonjourName: String?

    public init(host: String?, port: UInt16, bonjourName: String? = nil) {
        self.host = host; self.port = port; self.bonjourName = bonjourName
    }

    /// 二维码内容（无 host 时为 nil）
    public var qrString: String? {
        host.map { TransferEndpoint.qrString(host: $0, port: port) }
    }
}
