import Foundation

/// 图片页（/s/{pToken}/{gid}-{page}）HTML 解析：图片地址、跳过 H@H 的 nl key、原图地址、showkey。
/// 对应 Android `client/parser/GalleryPageParser`
public enum GalleryPageParser {
    public struct Result: Sendable, Hashable {
        public var imageUrl: String?
        public var skipHathKey: String?
        public var originImageUrl: String?
        public var showKey: String?
        public init(imageUrl: String? = nil, skipHathKey: String? = nil, originImageUrl: String? = nil, showKey: String? = nil) {
            self.imageUrl = imageUrl
            self.skipHathKey = skipHathKey
            self.originImageUrl = originImageUrl
            self.showKey = showKey
        }
    }

    static let patternImageUrl = Regex2(#"<img[^>]*src="([^"]+)" style"#)
    static let patternSkipHathKey = Regex2(#"onclick="return nl\('([^\)]+)'\)"#)
    static let patternOriginImageUrl = Regex2(#"<a href="([^"]+)fullimg([^"]+)">"#)
    // TODO 与 Java 一致：showkey 长度未确定
    static let patternShowKey = Regex2(#"var showkey="([0-9a-z]+)";"#)

    public static func parse(_ body: String) throws -> Result {
        var result = Result()
        if let m = patternImageUrl.firstMatch(in: body) {
            result.imageUrl = ParserUtils.unescapeXml(GallerySoup.trim(m[1]))
        }
        if let m = patternSkipHathKey.firstMatch(in: body) {
            result.skipHathKey = ParserUtils.unescapeXml(GallerySoup.trim(m[1]))
        }
        if let m = patternOriginImageUrl.firstMatch(in: body) {
            result.originImageUrl = ParserUtils.unescapeXml(m[1] ?? "") + "fullimg" + ParserUtils.unescapeXml(m[2] ?? "")
        }
        if let m = patternShowKey.firstMatch(in: body) {
            result.showKey = m[1]
        }
        guard result.imageUrl?.isEmpty == false, result.showKey?.isEmpty == false else {
            throw EhError.parseFailure("Parse image url and show error", html: body)
        }
        return result
    }
}
