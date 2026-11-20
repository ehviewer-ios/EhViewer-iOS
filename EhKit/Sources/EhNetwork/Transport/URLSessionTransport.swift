import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 基于 URLSession 的标准传输。
/// - 不使用 URLSession 的 cookie 管理（由 `EhCookieStore` 统一注入 / 解析）
/// - 不自动跟随重定向（3xx 原样返回，由 `EhHTTPClient` 逐跳处理）
/// - 代理通过 `connectionProxyDictionary` 设置（Linux 忽略）
/// - 无法自定义 DNS：hosts / DoH 只在 `DFTransport`（Apple）中生效
public final class URLSessionTransport: HTTPTransport, @unchecked Sendable {
    public let timeout: TimeInterval
    public let proxy: EhProxySetting
    private let session: URLSession
    private let delegate: SessionDelegate

    public init(timeout: TimeInterval = 10, proxy: EhProxySetting = .system, configuration: URLSessionConfiguration? = nil) {
        self.timeout = timeout
        self.proxy = proxy
        let cfg = configuration ?? URLSessionConfiguration.default
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = timeout
        cfg.httpMaximumConnectionsPerHost = 6
        #if !canImport(FoundationNetworking)
        cfg.connectionProxyDictionary = Self.proxyDictionary(proxy)
        #endif
        delegate = SessionDelegate()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "EhNetwork.URLSessionTransport"
        session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: queue)
    }

    deinit {
        session.invalidateAndCancel()
    }

    /// `connectionProxyDictionary` 内容。nil = 跟随系统；空字典 = 直连
    public static func proxyDictionary(_ proxy: EhProxySetting) -> [AnyHashable: Any]? {
        switch proxy {
        case .system:
            return nil
        case .direct:
            return [:]
        case let .http(host, port):
            return [
                "HTTPEnable": 1, "HTTPProxy": host, "HTTPPort": port,
                "HTTPSEnable": 1, "HTTPSProxy": host, "HTTPSPort": port,
            ]
        case let .socks(host, port):
            return ["SOCKSEnable": 1, "SOCKSProxy": host, "SOCKSPort": port]
        }
    }

    func makeURLRequest(_ r: EhHTTPRequest) -> URLRequest {
        var req = URLRequest(url: r.url)
        req.httpMethod = r.method.rawValue
        req.httpShouldHandleCookies = false
        req.timeoutInterval = r.timeout ?? timeout
        req.cachePolicy = .reloadIgnoringLocalCacheData
        for f in r.headers {
            // Host / Content-Length / Connection 由 URLSession 管理
            switch f.name.lowercased() {
            case "host", "content-length", "connection": continue
            default: req.addValue(f.value, forHTTPHeaderField: f.name)
            }
        }
        req.httpBody = r.body
        return req
    }

    public func send(_ request: EhHTTPRequest) async throws -> EhHTTPResponse {
        try await run(request, sink: nil, progress: nil)
    }

    public func download(_ request: EhHTTPRequest, to fileURL: URL, progress: EhDownloadProgress?) async throws -> EhHTTPResponse {
        let fm = FileManager.default
        try? fm.removeItem(at: fileURL)
        try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard fm.createFile(atPath: fileURL.path, contents: nil) else {
            throw EhTransportError.io("无法创建文件 \(fileURL.path)")
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        return try await run(request, sink: handle, progress: progress)
    }

    private func run(_ request: EhHTTPRequest, sink: FileHandle?, progress: EhDownloadProgress?) async throws -> EhHTTPResponse {
        try Task.checkCancellation()
        let task = session.dataTask(with: makeURLRequest(request))
        let state = TaskState(sink: sink, progress: progress, url: request.url)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<EhHTTPResponse, Error>) in
                state.continuation = cont
                delegate.register(task.taskIdentifier, state)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// HTTPURLResponse → HTTPHeaders；合并的 Set-Cookie 拆回多条
    static func headers(from response: HTTPURLResponse) -> HTTPHeaders {
        var h = HTTPHeaders()
        for (k, v) in response.allHeaderFields {
            guard let name = k as? String else { continue }
            let value = (v as? String) ?? "\(v)"
            if name.caseInsensitiveCompare("Set-Cookie") == .orderedSame {
                for c in SetCookieSplitter.split(value) { h.add("Set-Cookie", c) }
            } else {
                h.add(name, value)
            }
        }
        return h
    }
}

/// 单个 task 的状态，只在 delegate 串行队列上访问
final class TaskState: @unchecked Sendable {
    var continuation: CheckedContinuation<EhHTTPResponse, Error>?
    var response: HTTPURLResponse?
    var data = Data()
    let sink: FileHandle?
    let progress: EhDownloadProgress?
    let url: URL
    var received: Int64 = 0
    var writeError: Error?

    init(sink: FileHandle?, progress: EhDownloadProgress?, url: URL) {
        self.sink = sink
        self.progress = progress
        self.url = url
    }
}

final class SessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var states: [Int: TaskState] = [:]

    func register(_ id: Int, _ state: TaskState) {
        lock.lock()
        states[id] = state
        lock.unlock()
    }

    private func state(_ id: Int) -> TaskState? {
        lock.lock()
        defer { lock.unlock() }
        return states[id]
    }

    private func remove(_ id: Int) -> TaskState? {
        lock.lock()
        defer { lock.unlock() }
        return states.removeValue(forKey: id)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        state(dataTask.taskIdentifier)?.response = response as? HTTPURLResponse
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let s = state(dataTask.taskIdentifier) else { return }
        if let sink = s.sink {
            guard s.writeError == nil else { return }
            do {
                try sink.write(contentsOf: data)
            } catch {
                s.writeError = error
                dataTask.cancel()
                return
            }
        } else {
            s.data.append(data)
        }
        s.received += Int64(data.count)
        if let p = s.progress {
            let total = s.response?.expectedContentLength ?? -1
            p(s.received, total > 0 ? total : nil)
        }
    }

    // 不跟随重定向：返回 nil 让 3xx 作为最终响应
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let s = remove(task.taskIdentifier), let cont = s.continuation else { return }
        s.continuation = nil
        if let w = s.writeError {
            cont.resume(throwing: EhTransportError.io(String(describing: w)))
            return
        }
        if let error {
            if let u = error as? URLError {
                switch u.code {
                case .cancelled: cont.resume(throwing: CancellationError())
                case .timedOut: cont.resume(throwing: EhTransportError.timedOut)
                case .cannotFindHost, .dnsLookupFailed:
                    cont.resume(throwing: EhTransportError.unresolvedHost(u.localizedDescription))
                case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                     .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
                    cont.resume(throwing: EhTransportError.tlsFailed(u.localizedDescription))
                default:
                    cont.resume(throwing: EhTransportError.connectionFailed(u.localizedDescription))
                }
            } else {
                cont.resume(throwing: error)
            }
            return
        }
        guard let resp = s.response ?? task.response as? HTTPURLResponse else {
            cont.resume(throwing: EhTransportError.protocolError("无 HTTP 响应"))
            return
        }
        cont.resume(returning: EhHTTPResponse(
            status: resp.statusCode, headers: URLSessionTransport.headers(from: resp),
            body: s.data, url: resp.url ?? s.url
        ))
    }
}
