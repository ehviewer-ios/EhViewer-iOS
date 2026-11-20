import Foundation
import SwiftSoup

/// My Tags 页（/mytags）。对应 Android `parser/MyTagLitParser`（保留原类名拼写）
public enum MyTagLitParser {
    static let patternError = Regex2("<div class=\"d\">\n<p>([^<]+)</p>")

    /// 站点错误页抛 `EhError.server`；结构异常时与 Java 一致静默返回已解析部分
    public static func parse(_ body: String) throws -> UserTagList {
        var list = UserTagList()
        if let m = patternError.firstMatch(in: body), let msg = m[1] {
            throw EhError.server(msg)
        }
        guard let document = try? SwiftSoup.parse(body),
              let element = try? document.getElementById("usertags_outer") else {
            return list
        }
        // 第 0 个子元素是"新增标签"行，跳过
        for tag in element.children().array().dropFirst() {
            // Java 中任一条目解析异常会中断整个循环（外层 catch），这里保持一致
            guard let userTag = parseUserTag(tag) else { break }
            list.userTags.append(userTag)
        }
        return list
    }

    private static func parseUserTag(_ tag: Element) -> UserTag? {
        let userTagId = tag.id()
        // "usertag_3437".substring(7) == "_3437"
        guard userTagId.count >= 7 else { return nil }
        let id = String(userTagId.dropFirst(7))
        var userTag = UserTag(userTagId: userTagId)

        guard let preview = try? tag.getElementById("tagpreview" + id),
              let tagName = try? preview.attr("title") else { return nil }
        userTag.tagName = tagName

        if let watchInput = try? tag.getElementById("tagwatch" + id) {
            userTag.watched = (try? watchInput.attr("checked")) == "checked"
        }
        if let hideInput = try? tag.getElementById("taghide" + id) {
            userTag.hidden = (try? hideInput.attr("checked")) == "checked"
        }

        guard let colorInput = try? tag.getElementById("tagcolor" + id) else { return nil }
        userTag.color = try? colorInput.attr("placeholder")

        guard let weightInput = try? tag.getElementById("tagweight" + id),
              let weightString = try? weightInput.attr("value"),
              let weight = Int(weightString) else { return nil } // Integer.parseInt 失败即异常
        userTag.tagWeight = weight
        return userTag
    }
}
