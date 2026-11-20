import Foundation

/// Content-Encoding 解码（gzip / deflate）。
/// Apple 平台优先用 Foundation 的 `NSData.decompressed(using: .zlib)`（底层 Compression 框架，处理裸 DEFLATE）；
/// 其他平台或失败时回落到纯 Swift 的 `Inflate`。gzip/zlib 头尾由这里手动剥离。
public enum ContentDecoding {
    public static func decode(_ data: Data, contentEncoding: String?) throws -> Data {
        guard let enc = contentEncoding?.lowercased().trimmingCharacters(in: .whitespaces), !enc.isEmpty, !data.isEmpty else {
            return data
        }
        // 多重编码按逆序解码，如 "gzip, deflate"
        var result = data
        for e in enc.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }).reversed() {
            switch e {
            case "gzip", "x-gzip": result = try gunzip(result)
            case "deflate": result = try inflateZlibOrRaw(result)
            case "identity", "": continue
            default: throw EhTransportError.protocolError("不支持的 Content-Encoding：\(e)")
            }
        }
        return result
    }

    /// 解 gzip（RFC 1952），支持多 member
    public static func gunzip(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        var out = Data()
        var offset = 0
        repeat {
            let start = try gzipHeaderLength(bytes, at: offset)
            let (raw, consumed) = try inflateRaw(bytes, from: start, trailer: 8)
            out.append(raw)
            offset = start + consumed + 8 // CRC32 + ISIZE
        } while offset + 18 <= bytes.count && bytes[offset] == 0x1f && bytes[offset + 1] == 0x8b
        return out
    }

    /// 解析 gzip 头，返回 DEFLATE 数据起始偏移
    static func gzipHeaderLength(_ b: [UInt8], at base: Int) throws -> Int {
        guard b.count >= base + 10, b[base] == 0x1f, b[base + 1] == 0x8b, b[base + 2] == 8 else {
            throw EhTransportError.protocolError("非法 gzip 头")
        }
        let flags = b[base + 3]
        var p = base + 10
        if flags & 0x04 != 0 { // FEXTRA
            guard p + 2 <= b.count else { throw EhTransportError.protocolError("gzip 头截断") }
            p += 2 + (Int(b[p]) | (Int(b[p + 1]) << 8))
        }
        if flags & 0x08 != 0 { // FNAME
            while p < b.count, b[p] != 0 { p += 1 }
            p += 1
        }
        if flags & 0x10 != 0 { // FCOMMENT
            while p < b.count, b[p] != 0 { p += 1 }
            p += 1
        }
        if flags & 0x02 != 0 { p += 2 } // FHCRC
        guard p <= b.count else { throw EhTransportError.protocolError("gzip 头截断") }
        return p
    }

    /// HTTP 的 "deflate" 本应是 zlib 包装（RFC 1950），但不少服务器直接发裸 DEFLATE，两者都支持
    public static func inflateZlibOrRaw(_ data: Data) throws -> Data {
        let b = [UInt8](data)
        if b.count >= 2, b[0] & 0x0f == 8, (Int(b[0]) << 8 | Int(b[1])) % 31 == 0, b[1] & 0x20 == 0 {
            return try inflateRaw(b, from: 2, trailer: 4).data
        }
        return try inflateRaw(b, from: 0, trailer: 0).data
    }

    /// 裸 DEFLATE。返回解压数据与消耗的输入字节数（纯 Swift 路径能精确给出；系统路径按 count - trailer 估算）
    static func inflateRaw(_ b: [UInt8], from start: Int, trailer: Int) throws -> (data: Data, consumed: Int) {
        #if canImport(Compression)
        let end = max(start, b.count - trailer)
        if end > start {
            if let d = try? (Data(b[start..<end]) as NSData).decompressed(using: .zlib) as Data {
                return (d, end - start)
            }
        }
        #endif
        var inf = Inflate(input: b, position: start)
        let out = try inf.run()
        return (Data(out), inf.consumedBytes - start)
    }
}

/// 纯 Swift DEFLATE 解码（RFC 1951，参考 zlib 的 puff.c）
public struct Inflate {
    private let input: [UInt8]
    private var pos: Int
    private var bitBuf: UInt32 = 0
    private var bitCnt = 0
    private var out: [UInt8] = []

    public init(input: [UInt8], position: Int = 0) {
        self.input = input
        self.pos = position
    }

    /// 已消耗到的输入位置（块结束后按字节对齐）
    public var consumedBytes: Int { pos }

    public static func inflate(_ data: [UInt8]) throws -> [UInt8] {
        var i = Inflate(input: data)
        return try i.run()
    }

    struct Huffman {
        var count = [Int](repeating: 0, count: 16)
        var symbol: [Int]
        init(lengths: ArraySlice<Int>) throws {
            symbol = [Int](repeating: 0, count: lengths.count)
            for l in lengths { count[l] += 1 }
            if count[0] == lengths.count { return } // 空码表
            var left = 1
            for len in 1...15 {
                left <<= 1
                left -= count[len]
                if left < 0 { throw EhTransportError.protocolError("deflate: 码表过满") }
            }
            var offs = [Int](repeating: 0, count: 16)
            for len in 1..<15 { offs[len + 1] = offs[len] + count[len] }
            for (sym, l) in lengths.enumerated() where l != 0 {
                symbol[offs[l]] = sym
                offs[l] += 1
            }
        }
    }

    private static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    private static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    private static let distBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
    private static let distExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
    // swiftlint:disable force_try
    private static let fixedTables: (Huffman, Huffman) = {
        var lengths = [Int](repeating: 0, count: 288 + 30)
        for i in 0..<144 { lengths[i] = 8 }
        for i in 144..<256 { lengths[i] = 9 }
        for i in 256..<280 { lengths[i] = 7 }
        for i in 280..<288 { lengths[i] = 8 }
        for i in 288..<318 { lengths[i] = 5 }
        return (try! Huffman(lengths: lengths[0..<288]), try! Huffman(lengths: lengths[288..<318]))
    }()
    // swiftlint:enable force_try

    private mutating func bits(_ need: Int) throws -> Int {
        var val = bitBuf
        while bitCnt < need {
            guard pos < input.count else { throw EhTransportError.protocolError("deflate: 数据截断") }
            val |= UInt32(input[pos]) << UInt32(bitCnt)
            pos += 1
            bitCnt += 8
        }
        bitBuf = need >= 32 ? 0 : val >> UInt32(need)
        bitCnt -= need
        return Int(val & ((UInt32(1) << UInt32(need)) &- 1))
    }

    private mutating func decode(_ h: Huffman) throws -> Int {
        var code = 0, first = 0, index = 0
        for len in 1...15 {
            code |= try bits(1)
            let count = h.count[len]
            if code - count < first { return h.symbol[index + (code - first)] }
            index += count
            first += count
            first <<= 1
            code <<= 1
        }
        throw EhTransportError.protocolError("deflate: 无效编码")
    }

    public mutating func run() throws -> [UInt8] {
        out.reserveCapacity(input.count * 4)
        var last = 0
        repeat {
            last = try bits(1)
            let type = try bits(2)
            switch type {
            case 0: try stored()
            case 1: try codes(Self.fixedTables.0, Self.fixedTables.1)
            case 2: try dynamic()
            default: throw EhTransportError.protocolError("deflate: 非法块类型")
            }
        } while last == 0
        // 丢弃未满字节
        bitBuf = 0
        bitCnt = 0
        return out
    }

    private mutating func stored() throws {
        bitBuf = 0
        bitCnt = 0
        guard pos + 4 <= input.count else { throw EhTransportError.protocolError("deflate: stored 截断") }
        let len = Int(input[pos]) | Int(input[pos + 1]) << 8
        let nlen = Int(input[pos + 2]) | Int(input[pos + 3]) << 8
        pos += 4
        guard len == (~nlen & 0xffff) else { throw EhTransportError.protocolError("deflate: stored 长度校验失败") }
        guard pos + len <= input.count else { throw EhTransportError.protocolError("deflate: stored 截断") }
        out.append(contentsOf: input[pos..<(pos + len)])
        pos += len
    }

    private mutating func codes(_ lencode: Huffman, _ distcode: Huffman) throws {
        while true {
            var symbol = try decode(lencode)
            if symbol < 256 {
                out.append(UInt8(symbol))
            } else if symbol == 256 {
                return
            } else {
                symbol -= 257
                guard symbol < 29 else { throw EhTransportError.protocolError("deflate: 非法长度码") }
                let len = Self.lengthBase[symbol] + (try bits(Self.lengthExtra[symbol]))
                let ds = try decode(distcode)
                guard ds < 30 else { throw EhTransportError.protocolError("deflate: 非法距离码") }
                let dist = Self.distBase[ds] + (try bits(Self.distExtra[ds]))
                guard dist <= out.count else { throw EhTransportError.protocolError("deflate: 距离越界") }
                let from = out.count - dist
                if dist >= len {
                    out.append(contentsOf: out[from..<(from + len)])
                } else {
                    for k in 0..<len { out.append(out[from + k]) }
                }
            }
        }
    }

    private static let order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    private mutating func dynamic() throws {
        let nlen = try bits(5) + 257
        let ndist = try bits(5) + 1
        let ncode = try bits(4) + 4
        guard nlen <= 286, ndist <= 30 else { throw EhTransportError.protocolError("deflate: 码长计数非法") }
        var lengths = [Int](repeating: 0, count: 320)
        for i in 0..<ncode { lengths[Self.order[i]] = try bits(3) }
        let lencode0 = try Huffman(lengths: lengths[0..<19])
        var index = 0
        while index < nlen + ndist {
            var symbol = try decode(lencode0)
            if symbol < 16 {
                lengths[index] = symbol
                index += 1
            } else {
                var len = 0
                if symbol == 16 {
                    guard index > 0 else { throw EhTransportError.protocolError("deflate: 重复码无前值") }
                    len = lengths[index - 1]
                    symbol = 3 + (try bits(2))
                } else if symbol == 17 {
                    symbol = 3 + (try bits(3))
                } else {
                    symbol = 11 + (try bits(7))
                }
                guard index + symbol <= nlen + ndist else { throw EhTransportError.protocolError("deflate: 码长过多") }
                for _ in 0..<symbol {
                    lengths[index] = len
                    index += 1
                }
            }
        }
        guard lengths[256] != 0 else { throw EhTransportError.protocolError("deflate: 缺少结束码") }
        let lencode = try Huffman(lengths: lengths[0..<nlen])
        let distcode = try Huffman(lengths: lengths[nlen..<(nlen + ndist)])
        try codes(lencode, distcode)
    }
}
