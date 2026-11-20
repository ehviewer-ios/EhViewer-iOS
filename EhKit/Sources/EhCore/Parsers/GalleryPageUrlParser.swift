import Foundation

/// 从图片页 URL（/s/{pToken}/{gid}-{page}）中提取 gid、pToken 与页序号（从 0 开始）。
/// 对应 Android `client/parser/GalleryPageUrlParser`
public enum GalleryPageUrlParser {
    public struct Result: Sendable, Hashable {
        public var gid: Int64
        public var pToken: String
        /// 从 0 开始
        public var page: Int
        public init(gid: Int64, pToken: String, page: Int) {
            self.gid = gid
            self.pToken = pToken
            self.page = page
        }
    }

    private static let urlStrictPattern = Regex2(
        #"https?://(?:exhentai\.org|e-hentai\.org|lofi\.e-hentai\.org)/s/([0-9a-f]{10})/(\d+)-(\d+)"#
    )
    private static let urlPattern = Regex2(#"([0-9a-f]{10})/(\d+)-(\d+)"#)

    public static func parse(_ url: String?, strict: Bool = true) -> Result? {
        guard let url else { return nil }
        let pattern = strict ? urlStrictPattern : urlPattern
        guard let m = pattern.firstMatch(in: url), let pToken = m[1] else { return nil }
        let gid = GallerySoup.parseLong(m[2], -1)
        let page = GallerySoup.parseInt(m[3], 0) - 1
        guard gid >= 0, page >= 0 else { return nil }
        return Result(gid: gid, pToken: pToken, page: page)
    }
}
