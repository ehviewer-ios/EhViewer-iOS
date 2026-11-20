import Foundation

/// 纯 Swift MD5（EhCore 需在 Linux 编译，不能用 CryptoKit）。
/// 用于 WiFi 下载目录迁移的文件校验，对应 Android `MessageDigest.getInstance("MD5")`
public struct MD5: Sendable {
    private var a0: UInt32 = 0x6745_2301
    private var b0: UInt32 = 0xEFCD_AB89
    private var c0: UInt32 = 0x98BA_DCFE
    private var d0: UInt32 = 0x1032_5476
    private var buffer: [UInt8] = []
    private var totalLength: UInt64 = 0

    private static let s: [UInt32] = [
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
        5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
        4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
        6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
    ]

    private static let k: [UInt32] = [
        0xD76A_A478, 0xE8C7_B756, 0x2420_70DB, 0xC1BD_CEEE, 0xF57C_0FAF, 0x4787_C62A, 0xA830_4613, 0xFD46_9501,
        0x6980_98D8, 0x8B44_F7AF, 0xFFFF_5BB1, 0x895C_D7BE, 0x6B90_1122, 0xFD98_7193, 0xA679_438E, 0x49B4_0821,
        0xF61E_2562, 0xC040_B340, 0x265E_5A51, 0xE9B6_C7AA, 0xD62F_105D, 0x0244_1453, 0xD8A1_E681, 0xE7D3_FBC8,
        0x21E1_CDE6, 0xC337_07D6, 0xF4D5_0D87, 0x455A_14ED, 0xA9E3_E905, 0xFCEF_A3F8, 0x676F_02D9, 0x8D2A_4C8A,
        0xFFFA_3942, 0x8771_F681, 0x6D9D_6122, 0xFDE5_380C, 0xA4BE_EA44, 0x4BDE_CFA9, 0xF6BB_4B60, 0xBEBF_BC70,
        0x289B_7EC6, 0xEAA1_27FA, 0xD4EF_3085, 0x0488_1D05, 0xD9D4_D039, 0xE6DB_99E5, 0x1FA2_7CF8, 0xC4AC_5665,
        0xF429_2244, 0x432A_FF97, 0xAB94_23A7, 0xFC93_A039, 0x655B_59C3, 0x8F0C_CC92, 0xFFEF_F47D, 0x8584_5DD1,
        0x6FA8_7E4F, 0xFE2C_E6E0, 0xA301_4314, 0x4E08_11A1, 0xF753_7E82, 0xBD3A_F235, 0x2AD7_D2BB, 0xEB86_D391,
    ]

    public init() {
        buffer.reserveCapacity(64)
    }

    /// 一次性计算摘要（16 字节）
    public static func hash(_ data: Data) -> Data {
        var m = MD5()
        m.update(data)
        return m.finalize()
    }

    /// 摘要的小写十六进制串（与 Android `bytesToHex` 一致）
    public static func hexString(_ data: Data) -> String {
        hex(hash(data))
    }

    static func hex(_ digest: Data) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    public mutating func update(_ data: Data) {
        data.withUnsafeBytes { raw in
            update(raw.bindMemory(to: UInt8.self))
        }
    }

    public mutating func update(_ bytes: UnsafeBufferPointer<UInt8>) {
        totalLength &+= UInt64(bytes.count)
        var i = 0
        if !buffer.isEmpty {
            let n = min(64 - buffer.count, bytes.count)
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
        var tail = buffer
        tail.append(0x80)
        while tail.count % 64 != 56 { tail.append(0) }
        // MD5 长度为小端
        for i in 0..<8 { tail.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(i * 8))) }
        buffer.removeAll()
        tail.withUnsafeBufferPointer { p in
            var off = 0
            while off + 64 <= p.count {
                process(p, offset: off)
                off += 64
            }
        }
        var out = Data(capacity: 16)
        for v in [a0, b0, c0, d0] {
            out.append(UInt8(v & 0xFF)); out.append(UInt8((v >> 8) & 0xFF))
            out.append(UInt8((v >> 16) & 0xFF)); out.append(UInt8(v >> 24))
        }
        return out
    }

    /// 摘要的小写十六进制串
    public mutating func finalizeHex() -> String {
        Self.hex(finalize())
    }

    private mutating func process(_ p: UnsafeBufferPointer<UInt8>, offset: Int) {
        var m = [UInt32](repeating: 0, count: 16)
        for t in 0..<16 {
            let b = offset + t * 4
            m[t] = UInt32(p[b]) | UInt32(p[b + 1]) << 8 | UInt32(p[b + 2]) << 16 | UInt32(p[b + 3]) << 24
        }
        var a = a0, b = b0, c = c0, d = d0
        for i in 0..<64 {
            var f: UInt32
            let g: Int
            switch i {
            case 0..<16: f = (b & c) | (~b & d); g = i
            case 16..<32: f = (d & b) | (~d & c); g = (5 * i + 1) % 16
            case 32..<48: f = b ^ c ^ d; g = (3 * i + 5) % 16
            default: f = c ^ (b | ~d); g = (7 * i) % 16
            }
            f = f &+ a &+ Self.k[i] &+ m[g]
            a = d; d = c; c = b
            let sh = Self.s[i]
            b = b &+ ((f << sh) | (f >> (32 - sh)))
        }
        a0 &+= a; b0 &+= b; c0 &+= c; d0 &+= d
    }
}
