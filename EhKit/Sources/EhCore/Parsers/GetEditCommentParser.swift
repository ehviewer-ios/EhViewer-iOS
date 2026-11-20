import Foundation
import SwiftSoup

/// 获取可编辑评论 API（method=geteditcomment）响应。对应 Android `parser/GetEditCommentParser`
public enum GetEditCommentParser {
    public struct Result: Codable, Sendable, Hashable {
        public var id: Int64
        /// 评论原文（textarea 的完整文本，保留换行）
        public var comment: String
        public init(id: Int64, comment: String) {
            self.id = id
            self.comment = comment
        }
    }

    public static func parse(_ body: String) throws -> Result {
        guard let jo = MiscJSON.object(body) else {
            throw EhError.parseFailure("Can't parse editable comment", html: body)
        }
        if jo["error"] != nil {
            throw EhError.server(MiscJSON.string(jo["error"]) ?? "")
        }
        guard let id = MiscJSON.int64(jo["comment_id"]),
              let editable = MiscJSON.string(jo["editable_comment"]) else {
            throw EhError.parseFailure("Can't parse editable comment", html: body)
        }
        guard let doc = try? SwiftSoup.parseBodyFragment(editable),
              let textarea = try? doc.select("textarea[name=commenttext_edit]").first() else {
            throw EhError.parseFailure("Can't find editable comment", html: body)
        }
        // 对应 Jsoup `wholeText()`：拼接所有后代文本节点的原始文本
        let comment = textarea.textNodes().map { $0.getWholeText() }.joined()
        return Result(id: id, comment: comment)
    }
}
