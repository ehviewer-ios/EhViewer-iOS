import Foundation
import SwiftSoup

// 杂项解析器共用的 SwiftSoup 安全访问辅助（SwiftSoup 的 child(i) 越界会直接崩溃）
extension Element {
    /// 越界返回 nil 的 child(i)，对应 Jsoup `child(i)`（Jsoup 越界抛异常，这里用 nil 表示）
    func miscChild(_ index: Int) -> Element? {
        let c = children()
        guard index >= 0, index < c.size() else { return nil }
        return c.get(index)
    }
}

extension Elements {
    func miscGet(_ index: Int) -> Element? {
        guard index >= 0, index < size() else { return nil }
        return get(index)
    }
}

/// 对应 org.json `JSONObject.getXxx` 的宽松取值（数字/字符串均可）
enum MiscJSON {
    static func object(_ body: String) -> [String: Any]? {
        guard let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any]
        else { return nil }
        return obj
    }

    static func double(_ v: Any?) -> Double? {
        switch v {
        case let i as Int: return Double(i)
        case let d as Double: return d
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }

    static func int64(_ v: Any?) -> Int64? {
        switch v {
        case let i as Int: return Int64(i)
        case let d as Double: return Int64(d)
        case let n as NSNumber: return n.int64Value
        case let s as String: return Int64(s) ?? Double(s).map { Int64($0) }
        default: return nil
        }
    }

    static func string(_ v: Any?) -> String? {
        switch v {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }
}
