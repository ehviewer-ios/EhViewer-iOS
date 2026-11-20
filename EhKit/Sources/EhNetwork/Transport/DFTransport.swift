#if canImport(Network)
@preconcurrency import Dispatch
import Foundation
import Network
import Security

/// 域前置传输（对应 Android `EhSSLSocketFactory` + `EhHosts` + OkHttp 主机名校验）：
/// 1. 地址经 `EhResolver` 解析（用户 hosts → 内置 → DoH → 系统），直连 IP；
/// 2. TLS 不发送 SNI（`sendSNI = false`，即 DF）；或发送真实域名 SNI（`sendSNI = true`，仅自定义 DNS）；
/// 3. 证书在 verify block 中用 `SecPolicyCreateSSL(true, 真实域名)` 校验（系统信任链 + 主机名）；
/// 4. 自带最小 HTTP/1.1 客户端（Content-Length / chunked / gzip / deflate / keep-alive 连接池）。
/// 单跳：不跟随重定向（由 EhHTTPClient 处理）
public final class DFTransport: HTTPTransport, @unchecked Sendable {
    public struct Options: Sendable, Hashable {
        /// false = 不发 SNI（域前置）；true = 发真实域名 SNI（只用于自定义解析）
        public var sendSNI: Bool
        public var certificateValidation: EhCertificateValidation
        public var timeout: TimeInterval
        /// 每次请求最多尝试的 IP 数
        public var maxAddressAttempts: Int
        public var maxIdlePerHost: Int
        public var idleTimeout: TimeInterval

        public init(sendSNI: Bool = false, certificateValidation: EhCertificateValidation = .system,
                    timeout: TimeInterval = 10, maxAddressAttempts: Int = 4, maxIdlePerHost: Int = 6,
                    idleTimeout: TimeInterval = 120) {
            self.sendSNI = sendSNI
            self.certificateValidation = certificateValidation
            self.timeout = timeout
            self.maxAddressAttempts = maxAddressAttempts
            self.maxIdlePerHost = maxIdlePerHost
            self.idleTimeout = idleTimeout
        }
    }

    public let options: Options
    private let resolver: EhResolver
    private let pool: DFConnectionPool
    private let routes = RouteDatabase()

    public init(resolver: EhResolver, options: Options = Options()) {
        self.resolver = resolver
        self.options = options
        pool = DFConnectionPool(maxIdlePerKey: options.maxIdlePerHost, idleTimeout: options.idleTimeout)
    }

    /// 关闭所有空闲连接
    public func evictIdleConnections() async { await pool.evictAll() }

    public func send(_ request: EhHTTPRequest) async throws -> EhHTTPResponse {
        let sink = BodySink(file: nil, progress: nil)
        var req = request
        req.headers.setIfAbsent("Accept-Encoding", "gzip, deflate")
        let head = try await perform(req, sink: sink)
        var headers = head.headers
        var body = sink.data
        let enc = headers["Content-Encoding"]
        if let enc, !enc.isEmpty, enc.lowercased() != "identity" {
            body = try ContentDecoding.decode(body, contentEncoding: enc)
            // 与 OkHttp 透明解压一致：去掉编码相关头
            headers.remove("Content-Encoding")
            headers.set("Content-Length", String(body.count))
        }
        return EhHTTPResponse(status: head.status, headers: headers, body: body, url: request.url)
    }

    public func download(_ request: EhHTTPRequest, to fileURL: URL, progress: EhDownloadProgress?) async throws -> EhHTTPResponse {
        let fm = FileManager.default
        try? fm.removeItem(at: fileURL)
        try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard fm.createFile(atPath: fileURL.path, contents: nil) else {
            throw EhTransportError.io("无法创建文件 \(fileURL.path)")
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        let sink = BodySink(file: handle, progress: progress)
        var req = request
        req.headers.setIfAbsent("Accept-Encoding", "identity")
        let head: HTTPResponseHead
        do {
            head = try await perform(req, sink: sink)
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        var headers = head.headers
        // 服务器仍然压缩时整体解压（图片一般不会）
        if let enc = headers["Content-Encoding"], !enc.isEmpty, enc.lowercased() != "identity" {
            let raw = try Data(contentsOf: fileURL)
            let decoded = try ContentDecoding.decode(raw, contentEncoding: enc)
            try decoded.write(to: fileURL, options: .atomic)
            headers.remove("Content-Encoding")
            headers.set("Content-Length", String(decoded.count))
        }
        return EhHTTPResponse(status: head.status, headers: headers, body: Data(), url: request.url)
    }

    // MARK: - 核心流程

    private func perform(_ request: EhHTTPRequest, sink: BodySink) async throws -> HTTPResponseHead {
        let url = request.url
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased(), !host.isEmpty else {
            throw EhTransportError.invalidURL(url.absoluteString)
        }
        let tls = scheme == "https"
        let port = UInt16(url.port ?? (tls ? 443 : 80))
        let timeout = request.timeout ?? options.timeout
        let key = "\(scheme)://\(host):\(port)#sni=\(options.sendSNI)#v=\(options.certificateValidation.rawValue)"

        var retriedStale = false
        while true {
            try Task.checkCancellation()
            let (conn, reused) = try await obtainConnection(key: key, host: host, port: port, tls: tls, timeout: timeout)
            do {
                let (head, reusable) = try await exchange(conn, request: request, sink: sink, timeout: timeout)
                if reusable { await pool.put(conn, key: key) } else { conn.cancel() }
                return head
            } catch {
                conn.cancel()
                if Task.isCancelled { throw CancellationError() }
                // 复用的空闲连接可能已被服务器关闭：没收到任何响应字节时换新连接重试一次
                if reused, !retriedStale, !sink.receivedAnything {
                    retriedStale = true
                    continue
                }
                throw error
            }
        }
    }

    private func obtainConnection(key: String, host: String, port: UInt16, tls: Bool,
                                  timeout: TimeInterval) async throws -> (NWHTTPConnection, Bool) {
        if let c = await pool.take(key: key) { return (c, true) }
        let resolution = try await resolver.resolve(host)
        var lastError: Error = EhTransportError.unresolvedHost(host)
        // 近期连接失败的 IP 排到最后（对应 OkHttp RouteDatabase）
        let ordered = routes.order(resolution.addresses, port: port)
        for ip in ordered.prefix(max(1, options.maxAddressAttempts)) {
            try Task.checkCancellation()
            let conn = NWHTTPConnection(
                host: host, ip: ip, port: port, tls: tls, sendSNI: options.sendSNI,
                validation: options.certificateValidation, connectTimeout: timeout
            )
            do {
                try await conn.start(timeout: timeout)
                routes.connected(ip, port: port)
                return (conn, false)
            } catch {
                conn.cancel()
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                routes.failed(ip, port: port)
                lastError = error
            }
        }
        throw lastError
    }

    private func exchange(_ conn: NWHTTPConnection, request: EhHTTPRequest, sink: BodySink,
                          timeout: TimeInterval) async throws -> (HTTPResponseHead, Bool) {
        var headers = request.headers
        headers.setIfAbsent("Connection", "keep-alive")
        let bytes = HTTP1.serializeRequest(method: request.method, url: request.url, headers: headers, body: request.body)
        try await conn.send(bytes, timeout: timeout)

        var parser = HTTP1ResponseParser(requestMethod: request.method)
        var head: HTTPResponseHead?
        func handle(_ events: [HTTP1ResponseParser.Event]) throws {
            for e in events {
                switch e {
                case let .head(h):
                    head = h
                    sink.begin(h)
                case let .body(d):
                    try sink.write(d)
                case .end:
                    break
                }
            }
        }
        while !parser.isComplete {
            try Task.checkCancellation()
            guard let chunk = try await conn.receive(timeout: timeout) else {
                try handle(try parser.finish())
                break
            }
            sink.receivedAnything = true
            try handle(try parser.feed(chunk))
        }
        guard let head else { throw EhTransportError.protocolError("无响应头") }
        return (head, parser.isReusable && !conn.isEOF)
    }
}

/// 响应体接收：内存或文件，带进度
final class BodySink: @unchecked Sendable {
    let file: FileHandle?
    let progress: EhDownloadProgress?
    var data = Data()
    var received: Int64 = 0
    var total: Int64?
    var receivedAnything = false

    init(file: FileHandle?, progress: EhDownloadProgress?) {
        self.file = file
        self.progress = progress
    }

    func begin(_ head: HTTPResponseHead) {
        // 重试时重置
        data = Data()
        received = 0
        if let file { try? file.truncate(atOffset: 0); try? file.seek(toOffset: 0) }
        let encoded = head.headers["Content-Encoding"].map { !$0.isEmpty && $0.lowercased() != "identity" } ?? false
        total = encoded ? nil : head.headers["Content-Length"].flatMap { Int64($0) }
    }

    func write(_ d: Data) throws {
        if let file {
            do { try file.write(contentsOf: d) } catch { throw EhTransportError.io(String(describing: error)) }
        } else {
            data.append(d)
        }
        received += Int64(d.count)
        progress?(received, total)
    }
}

// MARK: - 失败路由记录

/// 记录连接失败的 IP，一段时间内优先尝试其他 IP（对应 OkHttp `RouteDatabase`）
final class RouteDatabase: @unchecked Sendable {
    private let lock = NSLock()
    private var failedAt: [String: Date] = [:]
    let penalty: TimeInterval = 600

    private func key(_ ip: EhIPAddress, _ port: UInt16) -> String { "\(ip):\(port)" }

    func failed(_ ip: EhIPAddress, port: UInt16) { lock.withLock { failedAt[key(ip, port)] = Date() } }
    func connected(_ ip: EhIPAddress, port: UInt16) { _ = lock.withLock { failedAt.removeValue(forKey: key(ip, port)) } }

    /// 保持原相对顺序，近期失败的放后面（去重）
    func order(_ ips: [EhIPAddress], port: UInt16) -> [EhIPAddress] {
        let now = Date()
        var seen = Set<EhIPAddress>()
        let unique = ips.filter { seen.insert($0).inserted }
        let bad: Set<EhIPAddress> = lock.withLock {
            Set(unique.filter { ip in failedAt[key(ip, port)].map { now.timeIntervalSince($0) < penalty } ?? false })
        }
        return unique.filter { !bad.contains($0) } + unique.filter { bad.contains($0) }
    }
}

// MARK: - 连接池

actor DFConnectionPool {
    private var idle: [String: [(conn: NWHTTPConnection, since: Date)]] = [:]
    let maxIdlePerKey: Int
    let idleTimeout: TimeInterval

    init(maxIdlePerKey: Int, idleTimeout: TimeInterval) {
        self.maxIdlePerKey = maxIdlePerKey
        self.idleTimeout = idleTimeout
    }

    func take(key: String) -> NWHTTPConnection? {
        let now = Date()
        while var list = idle[key], !list.isEmpty {
            let item = list.removeLast()
            idle[key] = list
            if now.timeIntervalSince(item.since) < idleTimeout, item.conn.isUsable {
                return item.conn
            }
            item.conn.cancel()
        }
        return nil
    }

    func put(_ conn: NWHTTPConnection, key: String) {
        guard conn.isUsable, maxIdlePerKey > 0 else { conn.cancel(); return }
        var list = idle[key] ?? []
        let now = Date()
        list.removeAll { item in
            let stale = now.timeIntervalSince(item.since) >= idleTimeout || !item.conn.isUsable
            if stale { item.conn.cancel() }
            return stale
        }
        if list.count >= maxIdlePerKey { list.removeFirst().conn.cancel() }
        list.append((conn, now))
        idle[key] = list
    }

    func evictAll() {
        for list in idle.values { for item in list { item.conn.cancel() } }
        idle.removeAll()
    }
}

// MARK: - NWConnection 包装

/// 一次性标志（多回调竞争时只允许第一个 resume）
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

final class NWHTTPConnection: @unchecked Sendable {
    let connection: NWConnection
    let queue: DispatchQueue
    let host: String
    private let lock = NSLock()
    private var _eof = false
    private var _failed = false

    var isEOF: Bool { lock.lock(); defer { lock.unlock() }; return _eof }
    var isUsable: Bool {
        lock.lock()
        defer { lock.unlock() }
        if _eof || _failed { return false }
        if case .ready = connection.state { return true }
        return false
    }

    init(host: String, ip: EhIPAddress, port: UInt16, tls: Bool, sendSNI: Bool,
         validation: EhCertificateValidation, connectTimeout: TimeInterval) {
        self.host = host
        queue = DispatchQueue(label: "EhNetwork.DF.\(host)")
        let nwHost: NWEndpoint.Host
        if ip.family == .v4, let a = IPv4Address(Data(ip.bytes)) {
            nwHost = .ipv4(a)
        } else if let a = IPv6Address(Data(ip.bytes)) {
            nwHost = .ipv6(a)
        } else {
            nwHost = .name(ip.description, nil)
        }
        let endpoint = NWEndpoint.hostPort(host: nwHost, port: NWEndpoint.Port(rawValue: port) ?? .https)

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = max(1, Int(connectTimeout.rounded(.up)))
        tcp.enableKeepalive = true

        var tlsOptions: NWProtocolTLS.Options?
        if tls {
            let t = NWProtocolTLS.Options()
            let sec = t.securityProtocolOptions
            if sendSNI {
                sec_protocol_options_set_tls_server_name(sec, host)
            }
            // 我们只实现 HTTP/1.1
            sec_protocol_options_add_tls_application_protocol(sec, "http/1.1")
            sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
            let verifyHost = host
            let verifyQueue = DispatchQueue(label: "EhNetwork.DF.verify")
            sec_protocol_options_set_verify_block(sec, { _, secTrust, complete in
                if validation == .none {
                    complete(true)
                    return
                }
                let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
                // 按真实域名校验证书链与主机名（连接的是 IP、未发 SNI，不能用默认校验）
                SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, verifyHost as CFString))
                var error: CFError?
                complete(SecTrustEvaluateWithError(trust, &error))
            }, verifyQueue)
            tlsOptions = t
        }
        let params = NWParameters(tls: tlsOptions, tcp: tcp)
        params.preferNoProxies = true
        connection = NWConnection(to: endpoint, using: params)
    }

    func start(timeout: TimeInterval) async throws {
        let once = OnceFlag()
        let conn = connection
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                conn.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready:
                        if once.claim() { cont.resume() }
                    case let .waiting(err):
                        // 无路由 / 被拒绝：当作失败，换下一个 IP
                        if once.claim() { cont.resume(throwing: Self.map(err)) }
                    case let .failed(err):
                        self?.markFailed()
                        if once.claim() { cont.resume(throwing: Self.map(err)) }
                    case .cancelled:
                        self?.markFailed()
                        if once.claim() { cont.resume(throwing: CancellationError()) }
                    default:
                        break
                    }
                }
                conn.start(queue: queue)
                queue.asyncAfter(deadline: .now() + timeout) {
                    if once.claim() {
                        conn.cancel()
                        cont.resume(throwing: EhTransportError.timedOut)
                    }
                }
            }
        } onCancel: {
            conn.cancel()
        }
    }

    private func markFailed() {
        lock.lock()
        _failed = true
        lock.unlock()
    }

    private func markEOF() {
        lock.lock()
        _eof = true
        lock.unlock()
    }

    func send(_ data: Data, timeout: TimeInterval) async throws {
        let once = OnceFlag()
        let conn = connection
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let timer = DispatchWorkItem {
                    if once.claim() {
                        conn.cancel()
                        cont.resume(throwing: EhTransportError.timedOut)
                    }
                }
                queue.asyncAfter(deadline: .now() + timeout, execute: timer)
                conn.send(content: data, completion: .contentProcessed { error in
                    timer.cancel()
                    guard once.claim() else { return }
                    if let error { cont.resume(throwing: Self.map(error)) } else { cont.resume() }
                })
            }
        } onCancel: {
            conn.cancel()
        }
    }

    /// 读一段数据；nil 表示对端已关闭
    func receive(timeout: TimeInterval) async throws -> Data? {
        if isEOF { return nil }
        let once = OnceFlag()
        let conn = connection
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data?, Error>) in
                let timer = DispatchWorkItem {
                    if once.claim() {
                        conn.cancel()
                        cont.resume(throwing: EhTransportError.timedOut)
                    }
                }
                queue.asyncAfter(deadline: .now() + timeout, execute: timer)
                conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
                    timer.cancel()
                    guard once.claim() else { return }
                    if isComplete { self?.markEOF() }
                    if let data, !data.isEmpty {
                        cont.resume(returning: data)
                    } else if let error {
                        self?.markFailed()
                        cont.resume(throwing: Self.map(error))
                    } else {
                        self?.markEOF()
                        cont.resume(returning: nil)
                    }
                }
            }
        } onCancel: {
            conn.cancel()
        }
    }

    func cancel() {
        markFailed()
        connection.cancel()
    }

    static func map(_ error: NWError) -> Error {
        switch error {
        case let .tls(status):
            return EhTransportError.tlsFailed("OSStatus \(status)")
        case let .dns(code):
            return EhTransportError.unresolvedHost("DNS \(code)")
        case let .posix(code):
            if code == .ECANCELED { return CancellationError() }
            if code == .ETIMEDOUT { return EhTransportError.timedOut }
            return EhTransportError.connectionFailed("\(code)")
        default:
            return EhTransportError.connectionFailed("\(error)")
        }
    }
}
#endif
