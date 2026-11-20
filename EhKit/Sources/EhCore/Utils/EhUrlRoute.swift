import Foundation

/// 链接路由判定。对应 Android `client/EhUrlOpener.parseUrl` + `UrlOpener.openUrl` 的分支选择（不含 UI 跳转）。
///
/// 判定顺序与 Java 一致：画廊列表 URL → 画廊详情 URL → 图片页 URL；都不匹配则为外部链接。
/// - `galleryList`：对应 `GalleryListScene` + `ACTION_LIST_URL_BUILDER`
/// - `galleryDetail`：对应 `GalleryDetailScene` + `ACTION_GID_TOKEN`
/// - `galleryPage`：对应 `ProgressScene` + `ACTION_GALLERY_TOKEN`（之后用 `EhAPI.getGalleryToken` 换取画廊 token）
/// - `external`：交给系统浏览器（`Intent.ACTION_VIEW`）
public enum EhUrlRoute: Sendable, Hashable {
    case galleryList(ListUrlBuilder)
    case galleryDetail(gid: Int64, token: String)
    /// page 从 0 开始
    case galleryPage(gid: Int64, pToken: String, page: Int)
    case external(String)

    /// 对应 `EhUrlOpener.parseUrl`：只识别站内链接，无法识别返回 nil
    public static func parseEhUrl(_ url: String?) -> EhUrlRoute? {
        guard let url, !url.isEmpty else { return nil }
        if let builder = GalleryListUrlParser.parse(url) {
            return .galleryList(builder)
        }
        if let r = GalleryDetailUrlParser.parse(url) {
            return .galleryDetail(gid: r.gid, token: r.token)
        }
        if let r = GalleryPageUrlParser.parse(url) {
            return .galleryPage(gid: r.gid, pToken: r.pToken, page: r.page)
        }
        return nil
    }

    /// 对应 `UrlOpener.openUrl(context, url, ehUrl)`：空链接返回 nil；
    /// `ehUrl` 为 true 时先尝试站内路由，失败（或 `ehUrl` 为 false）返回 `.external`
    public static func route(_ url: String?, ehUrl: Bool = true) -> EhUrlRoute? {
        guard let url, !url.isEmpty else { return nil }
        if ehUrl, let r = parseEhUrl(url) {
            return r
        }
        return .external(url)
    }

    /// 是否为站内路由
    public var isInternal: Bool {
        if case .external = self { return false }
        return true
    }
}
