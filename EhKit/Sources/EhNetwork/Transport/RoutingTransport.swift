import Foundation
#if canImport(CFNetwork)
import CFNetwork
#endif

/// 按配置与 host 选择传输：
/// - `.domainFronting`：DF 开启、未检测到 VPN、未设显式代理、https，且 host 属于 DF 范围 → `DFTransport`（不发 SNI）
/// - `.customDNS`：host 命中用户 / 内置 hosts，或开启了 DoH → `DFTransport`（发 SNI，仅替换 DNS）
///   ——对应 Android 中 `EhHosts` 作为 OkHttp Dns 对所有请求生效；URLSession 无法自定义 DNS，只能走自有 HTTP/1.1 客户端
/// - 其余 → `URLSessionTransport`
/// 非 Apple 平台（无 Network.framework）一律 URLSession
public final class RoutingTransport: HTTPTransport, @unchecked Sendable {
    public enum Route: String, Sendable, Hashable {
        case urlSession, domainFronting, customDNS
    }

    public let config: EhNetworkConfig
    public let resolver: EhResolver
    private let urlSession: URLSessionTransport
    private let isVPNActive: @Sendable () -> Bool
    #if canImport(Network)
    private let df: DFTransport
    private let customDNS: DFTransport
    #endif

    public init(config: EhNetworkConfig, resolver: EhResolver, timeout: TimeInterval? = nil,
                isVPNActive: (@Sendable () -> Bool)? = nil) {
        self.config = config
        self.resolver = resolver
        self.isVPNActive = isVPNActive ?? { VPNDetector.isVPNActive() }
        let t = timeout ?? config.timeout
        urlSession = URLSessionTransport(timeout: t, proxy: config.proxy)
        #if canImport(Network)
        let base = DFTransport.Options(
            sendSNI: false, certificateValidation: config.dfCertificateValidation, timeout: t,
            maxIdlePerHost: config.maxIdleConnectionsPerHost, idleTimeout: config.idleConnectionTimeout
        )
        df = DFTransport(resolver: resolver, options: base)
        var sni = base
        sni.sendSNI = true
        sni.certificateValidation = .system
        customDNS = DFTransport(resolver: resolver, options: sni)
        #endif
    }

    /// 是否有 Network.framework
    public static var networkFrameworkAvailable: Bool {
        #if canImport(Network)
        return true
        #else
        return false
        #endif
    }

    /// 路由决策（纯函数，可测）
    public static func route(for url: URL, config: EhNetworkConfig, vpnActive: Bool,
                             networkFrameworkAvailable: Bool = RoutingTransport.networkFrameworkAvailable) -> Route {
        guard networkFrameworkAvailable,
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased(), !host.isEmpty, !EhIPAddress.isIPLiteral(host),
              !config.proxy.isExplicit else {
            return .urlSession
        }
        if scheme == "https", config.domainFronting, !(config.disableDFWhenVPN && vpnActive),
           config.dfHostPolicy == .all || EhBuiltInHosts.isEhHost(host) {
            return .domainFronting
        }
        if config.resolverOptions.staticAddresses(for: host) != nil || config.dnsOverHttps {
            return .customDNS
        }
        return .urlSession
    }

    public func route(for url: URL) -> Route {
        Self.route(for: url, config: config, vpnActive: config.domainFronting && config.disableDFWhenVPN ? isVPNActive() : false)
    }

    private func transport(for url: URL) -> HTTPTransport {
        #if canImport(Network)
        switch route(for: url) {
        case .domainFronting: return df
        case .customDNS: return customDNS
        case .urlSession: return urlSession
        }
        #else
        return urlSession
        #endif
    }

    public func send(_ request: EhHTTPRequest) async throws -> EhHTTPResponse {
        try await transport(for: request.url).send(request)
    }

    public func download(_ request: EhHTTPRequest, to fileURL: URL, progress: EhDownloadProgress?) async throws -> EhHTTPResponse {
        try await transport(for: request.url).download(request, to: fileURL, progress: progress)
    }

    /// 释放 DF 连接池中的空闲连接
    public func evictIdleConnections() async {
        #if canImport(Network)
        await df.evictIdleConnections()
        await customDNS.evictIdleConnections()
        #endif
    }
}

/// VPN 检测（对应 `AppHelper.checkVPN`）。Apple：系统代理设置 `__SCOPED__` 中出现 utun/tun/tap/ppp/ipsec 接口
public enum VPNDetector {
    public static func isVPNActive() -> Bool {
        #if canImport(CFNetwork) && canImport(Darwin)
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any],
              let scoped = settings["__SCOPED__"] as? [String: Any] else { return false }
        return scoped.keys.contains { key in
            ["tap", "tun", "ppp", "ipsec"].contains { key.contains($0) }
        }
        #else
        return false
        #endif
    }
}
