import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// 系统 DNS（getaddrinfo）。对应 `InetAddress.getAllByName`
public enum SystemResolver {
    public static func lookup(_ host: String) async throws -> [EhIPAddress] {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do { cont.resume(returning: try lookupBlocking(host)) } catch { cont.resume(throwing: error) }
            }
        }
    }

    public static func lookupBlocking(_ host: String) throws -> [EhIPAddress] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        #if os(Linux)
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #else
        hints.ai_socktype = SOCK_STREAM
        #endif
        var res: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, nil, &hints, &res)
        guard rc == 0, let first = res else {
            let msg = rc != 0 ? String(cString: gai_strerror(rc)) : "无结果"
            throw EhTransportError.unresolvedHost("\(host)：\(msg)")
        }
        defer { freeaddrinfo(first) }
        var out: [EhIPAddress] = []
        var cur: UnsafeMutablePointer<addrinfo>? = first
        while let ai = cur {
            if let sa = ai.pointee.ai_addr {
                if ai.pointee.ai_family == AF_INET {
                    let sin = UnsafeRawPointer(sa).assumingMemoryBound(to: sockaddr_in.self).pointee
                    var addr = sin.sin_addr
                    let bytes = withUnsafeBytes(of: &addr) { Array($0) }
                    if let ip = EhIPAddress(bytes: bytes), !out.contains(ip) { out.append(ip) }
                } else if ai.pointee.ai_family == AF_INET6 {
                    let sin6 = UnsafeRawPointer(sa).assumingMemoryBound(to: sockaddr_in6.self).pointee
                    var addr = sin6.sin6_addr
                    let bytes = withUnsafeBytes(of: &addr) { Array($0) }
                    if let ip = EhIPAddress(bytes: bytes), !out.contains(ip) { out.append(ip) }
                }
            }
            cur = ai.pointee.ai_next
        }
        guard !out.isEmpty else { throw EhTransportError.unresolvedHost(host) }
        return out
    }
}
