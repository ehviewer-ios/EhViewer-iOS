import Foundation

/// `EhAPI` 每次请求时读取的设置快照。对应 EhEngine 中散落的 `Settings.getXxx()` / `EhUrl.getXxx()`（站点相关）。
/// 由调用方（App 层从 `EhSettings` 映射）通过闭包提供，EhNetwork 不依赖 EhStorage。
public struct EhAPIEnvironment: Sendable, Hashable {
    /// `Settings.getGallerySite()`：决定 api.php / Referer / Origin / 收藏 / 以图搜图等地址
    public var site: EhSite
    /// `Settings.getThumbResolution()`（0 原样 / 1 = 250 / 2 = 300）
    public var thumbResolution: Int
    /// `Settings.getFixThumbUrl()`
    public var fixThumbUrl: Bool
    /// `Settings.getShowGalleryPages()`：列表无页数时通过 gdata 补全
    public var showGalleryPages: Bool
    /// `Settings.isLogin()`：getWatchedList / addTag / deleteWatchedTag 未登录时直接返回 nil
    public var isLogin: Bool

    public init(site: EhSite = .e, thumbResolution: Int = 0, fixThumbUrl: Bool = false,
                showGalleryPages: Bool = false, isLogin: Bool = false) {
        self.site = site
        self.thumbResolution = thumbResolution
        self.fixThumbUrl = fixThumbUrl
        self.showGalleryPages = showGalleryPages
        self.isLogin = isLogin
    }
}

/// 列表过滤器。对应 `EhEngine.sEhFilter`（`EhFilter`）中被 `fillGalleryList` 用到的方法。
/// 方法签名与 EhStorage `EhFilter` 完全一致，App 层可直接 `extension EhFilter: @retroactive EhGalleryFiltering {}`。
/// 返回 true 表示保留。
public protocol EhGalleryFiltering: Sendable {
    var needTags: Bool { get }
    func filterTitle(_ info: GalleryInfo) -> Bool
    func filterUploader(_ info: GalleryInfo) -> Bool
    func filterTag(_ info: GalleryInfo) -> Bool
    func filterTagNamespace(_ info: GalleryInfo) -> Bool
}

/// 闭包形式的过滤器（测试或简单场景用）
public struct ClosureGalleryFilter: EhGalleryFiltering {
    private let _needTags: @Sendable () -> Bool
    private let _title: @Sendable (GalleryInfo) -> Bool
    private let _uploader: @Sendable (GalleryInfo) -> Bool
    private let _tag: @Sendable (GalleryInfo) -> Bool
    private let _tagNamespace: @Sendable (GalleryInfo) -> Bool

    public init(needTags: @escaping @Sendable () -> Bool = { false },
                title: @escaping @Sendable (GalleryInfo) -> Bool = { _ in true },
                uploader: @escaping @Sendable (GalleryInfo) -> Bool = { _ in true },
                tag: @escaping @Sendable (GalleryInfo) -> Bool = { _ in true },
                tagNamespace: @escaping @Sendable (GalleryInfo) -> Bool = { _ in true }) {
        _needTags = needTags
        _title = title
        _uploader = uploader
        _tag = tag
        _tagNamespace = tagNamespace
    }

    public var needTags: Bool { _needTags() }
    public func filterTitle(_ info: GalleryInfo) -> Bool { _title(info) }
    public func filterUploader(_ info: GalleryInfo) -> Bool { _uploader(info) }
    public func filterTag(_ info: GalleryInfo) -> Bool { _tag(info) }
    public func filterTagNamespace(_ info: GalleryInfo) -> Bool { _tagNamespace(info) }
}

/// 注入的外部依赖（数据库查询、UI 回调）。全部可选，缺省即"不过滤 / 不处理"
public struct EhAPIHooks: Sendable {
    /// `EhEngine.sEhFilter`
    public var galleryFilter: (any EhGalleryFiltering)?
    /// `EhDB.containLocalFavorites(gid)`：列表页无收藏色时判断本地收藏
    public var isLocalFavorite: (@Sendable (Int64) -> Bool)?
    /// `EhDB.inBlackList(user)`：评论黑名单
    public var isBlacklisted: (@Sendable (String?) -> Bool)?
    /// `EhApplication.showEventPane(html)`：详情页 / 首页中出现 `#eventpane`（"新的一天"等）时回调其 HTML。
    /// 是否展示（`Settings.getShowEhEvents()`）由回调方决定
    public var onEventPane: (@Sendable (String) -> Void)?
    /// `AppConfig.saveParseErrorBody`：解析失败时回调（`Settings.getSaveParseErrorBody()` 由回调方判断）
    public var onParseError: (@Sendable (_ error: EhError, _ body: String) -> Void)?

    public init(galleryFilter: (any EhGalleryFiltering)? = nil,
                isLocalFavorite: (@Sendable (Int64) -> Bool)? = nil,
                isBlacklisted: (@Sendable (String?) -> Bool)? = nil,
                onEventPane: (@Sendable (String) -> Void)? = nil,
                onParseError: (@Sendable (_ error: EhError, _ body: String) -> Void)? = nil) {
        self.galleryFilter = galleryFilter
        self.isLocalFavorite = isLocalFavorite
        self.isBlacklisted = isBlacklisted
        self.onEventPane = onEventPane
        self.onParseError = onParseError
    }
}
