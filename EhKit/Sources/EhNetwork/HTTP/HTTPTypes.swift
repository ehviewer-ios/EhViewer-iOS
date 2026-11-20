import Foundation

/// 有序、大小写不敏感的 HTTP 头集合（保留重复项，如多个 Set-Cookie）
public struct HTTPHeaders: Sendable, Hashable, Sequence, ExpressibleByDictionaryLiteral, CustomStringConvertible {
    public struct Field: Sendable, Hashable {
        public var name: String
        public var value: String
        public init(name: String, value: String) {
            self.name = name
            self.value = value
        }
    }

    public private(set) var fields: [Field] = []

    public init() {}
    public init(_ pairs: [(String, String)]) {
        fields = pairs.map { Field(name: $0.0, value: $0.1) }
    }
    public init(dictionaryLiteral elements: (String, String)...) {
        self.init(elements)
    }

    public var isEmpty: Bool { fields.isEmpty }
    public var count: Int { fields.count }

    /// 第一个同名头的值
    public subscript(name: String) -> String? {
        get { fields.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value }
        set {
            if let newValue { set(name, newValue) } else { remove(name) }
        }
    }

    public func values(for name: String) -> [String] {
        fields.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
    }

    public func contains(_ name: String) -> Bool { self[name] != nil }

    /// 追加（允许重复）
    public mutating func add(_ name: String, _ value: String) {
        fields.append(Field(name: name, value: value))
    }

    /// 替换所有同名头
    public mutating func set(_ name: String, _ value: String) {
        if let idx = fields.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            fields[idx].value = value
            var i = fields.count - 1
            while i > idx {
                if fields[i].name.caseInsensitiveCompare(name) == .orderedSame { fields.remove(at: i) }
                i -= 1
            }
        } else {
            add(name, value)
        }
    }

    /// 仅当不存在时设置
    public mutating func setIfAbsent(_ name: String, _ value: String) {
        if !contains(name) { add(name, value) }
    }

    public mutating func remove(_ name: String) {
        fields.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    public func makeIterator() -> IndexingIterator<[Field]> { fields.makeIterator() }

    public var description: String {
        fields.map { "\($0.name): \($0.value)" }.joined(separator: "\n")
    }
}

public struct HTTPMethod: RawRepresentable, Sendable, Hashable, ExpressibleByStringLiteral {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue.uppercased() }
    public init(stringLiteral value: String) { self.init(rawValue: value) }

    public static let get: HTTPMethod = "GET"
    public static let post: HTTPMethod = "POST"
    public static let head: HTTPMethod = "HEAD"
    public static let put: HTTPMethod = "PUT"
    public static let delete: HTTPMethod = "DELETE"
}

/// 传输层请求。传输层只做单跳（不跟随重定向），重定向由 `EhHTTPClient` 统一处理以便逐跳保存 Set-Cookie
public struct EhHTTPRequest: Sendable, Hashable {
    public var method: HTTPMethod
    public var url: URL
    public var headers: HTTPHeaders
    public var body: Data?
    /// 单次请求超时（秒）。nil 表示使用传输层默认值
    public var timeout: TimeInterval?
    /// 是否跟随 3xx（由 EhHTTPClient 处理）。登录等需要拿 302 的 Set-Cookie 时可关闭
    public var followRedirects: Bool

    public init(
        method: HTTPMethod = .get, url: URL, headers: HTTPHeaders = HTTPHeaders(), body: Data? = nil,
        timeout: TimeInterval? = nil, followRedirects: Bool = true
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeout = timeout
        self.followRedirects = followRedirects
    }
}

public struct EhHTTPResponse: Sendable, Hashable {
    public var status: Int
    public var headers: HTTPHeaders
    /// 下载到文件时为空
    public var body: Data
    /// 最终 URL（跟随重定向后）
    public var url: URL

    public init(status: Int, headers: HTTPHeaders, body: Data = Data(), url: URL) {
        self.status = status
        self.headers = headers
        self.body = body
        self.url = url
    }

    public var isSuccess: Bool { (200..<300).contains(status) }
    public var isRedirect: Bool { [301, 302, 303, 307, 308].contains(status) }
    public var setCookieHeaders: [String] { headers.values(for: "Set-Cookie") }
    public var contentType: String? { headers["Content-Type"] }
    public var contentLength: Int64? { headers["Content-Length"].flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) } }

    /// 按 Content-Type 的 charset 解码文本；默认 UTF-8，失败回退 ISO-8859-1（不会失败）
    public var text: String {
        var encoding: String.Encoding = .utf8
        if let ct = contentType?.lowercased(), let r = ct.range(of: "charset=") {
            let cs = ct[r.upperBound...].split(separator: ";").first.map {
                $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            } ?? ""
            switch cs {
            case "iso-8859-1", "latin1": encoding = .isoLatin1
            case "shift_jis", "sjis": encoding = .shiftJIS
            case "euc-jp": encoding = .japaneseEUC
            case "utf-16": encoding = .utf16
            default: encoding = .utf8
            }
        }
        if let s = String(data: body, encoding: encoding) { return s }
        if encoding != .utf8, let s = String(data: body, encoding: .utf8) { return s }
        return String(decoding: body, as: UTF8.self)
    }
}

/// 下载进度回调：已接收字节、总字节（未知为 nil）
public typealias EhDownloadProgress = @Sendable (_ received: Int64, _ total: Int64?) -> Void

/// 传输层抽象。实现：`URLSessionTransport`、`DFTransport`（Apple）、`RoutingTransport`
public protocol HTTPTransport: Sendable {
    /// 单跳请求，返回完整响应体（已按 Content-Encoding 解压）
    func send(_ request: EhHTTPRequest) async throws -> EhHTTPResponse
    /// 单跳流式下载到文件（覆盖写入）。返回的响应 body 为空。非 2xx 时同样写文件，由调用方判断
    func download(_ request: EhHTTPRequest, to fileURL: URL, progress: EhDownloadProgress?) async throws -> EhHTTPResponse
}

/// 传输层内部错误，统一在门面层转换为 `EhError`
public enum EhTransportError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidURL(String)
    case timedOut
    case connectionFailed(String)
    case tlsFailed(String)
    case protocolError(String)
    case unresolvedHost(String)
    case tooManyRedirects
    case io(String)

    public var description: String {
        switch self {
        case let .invalidURL(s): return "无效 URL：\(s)"
        case .timedOut: return "请求超时"
        case let .connectionFailed(s): return "连接失败：\(s)"
        case let .tlsFailed(s): return "TLS 握手失败：\(s)"
        case let .protocolError(s): return "HTTP 协议错误：\(s)"
        case let .unresolvedHost(s): return "无法解析主机：\(s)"
        case .tooManyRedirects: return "重定向次数过多"
        case let .io(s): return "读写失败：\(s)"
        }
    }
}

extension EhTransportError: LocalizedError {
    public var errorDescription: String? { description }
}
