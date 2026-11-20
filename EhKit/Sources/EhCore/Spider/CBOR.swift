import Foundation

/// 通用 CBOR（RFC 8949）值。用于读取新版 Android（及上游 EhViewer）写出的 CBOR 格式 `.ehviewer`。
/// 对应 Android `spider/CborSpiderHeader.kt`（Android 只读 gid/token，这里完整解码）。
public indirect enum CBORValue: Sendable, Hashable {
    case unsigned(UInt64)
    /// 负整数，实际值为 `-1 - n`
    case negative(UInt64)
    case bytes(Data)
    case text(String)
    case array([CBORValue])
    case map([CBORMapEntry])
    case tagged(UInt64, CBORValue)
    case bool(Bool)
    case null
    case undefined
    case simple(UInt8)
    case float(Double)

    /// 整数值（能放进 Int64 时）
    public var int64Value: Int64? {
        switch self {
        case let .unsigned(v): return v <= UInt64(Int64.max) ? Int64(v) : nil
        case let .negative(n): return n <= UInt64(Int64.max) ? -1 - Int64(n) : nil
        case let .tagged(_, v): return v.int64Value
        default: return nil
        }
    }

    public var intValue: Int? {
        guard let v = int64Value, v >= Int64(Int.min), v <= Int64(Int.max) else { return nil }
        return Int(v)
    }

    public var stringValue: String? {
        if case let .text(s) = self { return s }
        if case let .tagged(_, v) = self { return v.stringValue }
        return nil
    }

    public var mapEntries: [CBORMapEntry]? {
        if case let .map(m) = self { return m }
        return nil
    }

    /// 按文本 key 取 map 中的值
    public subscript(key: String) -> CBORValue? {
        mapEntries?.first(where: { $0.key.stringValue == key })?.value
    }
}

public struct CBORMapEntry: Sendable, Hashable {
    public var key: CBORValue
    public var value: CBORValue
    public init(key: CBORValue, value: CBORValue) {
        self.key = key
        self.value = value
    }
}

public enum CBORError: Error, Sendable, Equatable {
    case truncated
    case tooLarge
    case tooDeep
    case invalid(String)
}

/// 带深度 / 字节上限的 CBOR 读取游标。上限与 Android `CborSpiderHeader` 一致（深度 16，32 MiB）。
public struct CBORReader {
    public static let defaultMaxDepth = 16
    public static let defaultMaxBytes = 32 * 1024 * 1024
    public static let breakByte: UInt8 = 0xFF

    private let bytes: [UInt8]
    public private(set) var offset: Int = 0
    public let maxDepth: Int
    public let maxBytes: Int

    public init(_ data: Data, maxDepth: Int = defaultMaxDepth, maxBytes: Int = defaultMaxBytes) {
        self.init(bytes: [UInt8](data), maxDepth: maxDepth, maxBytes: maxBytes)
    }

    public init(bytes: [UInt8], maxDepth: Int = defaultMaxDepth, maxBytes: Int = defaultMaxBytes) {
        self.bytes = bytes
        self.maxDepth = maxDepth
        self.maxBytes = maxBytes
    }

    public var isAtEnd: Bool { offset >= bytes.count }

    // MARK: 基础读取

    private mutating func readByte() throws -> UInt8 {
        guard offset < bytes.count else { throw CBORError.truncated }
        guard offset < maxBytes else { throw CBORError.tooLarge }
        let b = bytes[offset]
        offset += 1
        return b
    }

    private mutating func readBytes(_ count: UInt64) throws -> ArraySlice<UInt8> {
        guard count <= UInt64(Int.max) else { throw CBORError.tooLarge }
        let n = Int(count)
        guard n <= bytes.count - offset else { throw CBORError.truncated }
        guard offset + n <= maxBytes else { throw CBORError.tooLarge }
        let slice = bytes[offset ..< offset + n]
        offset += n
        return slice
    }

    /// 下一个字节是否为 break（0xFF），不移动游标
    public func peekBreak() throws -> Bool {
        guard offset < bytes.count else { throw CBORError.truncated }
        return bytes[offset] == Self.breakByte
    }

    public mutating func consumeBreak() throws {
        guard try readByte() == Self.breakByte else { throw CBORError.invalid("expected break") }
    }

    /// 按附加信息读取无符号参数
    private mutating func readArgument(_ info: UInt8) throws -> UInt64 {
        if info < 24 { return UInt64(info) }
        let width: Int
        switch info {
        case 24: width = 1
        case 25: width = 2
        case 26: width = 4
        case 27: width = 8
        default: throw CBORError.invalid("bad argument \(info)")
        }
        var value: UInt64 = 0
        for _ in 0 ..< width {
            value = (value << 8) | UInt64(try readByte())
        }
        return value
    }

    // MARK: 容器头

    /// 读取 map 头。返回元素数量；不定长返回 nil。当前不是 map 时抛错（游标已前移）。
    public mutating func readMapHeader() throws -> Int? {
        let head = try readByte()
        guard head >> 5 == 5 else { throw CBORError.invalid("not a map") }
        let info = head & 0x1F
        if info == 31 { return nil }
        let count = try readArgument(info)
        guard count <= UInt64(Int.max) else { throw CBORError.tooLarge }
        return Int(count)
    }

    // MARK: 值

    public mutating func readValue() throws -> CBORValue {
        try readValue(depth: 0)
    }

    /// 跳过一个完整值
    public mutating func skipValue() throws {
        _ = try readValue(depth: 0)
    }

    private mutating func readValue(depth: Int) throws -> CBORValue {
        if depth > maxDepth { throw CBORError.tooDeep }
        let head = try readByte()
        let major = head >> 5
        let info = head & 0x1F
        switch major {
        case 0, 1:
            if info == 31 { throw CBORError.invalid("bad integer") }
            let v = try readArgument(info)
            return major == 0 ? .unsigned(v) : .negative(v)
        case 2:
            return .bytes(Data(try readStringBody(major: 2, info: info)))
        case 3:
            let raw = try readStringBody(major: 3, info: info)
            guard let s = String(bytes: raw, encoding: .utf8) else { throw CBORError.invalid("bad utf8") }
            return .text(s)
        case 4:
            var items: [CBORValue] = []
            if info == 31 {
                while try !peekBreak() { items.append(try readValue(depth: depth + 1)) }
                try consumeBreak()
            } else {
                let count = try readArgument(info)
                var i: UInt64 = 0
                while i < count {
                    items.append(try readValue(depth: depth + 1))
                    i += 1
                }
            }
            return .array(items)
        case 5:
            var entries: [CBORMapEntry] = []
            if info == 31 {
                while try !peekBreak() {
                    let k = try readValue(depth: depth + 1)
                    let v = try readValue(depth: depth + 1)
                    entries.append(CBORMapEntry(key: k, value: v))
                }
                try consumeBreak()
            } else {
                let count = try readArgument(info)
                var i: UInt64 = 0
                while i < count {
                    let k = try readValue(depth: depth + 1)
                    let v = try readValue(depth: depth + 1)
                    entries.append(CBORMapEntry(key: k, value: v))
                    i += 1
                }
            }
            return .map(entries)
        case 6:
            if info == 31 { throw CBORError.invalid("bad tag") }
            let tag = try readArgument(info)
            return .tagged(tag, try readValue(depth: depth + 1))
        default: // 7
            return try readSimple(info)
        }
    }

    private mutating func readStringBody(major: UInt8, info: UInt8) throws -> [UInt8] {
        if info != 31 {
            return Array(try readBytes(try readArgument(info)))
        }
        // 不定长：只接受同主类型的定长分块
        var out: [UInt8] = []
        while try !peekBreak() {
            let chunk = try readByte()
            if chunk >> 5 != major || chunk & 0x1F == 31 {
                throw CBORError.invalid("bad indefinite string")
            }
            out.append(contentsOf: try readBytes(try readArgument(chunk & 0x1F)))
        }
        try consumeBreak()
        return out
    }

    private mutating func readSimple(_ info: UInt8) throws -> CBORValue {
        switch info {
        case 20: return .bool(false)
        case 21: return .bool(true)
        case 22: return .null
        case 23: return .undefined
        case 0 ..< 20: return .simple(info)
        case 24: return .simple(try readByte())
        case 25:
            let b = try readBytes(2)
            let bits = UInt16(b[b.startIndex]) << 8 | UInt16(b[b.startIndex + 1])
            return .float(Self.halfToDouble(bits))
        case 26:
            var bits: UInt32 = 0
            for x in try readBytes(4) { bits = bits << 8 | UInt32(x) }
            return .float(Double(Float(bitPattern: bits)))
        case 27:
            var bits: UInt64 = 0
            for x in try readBytes(8) { bits = bits << 8 | UInt64(x) }
            return .float(Double(bitPattern: bits))
        default:
            // 31 = break 不能出现在值的位置；28..30 保留
            throw CBORError.invalid("bad simple \(info)")
        }
    }

    /// IEEE 754 半精度 → Double（不依赖 Float16，x86 macOS 不可用）
    static func halfToDouble(_ bits: UInt16) -> Double {
        let sign: Double = (bits & 0x8000) != 0 ? -1 : 1
        let exp = Int((bits >> 10) & 0x1F)
        let mant = Double(bits & 0x3FF)
        if exp == 0 { return sign * mant * pow(2, -24) }
        if exp == 31 { return mant == 0 ? sign * .infinity : .nan }
        return sign * (1 + mant / 1024) * pow(2, Double(exp - 15))
    }
}
