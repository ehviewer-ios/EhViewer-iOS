import Foundation

/// 对应 Android `ParserUtils` + `StringUtils.unescapeXml` + `NumberUtils.parseXxxSafely`
public enum ParserUtils {
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
    private static let lock = NSLock()

    /// 毫秒时间戳 -> "yyyy-MM-dd HH:mm"（UTC，与站点显示一致）
    public static func formatDate(_ millis: Int64) -> String {
        lock.lock(); defer { lock.unlock() }
        return dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(millis) / 1000))
    }

    /// "yyyy-MM-dd HH:mm"（UTC）-> 毫秒时间戳
    public static func parseDate(_ s: String) -> Int64? {
        lock.lock(); defer { lock.unlock() }
        guard let d = dateFormatter.date(from: s.trimmingCharacters(in: .whitespaces)) else { return nil }
        return Int64(d.timeIntervalSince1970 * 1000)
    }

    public static func trim(_ str: String?) -> String {
        unescapeXml(str ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func parseInt(_ str: String?, _ def: Int) -> Int {
        Int(trim(str).replacingOccurrences(of: ",", with: "")) ?? def
    }

    public static func parseLong(_ str: String?, _ def: Int64) -> Int64 {
        Int64(trim(str).replacingOccurrences(of: ",", with: "")) ?? def
    }

    public static func parseFloat(_ str: String?, _ def: Float) -> Float {
        Float(trim(str).replacingOccurrences(of: ",", with: "")) ?? def
    }

    /// 反转义 XML/HTML 实体：命名实体（&amp; &lt; &gt; &quot; &apos; &nbsp;）与数字实体（&#39; &#x27;）
    public static func unescapeXml(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        out.reserveCapacity(s.count)
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "&", let semi = s[i...].prefix(12).firstIndex(of: ";") {
                let entity = s[s.index(after: i)..<semi]
                if let rep = decodeEntity(entity) {
                    out.append(rep)
                    i = s.index(after: semi)
                    continue
                }
            }
            out.append(c)
            i = s.index(after: i)
        }
        return out
    }

    private static func decodeEntity(_ e: Substring) -> String? {
        switch e {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "nbsp": return "\u{00A0}"
        default: break
        }
        if e.hasPrefix("#x") || e.hasPrefix("#X") {
            if let v = UInt32(e.dropFirst(2), radix: 16), let u = Unicode.Scalar(v) { return String(Character(u)) }
        } else if e.hasPrefix("#") {
            if let v = UInt32(e.dropFirst()), let u = Unicode.Scalar(v) { return String(Character(u)) }
        }
        return nil
    }
}

/// NSRegularExpression 的便捷封装，Linux 可用
public struct Regex2: Sendable {
    public let re: NSRegularExpression
    public init(_ pattern: String, options: NSRegularExpression.Options = []) {
        // 模式均为编译期常量，失败即编程错误
        // swiftlint:disable:next force_try
        re = try! NSRegularExpression(pattern: pattern, options: options)
    }

    /// 第一次匹配的所有分组（索引 0 为整体）；未参与的分组为 nil
    public func firstMatch(in s: String) -> [String?]? {
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
    }

    public func allMatches(in s: String) -> [[String?]] {
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { i in
                let r = m.range(at: i)
                return r.location == NSNotFound ? nil : ns.substring(with: r)
            }
        }
    }

    public func matches(_ s: String) -> Bool { firstMatch(in: s) != nil }
}
