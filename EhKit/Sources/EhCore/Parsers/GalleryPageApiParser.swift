import Foundation

/// `api.php` showpage 接口（JSON）解析。对应 Android `client/parser/GalleryPageApiParser`
public enum GalleryPageApiParser {
    public struct Result: Sendable, Hashable {
        public var imageUrl: String?
        /// "Generate a static forum image link" 里的静态图地址
        public var otherImageUrl: String?
        public var skipHathKey: String?
        public var originImageUrl: String?
        public init(imageUrl: String? = nil, otherImageUrl: String? = nil, skipHathKey: String? = nil, originImageUrl: String? = nil) {
            self.imageUrl = imageUrl
            self.otherImageUrl = otherImageUrl
            self.skipHathKey = skipHathKey
            self.originImageUrl = originImageUrl
        }
    }

    static let patternOriginImageUrlNew = Regex2(##"<a href="#" onclick="prompt\('Copy the URL below.', '([^"]+)'\)"##)

    public static func parse(_ body: String) throws -> Result {
        guard let jo = GalleryJSON.object(body) else {
            throw EhError.parseFailure("Can't parse json", html: body)
        }
        if jo["error"] != nil {
            throw EhError.parseFailure(GalleryJSON.string(jo, "error") ?? "error", html: body)
        }
        guard let i3 = GalleryJSON.string(jo, "i3"), let i6 = GalleryJSON.string(jo, "i6") else {
            throw EhError.parseFailure("Can't parse json", html: body)
        }

        var result = Result()
        if let m = GalleryPageParser.patternImageUrl.firstMatch(in: i3) {
            result.imageUrl = ParserUtils.unescapeXml(GallerySoup.trim(m[1]))
        }
        if let m = GalleryPageParser.patternSkipHathKey.firstMatch(in: i6) {
            result.skipHathKey = ParserUtils.unescapeXml(GallerySoup.trim(m[1]))
        }
        if let m = patternOriginImageUrlNew.firstMatch(in: i6) {
            result.otherImageUrl = ParserUtils.unescapeXml(m[1] ?? "")
        }
        // 新版接口原图链接在 i7，旧版在 i6
        let originSource = GalleryJSON.isNull(jo, "i7") ? i6 : (GalleryJSON.string(jo, "i7") ?? "")
        if let m = GalleryPageParser.patternOriginImageUrl.firstMatch(in: originSource) {
            result.originImageUrl = ParserUtils.unescapeXml(m[1] ?? "") + "fullimg" + ParserUtils.unescapeXml(m[2] ?? "")
        }

        guard result.imageUrl?.isEmpty == false else {
            throw EhError.parseFailure("Parse image url and skip hath key error", html: body)
        }
        return result
    }
}
