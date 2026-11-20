import Foundation
import SwiftSoup

// 画廊列表/详情解析用的 SwiftSoup 安全封装（对应 Android `JsoupUtils` 及 jsoup 的部分行为）。
// SwiftSoup 的 `child(_:)` 越界会崩溃，而 Java 端依赖抛出 IndexOutOfBounds 再 catch，
// 这里统一改成返回可选值。前缀 `gl` 用于避免与其他解析任务的扩展重名。
extension Element {
    /// 安全版 `child(i)`
    func glChild(_ index: Int) -> Element? {
        let cs = children()
        return index >= 0 && index < cs.count ? cs.get(index) : nil
    }

    /// 对应 `JsoupUtils.getElementByClass`（包含自身）
    func glFirstByClass(_ className: String) -> Element? {
        (try? getElementsByClass(className))?.first()
    }

    /// 对应 `JsoupUtils.getElementsByClass`：空则返回 nil
    func glAllByClass(_ className: String) -> [Element]? {
        guard let es = try? getElementsByClass(className), !es.isEmpty() else { return nil }
        return es.array()
    }

    /// 对应 `JsoupUtils.getElementByTag`
    func glFirstByTag(_ tag: String) -> Element? {
        (try? getElementsByTag(tag))?.first()
    }

    func glById(_ id: String) -> Element? {
        (try? getElementById(id)) ?? nil
    }

    func glSelectFirst(_ css: String) -> Element? {
        (try? select(css))?.first()
    }

    var glText: String { (try? text()) ?? "" }

    var glHtml: String { (try? html()) ?? "" }

    func glAttr(_ key: String) -> String { (try? attr(key)) ?? "" }
}

enum GallerySoup {
    static func parse(_ html: String) -> Document? {
        try? SwiftSoup.parse(html)
    }

    /// 对应 Java `String.trim()` / `StringUtils.trim`（不做 XML 反转义）
    static func trim(_ s: String?) -> String {
        (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 对应 `NumberUtils.parseIntSafely`
    static func parseInt(_ s: String?, _ def: Int) -> Int {
        guard let s, let v = Int(s) else { return def }
        return v
    }

    static func parseLong(_ s: String?, _ def: Int64) -> Int64 {
        guard let s, let v = Int64(s) else { return def }
        return v
    }

    static func parseFloat(_ s: String?, _ def: Float) -> Float {
        guard let s, let v = Float(s.trimmingCharacters(in: .whitespaces)) else { return def }
        return v
    }
}

/// org.json 风格的宽松取值（对应 `JSONObject.getString/getLong/isNull`），基于 JSONSerialization
enum GalleryJSON {
    static func object(_ body: String) -> [String: Any]? {
        guard let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return obj as? [String: Any]
    }

    /// 对应 `getString`：字符串原样返回，数字/布尔转字符串；缺失或 null 返回 nil
    static func string(_ o: [String: Any], _ key: String) -> String? {
        switch o[key] {
        case nil, is NSNull: return nil
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        case let v?: return "\(v)"
        }
    }

    /// 对应 `getLong`：数字或可解析的字符串
    static func long(_ o: [String: Any], _ key: String) -> Int64? {
        switch o[key] {
        case let n as NSNumber: return n.int64Value
        case let s as String: return Int64(s) ?? Double(s).map { Int64($0) }
        default: return nil
        }
    }

    /// 对应 `isNull`：缺失或为 null
    static func isNull(_ o: [String: Any], _ key: String) -> Bool {
        switch o[key] {
        case nil, is NSNull: return true
        default: return false
        }
    }
}
