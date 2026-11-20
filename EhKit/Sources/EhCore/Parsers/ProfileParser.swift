import Foundation
import SwiftSoup

/// 论坛个人资料页（显示名与头像）。对应 Android `parser/ProfileParser`
public enum ProfileParser {
    public struct Result: Codable, Sendable, Hashable {
        public var displayName: String?
        public var avatar: String?
        public init(displayName: String? = nil, avatar: String? = nil) {
            self.displayName = displayName
            self.avatar = avatar
        }
    }

    /// 对应 `parse(String)`：`#profilename` 的首个子元素为显示名，其后第二个兄弟元素内为头像
    public static func parse(_ body: String) throws -> Result {
        do {
            let d = try SwiftSoup.parse(body)
            guard let profilename = try d.getElementById("profilename"),
                  let nameEl = profilename.miscChild(0) else {
                throw EhError.parseFailure("Parse forums error", html: body)
            }
            var result = Result()
            result.displayName = try nameEl.text()
            result.avatar = avatar(after: profilename)
            return result
        } catch let e as EhError {
            throw e
        } catch {
            throw EhError.parseFailure("Parse forums error", html: body)
        }
    }

    /// 对应 `parseNew(String)`：页面被 JSON 转义过的情况（Android 端未被调用，保留以便对照）
    public static func parseNew(_ body: String) throws -> Result {
        let htmlString = body
            .replacingOccurrences(of: "\\u003C", with: "<")
            .replacingOccurrences(of: "\\n", with: "")
            .replacingOccurrences(of: "\\\"", with: "")
            .replacingOccurrences(of: "\\t", with: "")
        var result = Result()
        if htmlString.contains("ERR_CONNECTION_REFUSED") {
            return result
        }
        do {
            let document = try SwiftSoup.parse(htmlString)
            guard let userlinks = try document.getElementById("userlinks"),
                  let nameEl = userlinks.miscChild(0)?.miscChild(0)?.miscChild(0) else {
                throw EhError.parseFailure("Parse forums error", html: body)
            }
            result.displayName = try nameEl.text()
            result.avatar = avatar(after: userlinks)
            return result
        } catch let e as EhError {
            throw e
        } catch {
            throw EhError.parseFailure("Parse forums error", html: body)
        }
    }

    /// 头像：元素之后第二个兄弟元素的首个子元素的 src；相对地址补全为论坛地址；失败返回 nil（No avatar）
    private static func avatar(after element: Element) -> String? {
        guard let s1 = try? element.nextElementSibling(),
              let s2 = try? s1.nextElementSibling(),
              let img = s2.miscChild(0),
              let src = try? img.attr("src"), !src.isEmpty else { return nil }
        return src.hasPrefix("http") ? src : EhURL.forums + src
    }
}
