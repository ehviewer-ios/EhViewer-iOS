import Foundation

/// 纯 Swift SHA-1（EhCore 需在 Linux 编译，不能用 CryptoKit）。
/// 用于标签翻译库的 sha1 校验，对应 Android `MessageDigest.getInstance("SHA-1")`
public struct SHA1: Sendable {
    private var h: (UInt32, UInt32, UInt32, UInt32, UInt32) =
        (0x6745_2301, 0xEFCD_AB89, 0x98BA_DCFE, 0x1032_5476, 0xC3D2_E1F0)
    private var buffer: [UInt8] = []
    private var totalLength: UInt64 = 0

    public init() {
        buffer.reserveCapacity(64)
    }

    /// 一次性计算摘要（20 字节）
    public static func hash(_ data: Data) -> Data {
        var s = SHA1()
        s.update(data)
        return s.finalize()
    }

    /// 摘要的小写十六进制串
    public static func hexString(_ data: Data) -> String {
        hash(data).map { String(format: "%02x", $0) }.joined()
    }

    public mutating func update(_ data: Data) {
        data.withUnsafeBytes { raw in
            update(raw.bindMemory(to: UInt8.self))
        }
    }

    public mutating func update(_ bytes: UnsafeBufferPointer<UInt8>) {
        totalLength &+= UInt64(bytes.count)
        var i = 0
        // 先补满缓冲区
        if !buffer.isEmpty {
            let need = 64 - buffer.count
            let n = min(need, bytes.count)
            buffer.append(contentsOf: bytes[0..<n])
            i = n
            if buffer.count == 64 {
                buffer.withUnsafeBufferPointer { process($0, offset: 0) }
                buffer.removeAll(keepingCapacity: true)
            }
        }
        while i + 64 <= bytes.count {
            process(bytes, offset: i)
            i += 64
        }
        if i < bytes.count {
            buffer.append(contentsOf: bytes[i..<bytes.count])
        }
    }

    public mutating func finalize() -> Data {
        let bitLength = totalLength &* 8
        var pad: [UInt8] = [0x80]
        let rem = (buffer.count + 1) % 64
        let zeros = rem <= 56 ? 56 - rem : 120 - rem
        pad.append(contentsOf: [UInt8](repeating: 0, count: zeros))
        for s in stride(from: 56, through: 0, by: -8) {
            pad.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(s)))
        }
        // 直接处理填充，避免 totalLength 被再次累加
        var tail = buffer + pad
        buffer.removeAll()
        tail.withUnsafeBufferPointer { p in
            var off = 0
            while off + 64 <= p.count {
                process(p, offset: off)
                off += 64
            }
        }
        tail.removeAll()
        var out = Data(capacity: 20)
        for v in [h.0, h.1, h.2, h.3, h.4] {
            out.append(UInt8(v >> 24)); out.append(UInt8((v >> 16) & 0xFF))
            out.append(UInt8((v >> 8) & 0xFF)); out.append(UInt8(v & 0xFF))
        }
        return out
    }

    private mutating func process(_ p: UnsafeBufferPointer<UInt8>, offset: Int) {
        var w = [UInt32](repeating: 0, count: 80)
        for t in 0..<16 {
            let b = offset + t * 4
            w[t] = UInt32(p[b]) << 24 | UInt32(p[b + 1]) << 16 | UInt32(p[b + 2]) << 8 | UInt32(p[b + 3])
        }
        for t in 16..<80 {
            let x = w[t - 3] ^ w[t - 8] ^ w[t - 14] ^ w[t - 16]
            w[t] = (x << 1) | (x >> 31)
        }
        var a = h.0, b = h.1, c = h.2, d = h.3, e = h.4
        for t in 0..<80 {
            let f: UInt32, k: UInt32
            switch t {
            case 0..<20: f = (b & c) | (~b & d); k = 0x5A82_7999
            case 20..<40: f = b ^ c ^ d; k = 0x6ED9_EBA1
            case 40..<60: f = (b & c) | (b & d) | (c & d); k = 0x8F1B_BCDC
            default: f = b ^ c ^ d; k = 0xCA62_C1D6
            }
            let temp = ((a << 5) | (a >> 27)) &+ f &+ e &+ k &+ w[t]
            e = d; d = c; c = (b << 30) | (b >> 2); b = a; a = temp
        }
        h.0 &+= a; h.1 &+= b; h.2 &+= c; h.3 &+= d; h.4 &+= e
    }
}
