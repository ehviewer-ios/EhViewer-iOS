import Foundation

/// 从画廊详情 URL（/g/{gid}/{token} 或 /mpv/{gid}/{token}）中提取 gid 与 token。
/// 对应 Android `client/parser/GalleryDetailUrlParser`
public enum GalleryDetailUrlParser {
    public struct Result: Sendable, Hashable {
        public var gid: Int64
        public var token: String
        public init(gid: Int64, token: String) {
            self.gid = gid
            self.token = token
        }
    }

    private static let urlStrictPattern = Regex2(
        #"https?://(?:exhentai\.org|e-hentai\.org|lofi\.e-hentai\.org)/(?:g|mpv)/(\d+)/([0-9a-f]{10})"#
    )
    private static let urlPattern = Regex2(#"(\d+)/([0-9a-f]{10})(?:[^0-9a-f]|$)"#)

    /// strict = true 时要求完整的站点 URL；false 时只要包含 `{gid}/{token}` 即可
    public static func parse(_ url: String?, strict: Bool = true) -> Result? {
        guard let url else { return nil }
        let pattern = strict ? urlStrictPattern : urlPattern
        guard let m = pattern.firstMatch(in: url) else { return nil }
        let gid = GallerySoup.parseLong(m[1], -1)
        guard gid >= 0, let token = m[2] else { return nil }
        return Result(gid: gid, token: token)
    }
}
