import Foundation

/// `api.php` gdata 接口（gmetadata）解析，用返回的元数据补全列表中已有的 GalleryInfo。
/// 对应 Android `client/parser/GalleryApiParser`
public enum GalleryApiParser {
    /// - Parameters:
    ///   - galleryInfoList: 就地更新，按 gid 匹配；接口里不存在于列表中的条目被忽略
    ///   - thumbResolution: 对应 `Settings.getThumbResolution()`
    public static func parse(_ body: String, galleryInfoList: inout [GalleryInfo], thumbResolution: Int = 0) throws {
        guard let jo = GalleryJSON.object(body), let ja = jo["gmetadata"] as? [Any] else {
            throw EhError.parseFailure("Can't parse gmetadata", html: body)
        }
        for item in ja {
            guard let g = item as? [String: Any] else {
                throw EhError.parseFailure("Can't parse gmetadata", html: body)
            }
            guard let gid = GalleryJSON.long(g, "gid") else {
                throw EhError.parseFailure("Can't parse gid", html: body)
            }
            guard let idx = galleryInfoList.firstIndex(where: { $0.gid == gid }) else { continue }
            // 被删除或拒绝的画廊带有 "error" 且没有 title，跳过，避免一个坏条目中断整批
            if g["error"] != nil || GalleryJSON.isNull(g, "title") { continue }

            var gi = galleryInfoList[idx]
            gi.title = ParserUtils.trim(GalleryJSON.string(g, "title"))
            gi.titleJpn = ParserUtils.trim(GalleryJSON.string(g, "title_jpn"))
            gi.category = EhCategory.from(string: GalleryJSON.string(g, "category"))
            gi.thumb = EhUtils.handleThumbUrlResolution(GalleryJSON.string(g, "thumb"), resolution: thumbResolution)
            gi.uploader = GalleryJSON.string(g, "uploader")
            gi.posted = ParserUtils.formatDate(ParserUtils.parseLong(GalleryJSON.string(g, "posted"), 0) * 1000)
            gi.rating = GallerySoup.parseFloat(GalleryJSON.string(g, "rating"), 0)
            if let tags = g["tags"] as? [Any] {
                gi.simpleTags = tags.map { ($0 as? String) ?? "\($0)" }
            } else {
                gi.simpleTags = []
            }
            gi.pages = GallerySoup.parseInt(GalleryJSON.string(g, "filecount"), 0)
            gi.generateSimpleLanguage()
            galleryInfoList[idx] = gi
        }
    }
}
