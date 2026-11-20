import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// 本机网络地址（getifaddrs）。对应 Android `WiFiServerActivity.getWifiApIpAddress` /
/// `WiFiClientActivity.getWifiRouteIPAddress`
public enum LocalNetwork {
    /// 所有处于 UP 状态的接口上的 IPv4 地址
    public static func ipv4Interfaces() -> [TransferEndpoint.InterfaceAddress] {
        var result: [TransferEndpoint.InterfaceAddress] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return result }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            let flags = Int32(truncatingIfNeeded: ifa.pointee.ifa_flags)
            guard flags & Int32(IFF_UP) != 0, flags & Int32(IFF_LOOPBACK) == 0,
                  let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET),
                  let ip = numericHost(addr) else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            let mask = ifa.pointee.ifa_netmask.flatMap(numericHost)
            result.append(.init(name: name, address: ip, netmask: mask))
        }
        return result
    }

    /// 用于二维码的本机 IPv4（en0 优先）
    public static func primaryIPv4() -> String? {
        TransferEndpoint.pickPrimaryIPv4(ipv4Interfaces())?.address
    }

    /// 猜测当前 Wi-Fi 网关（网段第一个地址）。用于连接以热点方式运行的 Android 发送端
    public static func gatewayGuess() -> String? {
        guard let a = TransferEndpoint.pickPrimaryIPv4(ipv4Interfaces()) else { return nil }
        return TransferEndpoint.gatewayGuess(address: a.address, netmask: a.netmask)
    }

    private static func numericHost(_ addr: UnsafeMutablePointer<sockaddr>) -> String? {
        guard addr.pointee.sa_family == sa_family_t(AF_INET) else { return nil }
        return addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin -> String? in
            var a = sin.pointee.sin_addr
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &a, &buf, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
            return String(cString: buf)
        }
    }
}
