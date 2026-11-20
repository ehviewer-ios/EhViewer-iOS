import Foundation
import SwiftSoup

/// 发表 / 编辑评论（POST 画廊详情页）后的响应解析。
/// 对应 Android `EhEngine.commentGallery` 中内联的解析逻辑：
/// `#chd + p` 存在时为站点错误提示（如评论过短、发言过快），否则解析刷新后的评论列表
public enum CommentGalleryParser {
    /// - Parameter isBlacklisted: 对应 `EhDB.inBlackList(user)`
    public static func parse(_ body: String, isBlacklisted: ((String?) -> Bool)? = nil) throws -> GalleryCommentList {
        guard let document = GallerySoup.parse(body) else {
            throw EhError.parseFailure("Can't parse comment response", html: body)
        }
        if let p = (try? document.select("#chd + p"))?.first() {
            throw EhError.server(p.glText)
        }
        return GalleryDetailParser.parseComments(document, isBlacklisted: isBlacklisted)
    }
}
