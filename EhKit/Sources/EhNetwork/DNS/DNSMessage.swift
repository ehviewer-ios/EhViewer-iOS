import Foundation

/// DNS 资源记录类型
public enum DNSRecordType: UInt16, Sendable {
    case a = 1
    case cname = 5
    case aaaa = 28
}

public struct DNSRecord: Sendable, Hashable {
    public var name: String
    public var type: UInt16
    public var rrClass: UInt16
    public var ttl: UInt32
    public var data: [UInt8]

    /// A / AAAA 记录对应的地址
    public var address: EhIPAddress? {
        if type == DNSRecordType.a.rawValue, data.count == 4 { return EhIPAddress(bytes: data) }
        if type == DNSRecordType.aaaa.rawValue, data.count == 16 { return EhIPAddress(bytes: data) }
        return nil
    }
}

public struct DNSResponse: Sendable, Hashable {
    public var id: UInt16
    public var flags: UInt16
    public var answers: [DNSRecord]

    /// RCODE：0 = NOERROR，3 = NXDOMAIN
    public var rcode: Int { Int(flags & 0x000f) }
    public var isResponse: Bool { flags & 0x8000 != 0 }
    public var isTruncated: Bool { flags & 0x0200 != 0 }

    public var addresses: [EhIPAddress] { answers.compactMap(\.address) }
    /// 地址记录的最小 TTL（秒）
    public var minimumTTL: UInt32? { answers.filter { $0.address != nil }.map(\.ttl).min() }
}

/// DNS 报文编解码（RFC 1035，DoH 使用 RFC 8484 wire format）。纯函数，可在 Linux 单测。
/// 对应 OkHttp `DnsRecordCodec`
public enum DNSMessage {
    public enum CodecError: Error, Sendable, Equatable {
        case invalidName(String)
        case truncated
        case badPointer
        case notResponse
        case idMismatch
    }

    /// 编码查询。DoH 建议 id = 0（便于 HTTP 缓存），标志位只设 RD
    public static func encodeQuery(host: String, type: DNSRecordType, id: UInt16 = 0) throws -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(18 + host.utf8.count)
        appendU16(&out, id)
        appendU16(&out, 0x0100) // RD
        appendU16(&out, 1) // QDCOUNT
        appendU16(&out, 0) // ANCOUNT
        appendU16(&out, 0) // NSCOUNT
        appendU16(&out, 0) // ARCOUNT
        try appendName(&out, host)
        appendU16(&out, type.rawValue)
        appendU16(&out, 1) // IN
        return out
    }

    static func appendU16(_ out: inout [UInt8], _ v: UInt16) {
        out.append(UInt8(v >> 8))
        out.append(UInt8(v & 0xff))
    }

    static func appendName(_ out: inout [UInt8], _ host: String) throws {
        var name = host.lowercased()
        if name.hasSuffix(".") { name.removeLast() }
        guard !name.isEmpty, name.utf8.count <= 253 else { throw CodecError.invalidName(host) }
        for label in name.split(separator: ".", omittingEmptySubsequences: false) {
            let bytes = Array(label.utf8)
            guard !bytes.isEmpty, bytes.count <= 63, bytes.allSatisfy({ $0 < 0x80 }) else {
                throw CodecError.invalidName(host)
            }
            out.append(UInt8(bytes.count))
            out.append(contentsOf: bytes)
        }
        out.append(0)
    }

    /// 解码响应。只解析 Answer 段（Authority / Additional 忽略）
    public static func decodeResponse(_ msg: [UInt8], expectedId: UInt16? = nil) throws -> DNSResponse {
        guard msg.count >= 12 else { throw CodecError.truncated }
        var p = 0
        let id = try readU16(msg, &p)
        let flags = try readU16(msg, &p)
        let qd = try readU16(msg, &p)
        let an = try readU16(msg, &p)
        _ = try readU16(msg, &p)
        _ = try readU16(msg, &p)
        guard flags & 0x8000 != 0 else { throw CodecError.notResponse }
        if let expectedId, expectedId != id { throw CodecError.idMismatch }
        for _ in 0..<qd {
            _ = try readName(msg, &p)
            p += 4
            guard p <= msg.count else { throw CodecError.truncated }
        }
        var answers: [DNSRecord] = []
        for _ in 0..<an {
            let name = try readName(msg, &p)
            let type = try readU16(msg, &p)
            let cls = try readU16(msg, &p)
            let ttlHi = try readU16(msg, &p)
            let ttlLo = try readU16(msg, &p)
            let len = Int(try readU16(msg, &p))
            guard p + len <= msg.count else { throw CodecError.truncated }
            answers.append(DNSRecord(
                name: name, type: type, rrClass: cls,
                ttl: UInt32(ttlHi) << 16 | UInt32(ttlLo), data: Array(msg[p..<(p + len)])
            ))
            p += len
        }
        return DNSResponse(id: id, flags: flags, answers: answers)
    }

    static func readU16(_ m: [UInt8], _ p: inout Int) throws -> UInt16 {
        guard p + 2 <= m.count else { throw CodecError.truncated }
        defer { p += 2 }
        return UInt16(m[p]) << 8 | UInt16(m[p + 1])
    }

    /// 读域名，支持压缩指针（0xC0），防环
    static func readName(_ m: [UInt8], _ p: inout Int) throws -> String {
        var labels: [String] = []
        var pos = p
        var jumped = false
        var jumps = 0
        while true {
            guard pos < m.count else { throw CodecError.truncated }
            let len = Int(m[pos])
            if len == 0 {
                pos += 1
                break
            }
            if len & 0xC0 == 0xC0 {
                guard pos + 1 < m.count else { throw CodecError.truncated }
                let target = (len & 0x3F) << 8 | Int(m[pos + 1])
                guard target < m.count else { throw CodecError.badPointer }
                if !jumped { p = pos + 2 }
                jumped = true
                jumps += 1
                guard jumps < 64 else { throw CodecError.badPointer }
                pos = target
                continue
            }
            guard len <= 63, pos + 1 + len <= m.count else { throw CodecError.truncated }
            labels.append(String(decoding: m[(pos + 1)...(pos + len)], as: UTF8.self))
            pos += 1 + len
        }
        if !jumped { p = pos }
        return labels.joined(separator: ".")
    }

    /// base64url 无填充（RFC 8484 GET 方式的 `dns` 参数）
    public static func base64URL(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
