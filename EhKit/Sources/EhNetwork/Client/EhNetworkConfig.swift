import Foundation

/// 代理类型。数值与 Android `EhProxySelector.TYPE_*` 一致
public enum EhProxyType: Int, Codable, Sendable, Hashable, CaseIterable {
    case direct = 0
    case system = 1
    case http = 2
    case socks = 3
}

/// 生效的代理设置
public enum EhProxySetting: Sendable, Hashable {
    /// 不使用代理
    case direct
    /// 跟随系统
    case system
    case http(host: String, port: Int)
    case socks(host: String, port: Int)

    /// 是否为显式代理（HTTP / SOCKS）。显式代理下不走 DF
    public var isExplicit: Bool {
        switch self {
        case .http, .socks: return true
        default: return false
        }
    }
}

/// DF 证书校验方式
public enum EhCertificateValidation: String, Codable, Sendable, Hashable {
    /// 系统信任链 + 按真实域名校验（对应 Android：系统 X509TrustManager + OkHostnameVerifier）
    case system
    /// 不校验（对应 Android 初始化系统 TrustManager 失败时回落的 `EhX509TrustManager` 全信任；
    /// 注意 Android 那条路径仍会做主机名校验，这里完全不校验，仅供调试）
    case none
}

/// DF 作用范围
public enum EhDFHostPolicy: String, Codable, Sendable, Hashable {
    /// 仅 E-Hentai 系列域名（e-hentai.org / exhentai.org / ehgt.org 等及子域）——iOS 默认
    case ehDomains
    /// 所有 HTTPS 请求（Android `EhSSLSocketFactory` 的实际行为：开关打开即对所有连接生效）
    case all
}

/// 网络配置（值类型，可整体替换）。字段对应 Android `Settings` 中的网络相关项
public struct EhNetworkConfig: Sendable, Hashable {
    /// Chrome 118 UA。对应 `ChromeRequestBuilder.CHROME_USER_AGENT`
    public static let chromeUserAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/118.0.0.0 Safari/537.36"
    /// 对应 `CHROME_ACCEPT`（Android 对所有请求都用这个值，照搬）
    public static let chromeAccept = "image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8"
    public static let chromeAcceptLanguage = "zh-CN,zh;q=0.9,en-US;q=0.8,en;q=0.7"

    public var site: EhSite = .e

    // MARK: DF / hosts / DoH
    /// 域前置（`Settings.getDF`，Android 默认 true）
    public var domainFronting: Bool = true
    public var dfHostPolicy: EhDFHostPolicy = .ehDomains
    public var dfCertificateValidation: EhCertificateValidation = .system
    /// 检测到 VPN 时不启用 DF（对应 `AppHelper.checkVPN`）
    public var disableDFWhenVPN: Bool = true
    /// 内置 hosts（`Settings.getBuiltInHosts`，默认 true）
    public var builtInHosts: Bool = true
    /// 内置里站 hosts（`Settings.getBuiltEXHosts`，默认 true）
    public var builtInExHosts: Bool = true
    /// DoH（`Settings.getDoH`，默认 false）
    public var dnsOverHttps: Bool = false
    public var dohServer: URL = DoHClient.defaultServer
    /// 用户自定义 hosts（host → IP 列表）
    public var userHosts: [String: [String]] = [:]

    // MARK: 代理（`Settings.getProxyType / getProxyIp / getProxyPort`）
    public var proxyType: EhProxyType = .system
    public var proxyHost: String?
    public var proxyPort: Int = -1

    // MARK: 请求
    public var userAgent: String = EhNetworkConfig.chromeUserAgent
    public var accept: String = EhNetworkConfig.chromeAccept
    public var acceptLanguage: String = EhNetworkConfig.chromeAcceptLanguage
    /// 普通请求超时（Android connect/read/write 均 10s）
    public var timeout: TimeInterval = 10
    /// 图片请求超时（Android 图片 client 20s）
    public var imageTimeout: TimeInterval = 20
    /// 最大重定向次数（OkHttp 为 20）
    public var maxRedirects: Int = 20
    /// 每个 host:port 最多保留的空闲连接数（DF 传输层连接池）
    public var maxIdleConnectionsPerHost: Int = 6
    /// 空闲连接保活时间
    public var idleConnectionTimeout: TimeInterval = 120

    public init() {}

    /// 对应 `EhProxySelector.select`：HTTP/SOCKS 需 IP 非空且端口合法，否则回落系统代理
    public var proxy: EhProxySetting {
        switch proxyType {
        case .direct: return .direct
        case .system: return .system
        case .http, .socks:
            guard let host = proxyHost?.trimmingCharacters(in: .whitespaces), !host.isEmpty,
                  (1...65535).contains(proxyPort) else { return .system }
            return proxyType == .http ? .http(host: host, port: proxyPort) : .socks(host: host, port: proxyPort)
        }
    }

    public var resolverOptions: EhResolverOptions {
        EhResolverOptions(
            userHosts: userHosts, builtInHosts: builtInHosts, builtInExHosts: builtInExHosts,
            dnsOverHttps: dnsOverHttps, dohServer: dohServer
        )
    }
}
