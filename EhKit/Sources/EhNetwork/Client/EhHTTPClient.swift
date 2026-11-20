import Foundation

/// 网络门面。对应 Android `EhApplication.getOkHttpClient / getImageOkHttpClient` + `EhRequestBuilder` + `EhCookieStore`：
/// - 统一 header（User-Agent / Accept / Accept-Language，可选 Referer / Origin）
/// - 自动注入 Cookie、逐跳保存 Set-Cookie（含 3xx）
/// - 重定向跟随（可按请求关闭）
/// - 通用错误识别（HTTP 状态码、Sad Panda、封禁页 → `EhError`）
public final class EhHTTPClient: @unchecked Sendable {
    public let cookieStore: EhCookieStore
    public let resolver: EhResolver
    /// Set-Cookie 回调（对应 Android 把 Set-Cookie 同步给 WebView CookieManager 的拦截器）
    public var onSetCookies: (@Sendable (_ url: URL, _ headers: [String]) -> Void)?

    private let lock = NSLock()
    private var _config: EhNetworkConfig
    private var _transport: HTTPTransport
    /// 注入的固定传输（测试用）
    private let fixedTransport: HTTPTransport?

    /// - Parameters:
    ///   - transport: 注入固定传输（测试用）；nil 时按配置创建 `RoutingTransport`
    public init(config: EhNetworkConfig = EhNetworkConfig(), cookieStore: EhCookieStore = EhCookieStore(),
                resolver: EhResolver? = nil, transport: HTTPTransport? = nil) {
        _config = config
        self.cookieStore = cookieStore
        let r = resolver ?? EhResolver(options: config.resolverOptions)
        self.resolver = r
        fixedTransport = transport
        // 超时按请求传递（普通 10s / 图片 20s），因此页面与图片共用一个传输与连接池
        _transport = transport ?? RoutingTransport(config: config, resolver: r, timeout: config.timeout)
    }

    public var config: EhNetworkConfig {
        lock.lock()
        defer { lock.unlock() }
        return _config
    }

    /// 更新配置（重建传输层，解析器清缓存）
    public func updateConfig(_ newConfig: EhNetworkConfig) async {
        await resolver.update(options: newConfig.resolverOptions)
        let t = fixedTransport ?? RoutingTransport(config: newConfig, resolver: resolver, timeout: newConfig.timeout)
        lock.withLock {
            _config = newConfig
            _transport = t
        }
    }

    public func updateConfig(_ transform: (inout EhNetworkConfig) -> Void) async {
        var c = config
        transform(&c)
        await updateConfig(c)
    }

    private var transport: HTTPTransport { lock.lock(); defer { lock.unlock() }; return _transport }

    // MARK: - 请求构造

    /// 对应 `EhRequestBuilder(url, referer, origin)`：加统一 header
    public func makeRequest(_ url: URL, method: HTTPMethod = .get, referer: String? = nil, origin: String? = nil,
                            headers extra: HTTPHeaders = HTTPHeaders(), body: Data? = nil) -> EhHTTPRequest {
        let c = config
        var h = HTTPHeaders()
        h.add("User-Agent", c.userAgent)
        h.add("Accept", c.accept)
        h.add("Accept-Language", c.acceptLanguage)
        if let referer { h.add("Referer", referer) }
        if let origin { h.add("Origin", origin) }
        for f in extra { h.set(f.name, f.value) }
        return EhHTTPRequest(method: method, url: url, headers: h, body: body)
    }

    static func url(_ s: String) throws -> URL {
        guard let u = URL(string: s), u.scheme != nil, u.host != nil else { throw EhError.other("无效 URL：\(s)") }
        return u
    }

    // MARK: - 执行

    /// 执行请求：注入 cookie、保存 Set-Cookie、跟随重定向；`validate` 为 true 时识别通用错误
    public func execute(_ request: EhHTTPRequest, validate: Bool = true) async throws -> EhHTTPResponse {
        do {
            let resp = try await runHops(request) { t, r in try await t.send(r) }
            if validate { try EhResponseValidator.validate(resp) }
            return resp
        } catch {
            throw EhResponseValidator.map(error)
        }
    }

    /// 流式下载到文件（未指定超时时用图片超时）。≥400 时删除文件并抛错
    public func download(_ request: EhHTTPRequest, to fileURL: URL, progress: EhDownloadProgress? = nil,
                         validate: Bool = true) async throws -> EhHTTPResponse {
        var request = request
        if request.timeout == nil { request.timeout = config.imageTimeout }
        do {
            let resp = try await runHops(request) { t, r in
                try await t.download(r, to: fileURL, progress: progress)
            }
            if validate {
                if resp.status >= 400 {
                    // 错误页可能是封禁提示，读出来判断
                    var withBody = resp
                    if let d = try? Data(contentsOf: fileURL), d.count < 1 << 20 { withBody.body = d }
                    try? FileManager.default.removeItem(at: fileURL)
                    try EhResponseValidator.validate(withBody)
                    throw EhError.http(status: resp.status)
                }
                try EhResponseValidator.validate(resp)
            }
            return resp
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            throw EhResponseValidator.map(error)
        }
    }

    private func runHops(_ original: EhHTTPRequest,
                         _ op: (HTTPTransport, EhHTTPRequest) async throws -> EhHTTPResponse) async throws -> EhHTTPResponse {
        let tr = transport
        let maxRedirects = config.maxRedirects
        var req = original
        var hops = 0
        while true {
            try Task.checkCancellation()
            var hopReq = req
            hopReq.headers.remove("Cookie")
            if let ch = cookieStore.cookieHeader(for: hopReq.url) {
                let explicit = req.headers["Cookie"]
                hopReq.headers.set("Cookie", explicit.map { ch + "; " + $0 } ?? ch)
            } else if let explicit = req.headers["Cookie"] {
                hopReq.headers.set("Cookie", explicit)
            }
            var resp = try await op(tr, hopReq)
            resp.url = hopReq.url
            let setCookies = resp.setCookieHeaders
            if !setCookies.isEmpty {
                cookieStore.store(setCookieHeaders: setCookies, for: hopReq.url)
                onSetCookies?(hopReq.url, setCookies)
            }
            guard original.followRedirects, let next = Self.redirectRequest(from: req, response: resp) else {
                return resp
            }
            hops += 1
            if hops > maxRedirects { throw EhTransportError.tooManyRedirects }
            req = next
        }
    }

    /// 生成重定向后的请求（对应 OkHttp `RetryAndFollowUpInterceptor.followUpRequest`）。nil 表示不跟随
    public static func redirectRequest(from req: EhHTTPRequest, response: EhHTTPResponse) -> EhHTTPRequest? {
        guard response.isRedirect, let loc = response.headers["Location"], !loc.isEmpty,
              let next = URL(string: loc, relativeTo: req.url)?.absoluteURL,
              let scheme = next.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        var r = req
        r.url = next
        r.headers.remove("Host")
        switch response.status {
        case 307, 308:
            // OkHttp：307/308 只对 GET/HEAD 跟随
            guard req.method == .get || req.method == .head else { return nil }
        default:
            if req.method != .get && req.method != .head {
                r.method = .get
                r.body = nil
                r.headers.remove("Content-Type")
                r.headers.remove("Content-Length")
                r.headers.remove("Transfer-Encoding")
            }
        }
        if req.url.host?.lowercased() != next.host?.lowercased() {
            r.headers.remove("Authorization")
        }
        return r
    }

    // MARK: - 便捷方法（下一阶段 EhEngine 基于这些实现）

    /// GET。返回完整响应（已校验）
    @discardableResult
    public func get(_ url: String, referer: String? = nil, origin: String? = nil, headers: HTTPHeaders = HTTPHeaders(),
                    followRedirects: Bool = true) async throws -> EhHTTPResponse {
        var r = makeRequest(try Self.url(url), referer: referer, origin: origin, headers: headers)
        r.followRedirects = followRedirects
        return try await execute(r)
    }

    /// GET 并按 charset 解码为字符串（HTML 页面）
    public func getText(_ url: String, referer: String? = nil, headers: HTTPHeaders = HTTPHeaders()) async throws -> String {
        try await get(url, referer: referer, headers: headers).text
    }

    /// POST application/x-www-form-urlencoded（对应 OkHttp `FormBody`，保持字段顺序）
    @discardableResult
    public func postForm(_ url: String, fields: [(String, String)], referer: String? = nil, origin: String? = nil,
                         headers: HTTPHeaders = HTTPHeaders(), followRedirects: Bool = true) async throws -> EhHTTPResponse {
        var h = headers
        h.set("Content-Type", "application/x-www-form-urlencoded")
        var r = makeRequest(try Self.url(url), method: .post, referer: referer, origin: origin, headers: h,
                            body: Data(FormEncoding.encode(fields).utf8))
        r.followRedirects = followRedirects
        return try await execute(r)
    }

    /// POST JSON（原始 Data）。对应 `MEDIA_TYPE_JSON = application/json; charset=utf-8`
    @discardableResult
    public func postJSON(_ url: String, data: Data, referer: String? = nil, origin: String? = nil,
                         headers: HTTPHeaders = HTTPHeaders()) async throws -> EhHTTPResponse {
        var h = headers
        h.set("Content-Type", "application/json; charset=utf-8")
        return try await execute(makeRequest(try Self.url(url), method: .post, referer: referer, origin: origin, headers: h, body: data))
    }

    /// POST JSON（Encodable）
    @discardableResult
    public func postJSON<T: Encodable>(_ url: String, body: T, referer: String? = nil, origin: String? = nil) async throws -> EhHTTPResponse {
        let data: Data
        do { data = try JSONEncoder().encode(body) } catch { throw EhError.other("JSON 编码失败：\(error)") }
        return try await postJSON(url, data: data, referer: referer, origin: origin)
    }

    /// POST JSON（JSONSerialization 兼容对象，如 `["method": "gdata", "gidlist": [[gid, token]]]`）
    @discardableResult
    public func postJSON(_ url: String, jsonObject: Any, referer: String? = nil, origin: String? = nil) async throws -> EhHTTPResponse {
        guard JSONSerialization.isValidJSONObject(jsonObject),
              let data = try? JSONSerialization.data(withJSONObject: jsonObject) else {
            throw EhError.other("非法 JSON 对象")
        }
        return try await postJSON(url, data: data, referer: referer, origin: origin)
    }

    /// POST multipart/form-data（以图搜图上传等）
    @discardableResult
    public func postMultipart(_ url: String, parts: [MultipartPart], referer: String? = nil, origin: String? = nil,
                              headers: HTTPHeaders = HTTPHeaders()) async throws -> EhHTTPResponse {
        let boundary = "EhBoundary" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var h = headers
        h.set("Content-Type", "multipart/form-data; boundary=\(boundary)")
        let body = MultipartPart.encode(parts, boundary: boundary)
        return try await execute(makeRequest(try Self.url(url), method: .post, referer: referer, origin: origin, headers: h, body: body))
    }

    /// 下载图片到文件（图片超时 20s；与 Android 图片 client 一样默认不跟随重定向）
    @discardableResult
    public func downloadImage(_ url: String, referer: String? = nil, to fileURL: URL, followRedirects: Bool = false,
                              progress: EhDownloadProgress? = nil) async throws -> EhHTTPResponse {
        var r = makeRequest(try Self.url(url), referer: referer)
        r.timeout = config.imageTimeout
        r.followRedirects = followRedirects
        return try await download(r, to: fileURL, progress: progress)
    }

    /// 小文件 / 缩略图读入内存
    public func fetchData(_ url: String, referer: String? = nil, timeout: TimeInterval? = nil) async throws -> Data {
        var r = makeRequest(try Self.url(url), referer: referer)
        r.timeout = timeout ?? config.imageTimeout
        return try await execute(r).body
    }

    // MARK: - 登录状态（转发 cookie store）

    public var hasSignedIn: Bool { cookieStore.hasSignedIn }
    public func signOut() { cookieStore.signOut() }
}

/// application/x-www-form-urlencoded 编码（对应 OkHttp `FormBody`：FORM_ENCODE_SET + '%' + '+'，空格编码为 %20）
public enum FormEncoding {
    static let reserved = Set(" \"':;<=>@[]^`{}|/\\?#&!$(),~%+".utf8)

    public static func escape(_ s: String) -> String {
        var out = ""
        for b in s.utf8 {
            if b > 0x20, b < 0x7f, !reserved.contains(b) {
                out.append(Character(UnicodeScalar(b)))
            } else {
                out += String(format: "%%%02X", b)
            }
        }
        return out
    }

    public static func encode(_ fields: [(String, String)]) -> String {
        fields.map { escape($0.0) + "=" + escape($0.1) }.joined(separator: "&")
    }
}

/// multipart 的一个部分
public struct MultipartPart: Sendable, Hashable {
    public var name: String
    public var filename: String?
    public var contentType: String?
    public var data: Data

    public init(name: String, value: String) {
        self.name = name
        data = Data(value.utf8)
    }

    public init(name: String, filename: String, contentType: String, data: Data) {
        self.name = name
        self.filename = filename
        self.contentType = contentType
        self.data = data
    }

    public static func encode(_ parts: [MultipartPart], boundary: String) -> Data {
        var body = Data()
        func line(_ s: String) { body.append(Data((s + "\r\n").utf8)) }
        for p in parts {
            line("--\(boundary)")
            var disp = "Content-Disposition: form-data; name=\"\(p.name)\""
            if let f = p.filename { disp += "; filename=\"\(f)\"" }
            line(disp)
            if let ct = p.contentType { line("Content-Type: \(ct)") }
            line("")
            body.append(p.data)
            line("")
        }
        line("--\(boundary)--")
        return body
    }
}
