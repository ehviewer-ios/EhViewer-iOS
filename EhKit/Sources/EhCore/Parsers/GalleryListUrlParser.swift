import Foundation

/// 把站点列表 URL（首页搜索、/uploader/xxx、/tag/xxx、/{category}）还原成 ListUrlBuilder。
/// 对应 Android `client/parser/GalleryListUrlParser`
public enum GalleryListUrlParser {
    static let validHosts: Set<String> = ["exhentai.org", "e-hentai.org", "lofi.e-hentai.org"]

    static let pathNormal = "/"
    static let pathUploader = "/uploader/"
    static let pathTag = "/tag/"

    /// 宽松的 URL 拆分（与 java.net.URL 一致：path / query 保持未解码）
    private static let urlPattern = Regex2(#"^[A-Za-z][A-Za-z0-9+.\-]*://(?:[^@/?#]*@)?([^/?#:]*)(?::\d*)?([^?#]*)(?:\?([^#]*))?"#)

    public static func parse(_ urlStr: String?) -> ListUrlBuilder? {
        guard let urlStr, let m = urlPattern.firstMatch(in: urlStr), let host = m[1] else { return nil }
        guard validHosts.contains(host.lowercased()) else { return nil }

        let path = m[2] ?? ""
        let query = m[3]
        if path == pathNormal || path.isEmpty {
            var builder = ListUrlBuilder()
            builder.setQuery(query)
            return builder
        } else if path.hasPrefix(pathUploader) {
            return parseSegment(path, prefix: pathUploader, mode: .uploader)
        } else if path.hasPrefix(pathTag) {
            return parseSegment(path, prefix: pathTag, mode: .tag)
        } else if path.hasPrefix("/") {
            guard let category = Int(path.dropFirst()) else { return nil }
            var builder = ListUrlBuilder()
            builder.setQuery(query)
            builder.category = category
            return builder
        }
        return nil
    }

    // TODO 与 Java 一致：未解析页码
    private static func parseSegment(_ path: String, prefix: String, mode: ListUrlBuilder.Mode) -> ListUrlBuilder? {
        let rest = path.dropFirst(prefix.count)
        let raw = rest.firstIndex(of: "/").map { String(rest[..<$0]) } ?? String(rest)
        guard let keyword = EhUtils.urlDecode(raw), !keyword.isEmpty else { return nil }
        var builder = ListUrlBuilder()
        builder.mode = mode
        builder.keyword = keyword
        return builder
    }
}
