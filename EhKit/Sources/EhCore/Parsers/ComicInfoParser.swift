import Foundation

/// 从 ComicInfo.xml 的 `<Web>` 地址解析画廊 gid 和 token。对应 Android `parser/ComicInfoParser`
public enum ComicInfoParser {
    public static let filename = "ComicInfo.xml"
    static let maxBytes = 256 * 1024
    static let web = Regex2("<Web>\\s*([^<]+?)\\s*</Web>", options: [.caseInsensitive])

    /// 第一个 `<Web>` 标签中的地址（已 trim）；没有返回 nil
    public static func parseWebUrl(_ xml: String?) -> String? {
        guard let xml, !xml.isEmpty,
              let m = web.firstMatch(in: xml), let url = m[1] else { return nil }
        return url.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 取出画廊地址并按严格模式解析；没有该标签或地址不符合画廊详情格式时返回 nil
    public static func parse(_ xml: String?) -> GalleryDetailUrlParser.Result? {
        guard let url = parseWebUrl(xml) else { return nil }
        return GalleryDetailUrlParser.parse(url, strict: true)
    }

    /// 按 UTF-8 读取文件内容再解析。超过 256KB 返回 nil。对应 `parse(InputStream)`
    public static func parse(data: Data?) -> GalleryDetailUrlParser.Result? {
        guard let data, data.count <= maxBytes else { return nil }
        return parse(String(decoding: data, as: UTF8.self))
    }
}
