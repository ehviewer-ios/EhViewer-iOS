import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// DNS over HTTPS（RFC 8484）。对应 Android `EhHosts` 里的 OkHttp `DnsOverHttps`：
/// 服务器 `https://77.88.8.1/dns-query`、POST 方式、同时查询 A 与 AAAA。
/// 查询请求本身走一个独立的 URLSession（系统 DNS / 系统代理），不经过 EhResolver，避免递归
public struct DoHClient: Sendable {
    public static let defaultServer = URL(string: "https://77.88.8.1/dns-query")!
    public static let mediaType = "application/dns-message"

    /// 实际发送：返回 (状态码, body)。可注入以便测试
    public typealias Fetch = @Sendable (URLRequest) async throws -> (Int, Data)

    public var server: URL
    public var usePost: Bool
    public var includeIPv6: Bool
    public var timeout: TimeInterval
    private let fetch: Fetch

    public init(
        server: URL = DoHClient.defaultServer, usePost: Bool = true, includeIPv6: Bool = true,
        timeout: TimeInterval = 10, fetch: Fetch? = nil
    ) {
        self.server = server
        self.usePost = usePost
        self.includeIPv6 = includeIPv6
        self.timeout = timeout
        self.fetch = fetch ?? DoHClient.urlSessionFetch
    }

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        cfg.urlCache = nil
        return URLSession(configuration: cfg)
    }()

    static let urlSessionFetch: Fetch = { req in
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Int, Data), Error>) in
            let task = session.dataTask(with: req) { data, resp, err in
                if let err { cont.resume(throwing: err); return }
                cont.resume(returning: ((resp as? HTTPURLResponse)?.statusCode ?? 0, data ?? Data()))
            }
            task.resume()
        }
    }

    /// 构造 DoH 请求（纯函数，便于测试）
    public func makeRequest(host: String, type: DNSRecordType) throws -> URLRequest {
        let query = try DNSMessage.encodeQuery(host: host, type: type)
        var req: URLRequest
        if usePost {
            req = URLRequest(url: server)
            req.httpMethod = "POST"
            req.httpBody = Data(query)
            req.setValue(Self.mediaType, forHTTPHeaderField: "Content-Type")
        } else {
            var comps = URLComponents(url: server, resolvingAgainstBaseURL: false)!
            comps.queryItems = (comps.queryItems ?? []) + [URLQueryItem(name: "dns", value: DNSMessage.base64URL(query))]
            req = URLRequest(url: comps.url!)
            req.httpMethod = "GET"
        }
        req.setValue(Self.mediaType, forHTTPHeaderField: "Accept")
        req.timeoutInterval = timeout
        return req
    }

    public func query(host: String, type: DNSRecordType) async throws -> DNSResponse {
        let (status, data) = try await fetch(try makeRequest(host: host, type: type))
        guard status == 200 else { throw EhTransportError.unresolvedHost("DoH HTTP \(status)") }
        return try DNSMessage.decodeResponse([UInt8](data))
    }

    /// 查询 A（及 AAAA）。任一成功即返回；都失败则抛错。返回地址与最小 TTL
    public func lookup(_ host: String) async throws -> (addresses: [EhIPAddress], ttl: TimeInterval?) {
        var types: [DNSRecordType] = [.a]
        if includeIPv6 { types.append(.aaaa) }
        var addrs: [EhIPAddress] = []
        var ttl: UInt32?
        var lastError: Error?
        await withTaskGroup(of: Result<DNSResponse, Error>.self) { group in
            for t in types {
                group.addTask {
                    do { return .success(try await query(host: host, type: t)) } catch { return .failure(error) }
                }
            }
            for await r in group {
                switch r {
                case let .success(resp):
                    addrs.append(contentsOf: resp.addresses)
                    if let m = resp.minimumTTL { ttl = min(ttl ?? m, m) }
                case let .failure(e):
                    lastError = e
                }
            }
        }
        // IPv4 优先
        addrs.sort { a, b in a.family == .v4 && b.family == .v6 }
        if addrs.isEmpty, let lastError { throw lastError }
        return (addrs, ttl.map(TimeInterval.init))
    }
}
