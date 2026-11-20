import Foundation

/// 解析器选项（从 `EhNetworkConfig` 派生）
public struct EhResolverOptions: Sendable, Hashable {
    /// 用户自定义 hosts：host → IP 列表。对应 Android `Hosts`（hosts.db，一个 host 一个 IP；这里允许多个）
    public var userHosts: [String: [String]]
    /// 内置 hosts（`Settings.getBuiltInHosts`）
    public var builtInHosts: Bool
    /// 内置里站 hosts（`Settings.getBuiltEXHosts`）
    public var builtInExHosts: Bool
    /// DoH（`Settings.getDoH`）
    public var dnsOverHttps: Bool
    public var dohServer: URL
    /// 是否打乱顺序（Android 每次都 shuffle；测试时关闭）
    public var shuffle: Bool

    public init(
        userHosts: [String: [String]] = [:], builtInHosts: Bool = true, builtInExHosts: Bool = true,
        dnsOverHttps: Bool = false, dohServer: URL = DoHClient.defaultServer, shuffle: Bool = true
    ) {
        self.userHosts = userHosts
        self.builtInHosts = builtInHosts
        self.builtInExHosts = builtInExHosts
        self.dnsOverHttps = dnsOverHttps
        self.dohServer = dohServer
        self.shuffle = shuffle
    }

    /// 用户 hosts 中的地址（host 小写匹配）
    public func userAddresses(for host: String) -> [EhIPAddress]? {
        let h = host.lowercased()
        guard let ips = userHosts[h] ?? userHosts.first(where: { $0.key.lowercased() == h })?.value else { return nil }
        let addrs = ips.compactMap(EhIPAddress.init)
        return addrs.isEmpty ? nil : addrs
    }

    /// 是否存在静态映射（用户 hosts 或内置 hosts），不发网络请求
    public func staticAddresses(for host: String) -> (addresses: [EhIPAddress], source: EhResolution.Source)? {
        if let a = userAddresses(for: host) { return (a, .userHosts) }
        if builtInHosts || builtInExHosts,
           let a = EhBuiltInHosts.lookup(host, builtIn: builtInHosts, builtInEx: builtInExHosts) {
            return (a, .builtIn)
        }
        return nil
    }
}

public struct EhResolution: Sendable, Hashable {
    public enum Source: String, Sendable, Hashable { case literal, userHosts, builtIn, doh, system }
    public var addresses: [EhIPAddress]
    public var source: Source
    public init(addresses: [EhIPAddress], source: Source) {
        self.addresses = addresses
        self.source = source
    }
}

/// 地址解析。对应 Android `EhHosts.lookup`：
/// 用户 hosts → 内置 hosts（两个开关）→ DoH（开关）→ 系统解析（getaddrinfo）。
/// 与 Android 的差异：DoH 抛错时继续回落系统解析（Android 会直接抛 UnknownHostException）。
/// DoH / 系统结果带 TTL 缓存。
public actor EhResolver {
    public typealias DoHLookup = @Sendable (_ host: String, _ server: URL) async throws -> (addresses: [EhIPAddress], ttl: TimeInterval?)
    public typealias SystemLookup = @Sendable (_ host: String) async throws -> [EhIPAddress]

    public private(set) var options: EhResolverOptions
    private let dohLookup: DoHLookup
    private let systemLookup: SystemLookup
    private var cache: [String: (resolution: EhResolution, expires: Date)] = [:]

    /// 系统解析缓存时间
    public var systemTTL: TimeInterval = 60
    /// DoH TTL 上下限
    public var dohTTLRange: ClosedRange<TimeInterval> = 30...3600

    public init(options: EhResolverOptions = .init(), dohLookup: DoHLookup? = nil, systemLookup: SystemLookup? = nil) {
        self.options = options
        self.dohLookup = dohLookup ?? { host, server in try await DoHClient(server: server).lookup(host) }
        self.systemLookup = systemLookup ?? { try await SystemResolver.lookup($0) }
    }

    public func update(options newValue: EhResolverOptions) {
        if newValue != options {
            options = newValue
            cache.removeAll()
        }
    }

    public func clearCache() { cache.removeAll() }

    public func resolve(_ hostname: String) async throws -> EhResolution {
        var host = hostname.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if let ip = EhIPAddress(host) { return EhResolution(addresses: [ip], source: .literal) }

        if let (addrs, source) = options.staticAddresses(for: host) {
            return EhResolution(addresses: maybeShuffle(addrs), source: source)
        }

        if let c = cache[host], c.expires > Date() {
            return EhResolution(addresses: maybeShuffle(c.resolution.addresses), source: c.resolution.source)
        }

        let opts = options
        if opts.dnsOverHttps {
            if let r = try? await dohLookup(host, opts.dohServer), !r.addresses.isEmpty {
                let ttl = min(max(r.ttl ?? 300, dohTTLRange.lowerBound), dohTTLRange.upperBound)
                let res = EhResolution(addresses: r.addresses, source: .doh)
                if opts == options { cache[host] = (res, Date().addingTimeInterval(ttl)) }
                return EhResolution(addresses: maybeShuffle(res.addresses), source: .doh)
            }
        }

        let addrs = try await systemLookup(host)
        guard !addrs.isEmpty else { throw EhTransportError.unresolvedHost(host) }
        let res = EhResolution(addresses: addrs, source: .system)
        if opts == options { cache[host] = (res, Date().addingTimeInterval(systemTTL)) }
        return EhResolution(addresses: maybeShuffle(addrs), source: .system)
    }

    public func setSystemTTL(_ ttl: TimeInterval) { systemTTL = ttl }

    private func maybeShuffle(_ a: [EhIPAddress]) -> [EhIPAddress] {
        options.shuffle ? a.shuffled() : a
    }
}
