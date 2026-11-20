import Foundation

/// WiFi 互传的 JSON 消息。对应 Android `client/data/wifi/WiFiDataHand.java`。
///
/// JSON 结构（fastjson `toJSONString`，null 字段省略）：
/// ```json
/// {"messageType":2,"dataType":1001,"data":{"quick_search":[…]},"totalSize":3,"part":1}
/// ```
/// `totalSize` = 总页数（pageSize），`part` = 当前页（pageIndex，1 起）。
public struct WiFiDataHand: Sendable, Hashable {
    public static let error = 0
    public static let received = 1
    public static let send = 2

    public var messageType: Int
    public var dataType: Int = 0
    /// 总页数，默认 1
    public var pageSize: Int64 = 1
    /// 当前页（1 起），默认 1
    public var pageIndex: Int64 = 1
    public var errorMessage: String?
    public var data: [String: TransferJSON]?

    public init(messageType: Int, dataType: Int = 0, data: [String: TransferJSON]? = nil,
                pageIndex: Int64 = 1, pageSize: Int64 = 1) {
        self.messageType = messageType
        self.dataType = dataType
        self.data = data
        self.pageIndex = pageIndex
        self.pageSize = pageSize
    }

    /// 对应 `WiFiDataHand(String msg)`：解析失败时 messageType = ERROR
    public init(json: String) {
        guard let v = try? TransferJSON.parse(Data(json.utf8)), case let .object(o) = v else {
            self.init(messageType: Self.error, data: [:])
            errorMessage = "invalid json"
            return
        }
        self.init(messageType: o["messageType"]?.intValue ?? 0, dataType: o["dataType"]?.intValue ?? 0,
                  data: o["data"]?.objectValue, pageIndex: o["part"]?.int64Value ?? 0,
                  pageSize: o["totalSize"]?.int64Value ?? 0)
    }

    /// 对应 `addData`
    public mutating func addData(_ key: String, _ value: TransferJSON) {
        if data == nil { data = [:] }
        data?[key] = value
    }

    /// 对应 `toJsonObject`
    public var jsonObject: TransferJSON {
        var o: [String: TransferJSON] = [
            "messageType": .int(Int64(messageType)),
            "dataType": .int(Int64(dataType)),
            "totalSize": .int(pageSize),
            "part": .int(pageIndex),
        ]
        if let data { o["data"] = .object(data) }
        return .object(o)
    }

    /// 序列化后的 UTF-8 JSON
    public func jsonData() -> Data {
        Data(jsonObject.jsonString().utf8)
    }

    /// 对应 `ConnectThread.dataProcessed`：接收端处理完后回给发送端的应答（RECEIVED，回显 data 与页码）
    public func processedReply() -> WiFiDataHand {
        WiFiDataHand(messageType: Self.received, dataType: dataType, data: data,
                     pageIndex: pageIndex, pageSize: pageSize)
    }
}

/// 最小 JSON 值，代替 fastjson `JSONObject` / `JSONArray`（可 Sendable、可比较）。
/// 取值方法模仿 fastjson 的 `getIntValue` / `getLongValue` / `getString` / `getBoolean` 的宽松转换。
public enum TransferJSON: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([TransferJSON])
    case object([String: TransferJSON])

    // MARK: 构造辅助

    /// String? → .string / .null
    public static func string(_ s: String?) -> TransferJSON { s.map(TransferJSON.string) ?? .null }

    /// Float → 以最短十进制表示的 Double（避免 4.3f 变成 4.300000190734863）
    public static func float(_ f: Float) -> TransferJSON {
        guard f.isFinite else { return .null }
        return .double(Double("\(f)") ?? Double(f))
    }

    public static func int(_ i: Int) -> TransferJSON { .int(Int64(i)) }

    // MARK: 取值（fastjson 风格）

    public subscript(key: String) -> TransferJSON? {
        if case let .object(o) = self { return o[key] }
        return nil
    }

    public var isNull: Bool { self == .null }

    public var objectValue: [String: TransferJSON]? {
        if case let .object(o) = self { return o }
        return nil
    }

    public var arrayValue: [TransferJSON]? {
        if case let .array(a) = self { return a }
        return nil
    }

    /// 对应 `getString`：字符串原样；数字 / 布尔转字符串；null → nil；对象 / 数组 → JSON 文本
    public var stringValue: String? {
        switch self {
        case .null: return nil
        case let .string(s): return s
        case let .int(i): return String(i)
        case let .double(d): return Self.format(d)
        case let .bool(b): return b ? "true" : "false"
        case .array, .object: return jsonString()
        }
    }

    /// 对应 `getLongValue`：null / 无法转换 → 0；小数截断
    public var int64Value: Int64 {
        switch self {
        case let .int(i): return i
        case let .double(d): return d.isFinite ? Int64(exactly: d.rounded(.towardZero)) ?? 0 : 0
        case let .bool(b): return b ? 1 : 0
        case let .string(s):
            let t = s.trimmingCharacters(in: .whitespaces)
            if let i = Int64(t) { return i }
            if let d = Double(t), d.isFinite { return Int64(exactly: d.rounded(.towardZero)) ?? 0 }
            return 0
        default: return 0
        }
    }

    /// 对应 `getIntValue`（Java int 溢出时截断）
    public var intValue: Int { Int(Int32(truncatingIfNeeded: int64Value)) }

    /// 对应 `getFloat`（缺失时 Android 会 NPE，这里返回 0）
    public var floatValue: Float {
        switch self {
        case let .int(i): return Float(i)
        case let .double(d): return Float(d)
        case let .string(s): return Float(s.trimmingCharacters(in: .whitespaces)) ?? 0
        case let .bool(b): return b ? 1 : 0
        default: return 0
        }
    }

    /// 对应 `getBoolean`：数字非 0 为 true；字符串 "true" / "1" / "Y"
    public var boolValue: Bool? {
        switch self {
        case let .bool(b): return b
        case let .int(i): return i != 0
        case let .double(d): return d != 0
        case let .string(s):
            switch s.lowercased() {
            case "true", "1", "y", "t": return true
            case "false", "0", "n", "f", "": return false
            default: return nil
            }
        default: return nil
        }
    }

    // MARK: 序列化

    /// 紧凑 JSON；对象键按字典序（fastjson 用 HashMap，顺序不确定，接收端不依赖顺序）。
    /// 非 ASCII 原样输出，控制字符转义为 \uXXXX（与 fastjson 默认行为一致）
    public func jsonString() -> String {
        var out = ""
        write(to: &out)
        return out
    }

    private func write(to out: inout String) {
        switch self {
        case .null: out += "null"
        case let .bool(b): out += b ? "true" : "false"
        case let .int(i): out += String(i)
        case let .double(d): out += d.isFinite ? Self.format(d) : "null"
        case let .string(s): Self.writeString(s, to: &out)
        case let .array(a):
            out += "["
            for (i, v) in a.enumerated() {
                if i > 0 { out += "," }
                v.write(to: &out)
            }
            out += "]"
        case let .object(o):
            out += "{"
            for (i, key) in o.keys.sorted().enumerated() {
                if i > 0 { out += "," }
                Self.writeString(key, to: &out)
                out += ":"
                o[key]!.write(to: &out)
            }
            out += "}"
        }
    }

    static func format(_ d: Double) -> String {
        // Swift 的 description 为最短可还原表示（4.5、1e-05），均为合法 JSON 数字
        "\(d)"
    }

    private static func writeString(_ s: String, to out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }

    // MARK: 解析

    /// 解析 UTF-8 JSON（允许顶层为任意值）
    public static func parse(_ data: Data) throws -> TransferJSON {
        try JSONDecoder().decode(TransferJSON.self, from: data)
    }
}

extension TransferJSON: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? c.decode(Int64.self) {
            self = .int(i)
        } else if let d = try? c.decode(Double.self) {
            self = .double(d)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([TransferJSON].self) {
            self = .array(a)
        } else {
            self = .object(try c.decode([String: TransferJSON].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case let .bool(b): try c.encode(b)
        case let .int(i): try c.encode(i)
        case let .double(d): try c.encode(d)
        case let .string(s): try c.encode(s)
        case let .array(a): try c.encode(a)
        case let .object(o): try c.encode(o)
        }
    }
}
