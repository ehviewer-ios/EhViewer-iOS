import Foundation

/// 响应状态行 + 头
public struct HTTPResponseHead: Sendable, Hashable {
    public var version: String
    public var status: Int
    public var reason: String
    public var headers: HTTPHeaders

    public init(version: String, status: Int, reason: String, headers: HTTPHeaders) {
        self.version = version
        self.status = status
        self.reason = reason
        self.headers = headers
    }
}

/// 最小 HTTP/1.1 编解码（纯函数 / 值类型状态机，可在 Linux 单测）。供 `DFTransport` 使用
public enum HTTP1 {
    static let crlf: [UInt8] = [13, 10]
    /// 响应头最大长度，超出视为协议错误
    public static let maxHeadSize = 256 * 1024

    /// 请求行目标：percent-encoded path + query；空 path 用 "/"
    public static func requestTarget(for url: URL) -> String {
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var path = comps?.percentEncodedPath ?? ""
        if path.isEmpty { path = "/" }
        if let q = comps?.percentEncodedQuery { path += "?" + q }
        return path
    }

    /// Host 头：非默认端口时带端口
    public static func hostHeader(for url: URL) -> String {
        var host = url.host ?? ""
        if host.contains(":"), !host.hasPrefix("[") { host = "[\(host)]" }
        if let port = url.port {
            let scheme = url.scheme?.lowercased()
            if !(scheme == "https" && port == 443) && !(scheme == "http" && port == 80) {
                return "\(host):\(port)"
            }
        }
        return host
    }

    /// 序列化请求。自动补 Host / Content-Length；调用方给出的 Host 头优先（对应 ChromeRequestBuilder 的手动 Host）
    public static func serializeRequest(method: HTTPMethod, url: URL, headers: HTTPHeaders, body: Data?) -> Data {
        var out = "\(method.rawValue) \(requestTarget(for: url)) HTTP/1.1\r\n"
        var h = headers
        let host = h["Host"] ?? hostHeader(for: url)
        h.remove("Host")
        out += "Host: \(host)\r\n"
        if let body {
            h.set("Content-Length", String(body.count))
        } else if method == .post || method == .put {
            h.set("Content-Length", "0")
        } else {
            h.remove("Content-Length")
        }
        h.remove("Transfer-Encoding")
        for f in h {
            // 防止头注入
            let name = Self.stripCRLF(f.name)
            let value = Self.stripCRLF(f.value)
            out += "\(name): \(value)\r\n"
        }
        out += "\r\n"
        var data = Data(out.utf8)
        if let body { data.append(body) }
        return data
    }

    static func stripCRLF(_ s: String) -> String {
        var v = String.UnicodeScalarView()
        v.append(contentsOf: s.unicodeScalars.filter { $0 != "\r" && $0 != "\n" })
        return String(v)
    }

    /// 在 buffer 中查找头结束位置（\r\n\r\n 或宽松的 \n\n），返回头部字节数（含结束符）
    static func findHeadEnd(_ buf: [UInt8], from start: Int = 0) -> Int? {
        var i = max(start, 0)
        let n = buf.count
        while i < n {
            if buf[i] == 10 {
                if i + 1 < n, buf[i + 1] == 10 { return i + 2 }
                if i + 2 < n, buf[i + 1] == 13, buf[i + 2] == 10 { return i + 3 }
            }
            i += 1
        }
        return nil
    }

    /// 解析完整响应头。返回 nil 表示数据不足
    public static func parseHead(_ buf: [UInt8]) throws -> (head: HTTPResponseHead, consumed: Int)? {
        guard let end = findHeadEnd(buf) else {
            if buf.count > maxHeadSize { throw EhTransportError.protocolError("响应头过大") }
            return nil
        }
        // 注意：Swift 中 "\r\n" 是一个 Character，必须按字节切行
        var lines = buf[0..<end].split(separator: 10, omittingEmptySubsequences: false).map { line -> String in
            let l = line.last == 13 ? line.dropLast() : line
            // 头部按 ISO-8859-1 宽松解码可能更标准，这里 UTF-8 容错解码即可
            return String(decoding: l, as: UTF8.self)
        }
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        guard let statusLine = lines.first else { throw EhTransportError.protocolError("空状态行") }
        let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/"), let status = Int(parts[1]), (100...999).contains(status) else {
            throw EhTransportError.protocolError("非法状态行：\(statusLine.prefix(64))")
        }
        var headers = HTTPHeaders()
        for line in lines.dropFirst() {
            // obs-fold：以空白开头的续行拼到上一个头
            if let first = line.first, first == " " || first == "\t", !headers.isEmpty {
                var fields = headers.fields
                fields[fields.count - 1].value += " " + line.trimmingCharacters(in: .whitespaces)
                headers = HTTPHeaders(fields.map { ($0.name, $0.value) })
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { headers.add(name, value) }
        }
        let head = HTTPResponseHead(
            version: String(parts[0]), status: status,
            reason: parts.count > 2 ? String(parts[2]) : "", headers: headers
        )
        return (head, end)
    }
}

/// `Transfer-Encoding: chunked` 增量解码器
public struct ChunkedDecoder: Sendable {
    enum State: Sendable { case size, data(Int), dataEnd, trailer, done }
    var state: State = .size
    var line: [UInt8] = []

    public init() {}

    public var isDone: Bool { if case .done = state { return true } else { return false } }

    /// 输入任意切分的字节，返回解出的数据。结束后多余字节放入 `leftover`
    public mutating func feed(_ input: [UInt8]) throws -> (data: [UInt8], leftover: [UInt8]) {
        var out: [UInt8] = []
        var i = 0
        let n = input.count
        while i < n {
            switch state {
            case .done:
                return (out, Array(input[i...]))
            case let .data(remaining):
                let take = min(remaining, n - i)
                out.append(contentsOf: input[i..<(i + take)])
                i += take
                state = remaining - take == 0 ? .dataEnd : .data(remaining - take)
            case .size, .dataEnd, .trailer:
                let b = input[i]
                i += 1
                if b != 10 {
                    line.append(b)
                    if line.count > 8192 { throw EhTransportError.protocolError("chunk 行过长") }
                    continue
                }
                if line.last == 13 { line.removeLast() }
                let l = line
                line.removeAll(keepingCapacity: true)
                try handleLine(l)
            }
        }
        return (out, [])
    }

    private mutating func handleLine(_ l: [UInt8]) throws {
        switch state {
        case .size:
            // chunk-size [; ext]
            var hex = ""
            for c in l {
                if c == 59 || c == 32 || c == 9 { break } // ';' / 空白
                hex.append(Character(UnicodeScalar(c)))
            }
            guard !hex.isEmpty, let size = Int(hex, radix: 16), size >= 0 else {
                throw EhTransportError.protocolError("非法 chunk 大小：\(String(decoding: l, as: UTF8.self).prefix(32))")
            }
            state = size == 0 ? .trailer : .data(size)
        case .dataEnd:
            // 数据后的 CRLF；容忍非空行（直接视为下一个 size 行）
            if l.isEmpty { state = .size } else { state = .size; try handleLine(l) }
        case .trailer:
            if l.isEmpty { state = .done }
        default:
            break
        }
    }
}

/// HTTP/1.1 响应增量解析器：状态行/头 → 按 Content-Length / chunked / 读到关闭 切分 body
public struct HTTP1ResponseParser: Sendable {
    public enum Event: Sendable, Equatable {
        case head(HTTPResponseHead)
        case body(Data)
        case end
    }

    public enum Framing: Sendable, Equatable {
        case none
        case length(Int64)
        case chunked
        case untilClose
    }

    enum State: Sendable {
        case head
        case fixed(Int64)
        case chunked(ChunkedDecoder)
        case untilClose
        case done
    }

    private var state: State = .head
    private var buffer: [UInt8] = []
    private let isHeadRequest: Bool
    public private(set) var head: HTTPResponseHead?
    public private(set) var framing: Framing = .none
    /// 结束后剩余的字节（流水线时属于下一响应；我们不做流水线，非空即不可复用）
    public private(set) var leftover: [UInt8] = []

    public init(requestMethod: HTTPMethod = .get) {
        isHeadRequest = requestMethod == .head
    }

    public var isComplete: Bool { if case .done = state { return true } else { return false } }

    /// 响应结束后连接能否复用
    public var isReusable: Bool {
        guard isComplete, leftover.isEmpty, let head else { return false }
        if case .untilClose = framing { return false }
        let conn = head.headers.values(for: "Connection").joined(separator: ",").lowercased()
        if conn.contains("close") { return false }
        if head.version == "HTTP/1.0" { return conn.contains("keep-alive") }
        return true
    }

    public mutating func feed(_ data: Data) throws -> [Event] {
        try feed(bytes: [UInt8](data))
    }

    public mutating func feed(bytes input: [UInt8]) throws -> [Event] {
        var events: [Event] = []
        var pending = input
        while !pending.isEmpty {
            switch state {
            case .head:
                buffer.append(contentsOf: pending)
                pending = []
                guard let (h, consumed) = try HTTP1.parseHead(buffer) else { return events }
                let rest = Array(buffer[consumed...])
                buffer = []
                // 1xx（除 101）是中间响应，丢弃继续读
                if (100..<200).contains(h.status), h.status != 101 {
                    pending = rest
                    continue
                }
                head = h
                events.append(.head(h))
                framing = Self.framing(for: h, isHeadRequest: isHeadRequest)
                switch framing {
                case .none, .length(0):
                    state = .done
                    leftover = rest
                    events.append(.end)
                    return events
                case let .length(n): state = .fixed(n)
                case .chunked: state = .chunked(ChunkedDecoder())
                case .untilClose: state = .untilClose
                }
                pending = rest
            case let .fixed(remaining):
                let take = Int(min(Int64(pending.count), remaining))
                if take > 0 { events.append(.body(Data(pending[0..<take]))) }
                let left = remaining - Int64(take)
                pending = take < pending.count ? Array(pending[take...]) : []
                if left == 0 {
                    state = .done
                    leftover = pending
                    events.append(.end)
                    return events
                }
                state = .fixed(left)
            case var .chunked(decoder):
                let (out, rest) = try decoder.feed(pending)
                pending = []
                if !out.isEmpty { events.append(.body(Data(out))) }
                if decoder.isDone {
                    state = .done
                    leftover = rest
                    events.append(.end)
                    return events
                }
                state = .chunked(decoder)
            case .untilClose:
                events.append(.body(Data(pending)))
                pending = []
            case .done:
                leftover.append(contentsOf: pending)
                return events
            }
        }
        return events
    }

    /// 连接被对端关闭（EOF）时调用
    public mutating func finish() throws -> [Event] {
        switch state {
        case .done: return []
        case .untilClose:
            state = .done
            return [.end]
        case .head:
            throw EhTransportError.protocolError(buffer.isEmpty ? "连接在响应前关闭" : "响应头不完整")
        case let .fixed(remaining):
            throw EhTransportError.protocolError("响应体不完整，缺少 \(remaining) 字节")
        case .chunked:
            throw EhTransportError.protocolError("chunked 响应体不完整")
        }
    }

    static func framing(for head: HTTPResponseHead, isHeadRequest: Bool) -> Framing {
        if isHeadRequest || head.status == 204 || head.status == 304 || (100..<200).contains(head.status) {
            return .none
        }
        let te = head.headers.values(for: "Transfer-Encoding").joined(separator: ",").lowercased()
        if te.contains("chunked") { return .chunked }
        if let cl = head.headers["Content-Length"], let n = Int64(cl.trimmingCharacters(in: .whitespaces)), n >= 0 {
            return .length(n)
        }
        return .untilClose
    }
}
