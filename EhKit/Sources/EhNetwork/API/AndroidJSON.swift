import Foundation

/// 与 Android `org.json.JSONObject.toString()` 字节级一致的 JSON 编码：
/// - 对象键保持插入顺序（Android JSONObject 基于 LinkedHashMap）
/// - 紧凑输出，无空格
/// - 字符串转义：`"` `\` `/` 前加反斜杠；\t \b \n \r \f；其他 ≤ 0x1F 的字符为 `\u00xx`（小写十六进制）
/// JSONSerialization 不保证键顺序，因此 api.php 请求体统一用这个类型构造。
public indirect enum AndroidJSON: Sendable, Hashable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral {
    case int(Int64)
    case string(String)
    case bool(Bool)
    case array([AndroidJSON])
    case object([Pair])

    public struct Pair: Sendable, Hashable {
        public var key: String
        public var value: AndroidJSON
        public init(_ key: String, _ value: AndroidJSON) {
            self.key = key
            self.value = value
        }
    }

    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int64) { self = .int(value) }

    /// 按顺序构造对象
    public static func obj(_ pairs: (String, AndroidJSON)...) -> AndroidJSON {
        .object(pairs.map { Pair($0.0, $0.1) })
    }

    public var encoded: String {
        var out = ""
        write(into: &out)
        return out
    }

    public var data: Data { Data(encoded.utf8) }

    private func write(into out: inout String) {
        switch self {
        case let .int(v):
            out += String(v)
        case let .bool(v):
            out += v ? "true" : "false"
        case let .string(s):
            Self.quote(s, into: &out)
        case let .array(items):
            out += "["
            for (i, v) in items.enumerated() {
                if i > 0 { out += "," }
                v.write(into: &out)
            }
            out += "]"
        case let .object(pairs):
            out += "{"
            for (i, p) in pairs.enumerated() {
                if i > 0 { out += "," }
                Self.quote(p.key, into: &out)
                out += ":"
                p.value.write(into: &out)
            }
            out += "}"
        }
    }

    /// 对应 `JSONStringer.string`
    static func quote(_ s: String, into out: inout String) {
        out += "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"", "\\", "/":
                out += "\\"
                out.unicodeScalars.append(u)
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\u{0C}": out += "\\f"
            default:
                if u.value <= 0x1F {
                    out += String(format: "\\u%04x", u.value)
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        out += "\""
    }
}
