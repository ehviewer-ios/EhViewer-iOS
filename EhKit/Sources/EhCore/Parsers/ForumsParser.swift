import Foundation
import SwiftSoup

/// 论坛首页：取出当前用户个人资料页链接。对应 Android `parser/ForumsParser`
public enum ForumsParser {
    /// 返回 `#userlinks` 第一个链接的 href（个人资料页，下一步交给 `ProfileParser.parse`）
    public static func parse(_ body: String) throws -> String {
        guard let d = try? SwiftSoup.parse(body, EhURL.forums),
              let userlinks = try? d.getElementById("userlinks"),
              let child = userlinks.miscChild(0)?.miscChild(0)?.miscChild(0),
              let href = try? child.attr("href") else {
            throw EhError.parseFailure("Parse forums error", html: body)
        }
        return href
    }
}
