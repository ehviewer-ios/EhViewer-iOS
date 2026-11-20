import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// IPv4 / IPv6 地址（对应 Android `InetAddress` 在本模块中的用法）
public struct EhIPAddress: Sendable, Hashable, Codable, CustomStringConvertible {
    public enum Family: Sendable, Hashable, Codable { case v4, v6 }

    /// 网络字节序，4 或 16 字节
    public let bytes: [UInt8]

    public init?(bytes: [UInt8]) {
        guard bytes.count == 4 || bytes.count == 16 else { return nil }
        self.bytes = bytes
    }

    /// 解析 IP 字面量（IPv6 可带方括号）。对应 `Hosts.isValidIp / parseV4 / parseV6`
    public init?(_ string: String) {
        var s = string.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("["), s.hasSuffix("]") { s = String(s.dropFirst().dropLast()) }
        guard !s.isEmpty else { return nil }
        if s.contains(":") {
            var buf = [UInt8](repeating: 0, count: 16)
            guard inet_pton(AF_INET6, s, &buf) == 1 else { return nil }
            bytes = buf
        } else {
            var buf = [UInt8](repeating: 0, count: 4)
            guard inet_pton(AF_INET, s, &buf) == 1 else { return nil }
            bytes = buf
        }
    }

    public var family: Family { bytes.count == 4 ? .v4 : .v6 }

    public var description: String {
        if bytes.count == 4 { return bytes.map(String.init).joined(separator: ".") }
        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let ok = bytes.withUnsafeBytes { raw in
            inet_ntop(AF_INET6, raw.baseAddress, &buf, socklen_t(buf.count)) != nil
        }
        if ok { return String(cString: buf) }
        return stride(from: 0, to: 16, by: 2).map { String(format: "%x", Int(bytes[$0]) << 8 | Int(bytes[$0 + 1])) }
            .joined(separator: ":")
    }

    /// URL 中使用的形式（IPv6 带方括号）
    public var urlHost: String { family == .v6 ? "[\(description)]" : description }

    public static func isIPLiteral(_ host: String) -> Bool { EhIPAddress(host) != nil }
}

/// 对应 `Hosts.isValidHost`：小写字母数字、'-'、'.'，每段 1~63，总长 ≤ 253
public func ehIsValidHost(_ host: String) -> Bool {
    guard !host.isEmpty, host.utf8.count <= 253 else { return false }
    var labelLength = 0
    for ch in host.utf8 {
        if ch == UInt8(ascii: ".") {
            if labelLength < 1 || labelLength > 63 { return false }
            labelLength = 0
        } else {
            labelLength += 1
        }
        let ok = (ch >= 97 && ch <= 122) || (ch >= 48 && ch <= 57) || ch == 45 || ch == 46
        if !ok { return false }
    }
    return labelLength >= 1 && labelLength <= 63
}
