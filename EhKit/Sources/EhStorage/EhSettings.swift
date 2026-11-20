import Foundation

/// 应用设置。对应 Android `Settings.java`。
///
/// - 底层 `UserDefaults`，构造时可注入 suite（测试用临时 suite）。
/// - key 字符串与 Android SharedPreferences 完全一致；Android 用 `putIntToStr` 存成字符串的项，这里同样存字符串，
///   以便与 Android 偏好文件互相导入（见 `importAndroidPreferences`）。
/// - 读取时类型不符返回默认值（对应 Android 捕获 ClassCastException）。
/// - 省略了 Android 专属项：见 `EhSettings.omittedAndroidKeys`。
public final class EhSettings: @unchecked Sendable {
    public let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public convenience init?(suiteName: String) {
        guard let d = UserDefaults(suiteName: suiteName) else { return nil }
        self.init(defaults: d)
    }

    // MARK: - Keys

    /// 所有 key（与 Android 一致）
    public enum Key {
        public static let versionCode = "version_code"
        public static let displayName = "display_name"
        public static let avatar = "avatar"
        public static let showWarning = "show_warning"
        public static let removeImageFiles = "include_pic"
        public static let needSignIn = "need_sign_in"
        public static let selectSite = "select_site"
        public static let quickSearchTip = "quick_search_tip"
        // Eh
        public static let theme = "theme"
        public static let themeAutoSwitch = "theme_auto_switch"
        public static let gallerySite = "gallery_site"
        public static let launchPage = "launch_page"
        public static let listMode = "list_mode"
        public static let detailSize = "detail_size"
        public static let thumbSize = "thumb_size"
        public static let thumbResolution = "thumb_resolution"
        public static let fixThumbUrl = "fix_thumb_url"
        public static let showJpnTitle = "show_jpn_title"
        public static let showGalleryPages = "show_gallery_pages"
        public static let showTagTranslations = "show_tag_translations"
        public static let defaultCategories = "default_categories"
        public static let excludedTagNamespaces = "excluded_tag_namespaces"
        public static let excludedLanguages = "excluded_languages"
        public static let cellularNetworkWarning = "cellular_network_warning"
        public static let showGalleryComment = "show_gallery_comment"
        public static let showGalleryRating = "show_gallery_rating"
        public static let showEhEvents = "show_eh_events"
        public static let showEhLimits = "show_eh_limits"
        public static let showReadProgress = "show_read_progress"
        public static let historyInfoSize = "history_info_size"
        // Read
        public static let screenRotation = "screen_rotation"
        public static let readingRefreshRate = "reading_refresh_rate"
        public static let readingDirection = "reading_direction"
        public static let pageScaling = "page_scaling"
        public static let startPosition = "start_position"
        public static let startTransferTime = "start_transfer_time"
        public static let keepScreenOn = "keep_screen_on"
        public static let showClock = "gallery_show_clock"
        public static let showProgress = "gallery_show_progress"
        public static let showBattery = "gallery_show_battery"
        public static let showPageInterval = "gallery_show_page_interval"
        public static let volumePage = "volume_page"
        public static let reverseVolumePage = "reverse_volume_page"
        public static let readingFullscreen = "reading_fullscreen"
        public static let customScreenLightness = "custom_screen_lightness"
        public static let screenLightness = "screen_lightness"
        // Privacy
        public static let secSecurity = "enable_secure"
        public static let security = "security"
        public static let enableFingerprint = "enable_fingerprint"
        // Download
        public static let syncDownloadWhileReading = "sync_download_while_reading"
        public static let recentDownloadLabel = "recent_download_label"
        public static let hasDefaultDownloadLabel = "has_default_download_label"
        public static let defaultDownloadLabel = "default_download_label"
        public static let multiThreadDownload = "download_thread"
        public static let preloadImage = "preload_image"
        public static let imageResolution = "image_size"
        public static let downloadOriginImage = "download_origin_image"
        public static let downloadDelay = "download_delay"
        public static let downloadTimeout = "download_timeout"
        public static let downloadOrderAsc = "download_order_asc"
        public static let downloadListPagination = "download_list_pagination"
        public static let dragDownloadGallery = "drag_download_gallery"
        // Favorites
        public static func favCat(_ i: Int) -> String { "fav_cat_\(i)" }
        public static func favCount(_ i: Int) -> String { "fav_count_\(i)" }
        public static let favLocal = "fav_local"
        public static let favCloud = "fav_cloud"
        public static let recentFavCat = "recent_fav_cat"
        public static let defaultFavSlot = "default_favorite_2"
        // Analytics
        public static let askAnalytics = "ask_analytics"
        public static let enableAnalytics = "enable_analytics"
        public static let userID = "user_id"
        // Advanced
        public static let saveParseErrorBody = "save_parse_error_body"
        public static let saveCrashLog = "save_crash_log"
        public static let readCacheSize = "read_cache_size"
        public static let builtInHosts = "built_in_hosts"
        public static let builtExHosts = "built_ex_hosts"
        public static let appLanguage = "app_language"
        public static let proxyType = "proxy_type"
        public static let proxyIp = "proxy_ip"
        public static let proxyPort = "proxy_port"
        public static let doH = "dns_over_https"
        public static let domainFronting = "domain_fronting"
        // Guide
        public static let guideQuickSearch = "guide_quick_search"
        public static let guideCollections = "guide_collections"
        public static let guideDownloadThumb = "guide_download_thumb"
        public static let guideDownloadLabels = "guide_download_labels"
        public static let guideGallery = "guide_gallery"
        // Misc
        public static let clipboardTextHashCode = "clipboard_text_hash_code"
        public static let isLogin = "is_login"
        public static let backgroundImagePath = "background_image_path"
        public static let avatarImagePath = "avatar_image_path"
    }

    /// 未移植的 Android 专属 key（在 iOS 无意义）
    public static let omittedAndroidKeys: [String] = [
        "apply_nav_bar_theme_color", // Android 导航栏着色
        "media_scan", // MediaStore 扫描 / .nomedia
        "image_scheme", "image_authority", "image_path", "image_query", "image_fragment", // SAF 下载目录 URI
        "beta_update_channel", "skip_update_version", "close_auto_updates", "last_update_time", // APK 自更新
        "data_map_next_id", "global_stuff_next_id", // 进程内对象 id 计数
    ]

    // MARK: - 枚举

    /// 主题。对应 `THEME_LIGHT / THEME_DARK / THEME_BLACK`
    public enum Theme: Int, CaseIterable, Sendable { case light = 0, dark = 1, black = 2 }

    /// 启动页。对应 `getLaunchPageGalleryListSceneAction`
    public enum LaunchPage: Int, CaseIterable, Sendable { case homepage = 0, subscription = 1, whatsHot = 2 }

    /// 列表模式。对应 `list_mode_entry_values`
    public enum ListMode: Int, CaseIterable, Sendable { case detail = 0, thumb = 1 }

    /// 详情列表宽度。0 = long，1 = short
    public enum DetailSize: Int, CaseIterable, Sendable { case long = 0, short = 1 }

    /// 缩略图网格尺寸
    public enum ThumbSize: Int, CaseIterable, Sendable { case large = 0, middle = 1, small = 2 }

    /// 缩略图分辨率：auto / 250x / 300x
    public enum ThumbResolution: Int, CaseIterable, Sendable { case auto = 0, x250 = 1, x300 = 2 }

    /// 屏幕方向
    public enum ScreenRotation: Int, CaseIterable, Sendable { case `default` = 0, portrait = 1, landscape = 2, sensor = 3 }

    /// 阅读刷新率。对应 `util/ReadingRefreshRate`
    public enum ReadingRefreshRate: Int, CaseIterable, Sendable {
        case systemDefault = 0, displayMax = -1, hz60 = 60, hz90 = 90, hz120 = 120
        public static func sanitize(_ v: Int) -> ReadingRefreshRate { ReadingRefreshRate(rawValue: v) ?? .systemDefault }
    }

    /// 阅读方向。对应 `GalleryView.LAYOUT_*`
    public enum ReadingDirection: Int, CaseIterable, Sendable {
        case leftToRight = 0, rightToLeft = 1, topToBottom = 2
        /// 对应 `GalleryView.sanitizeLayoutMode`
        public static func sanitize(_ v: Int) -> ReadingDirection { ReadingDirection(rawValue: v) ?? .leftToRight }
    }

    /// 缩放模式。对应 `GalleryView.SCALE_*`
    public enum PageScaling: Int, CaseIterable, Sendable {
        case origin = 0, fitWidth = 1, fitHeight = 2, fit = 3, fixed = 4
        /// 对应 `GalleryView.sanitizeScaleMode`
        public static func sanitize(_ v: Int) -> PageScaling { PageScaling(rawValue: v) ?? .fit }
    }

    /// 起始位置。对应 `GalleryView.START_POSITION_*`
    public enum StartPosition: Int, CaseIterable, Sendable {
        case topLeft = 0, topRight = 1, bottomLeft = 2, bottomRight = 3, center = 4
        /// 对应 `GalleryView.sanitizeStartPosition`
        public static func sanitize(_ v: Int) -> StartPosition { StartPosition(rawValue: v) ?? .topLeft }
    }

    /// 图片分辨率（uconfig xr）。对应 `EhConfig.IMAGE_SIZE_*`
    public enum ImageResolution: String, CaseIterable, Sendable {
        case auto = "a", x780 = "780", x980 = "980", x1280 = "1280", x1600 = "1600", x2400 = "2400"
    }

    /// 代理类型。对应 `EhProxySelector.TYPE_*`
    public enum ProxyType: Int, CaseIterable, Sendable { case direct = 0, system = 1, http = 2, socks = 3 }

    // MARK: - 选项列表（对应 res/values/arrays.xml 的 entryValues）

    public static let historyInfoSizeOptions = [100, 500, 1000, 5000, 10000, 20000, -1]
    public static let multiThreadDownloadOptions = [1, 3, 5, 7]
    public static let preloadImageOptions = [3, 5, 7, 11, 13, 17]
    public static let downloadTimeoutOptions = [0, 10, 30, 50, 100, 200, 300]
    public static let readCacheSizeOptions = [40, 80, 160, 320, 640]
    public static let appLanguageOptions = ["system", "de", "en", "es", "fr", "ja", "ko", "th", "zh-CN", "zh-HK", "zh-TW"]

    // MARK: - 默认值常量

    public static let defaultHistoryInfoSize = 100
    public static let defaultReadCacheSize = 160
    /// -1 本地，0..9 云端，其他为未设置
    public static let invalidDefaultFavSlot = -2
    /// `FavListUrlBuilder.FAV_CAT_ALL`
    public static let favCatAll = -1
    static let userIDLength = 32

    // MARK: - 原始读写（对应 getBoolean / getInt / getIntFromStr …）

    public func bool(_ key: String, _ def: Bool) -> Bool {
        guard let v = defaults.object(forKey: key) else { return def }
        if let b = v as? Bool { return b }
        return def
    }

    public func setBool(_ key: String, _ v: Bool) { defaults.set(v, forKey: key) }

    public func int(_ key: String, _ def: Int) -> Int {
        guard let v = defaults.object(forKey: key) else { return def }
        if v is String { return def } // 字符串 → ClassCastException
        if let n = v as? Int { return n }
        if let n = v as? NSNumber { return n.intValue }
        return def
    }

    public func setInt(_ key: String, _ v: Int) { defaults.set(v, forKey: key) }

    public func long(_ key: String, _ def: Int64) -> Int64 {
        guard let v = defaults.object(forKey: key) else { return def }
        if v is String { return def }
        if let n = v as? Int64 { return n }
        if let n = v as? NSNumber { return n.int64Value }
        return def
    }

    public func setLong(_ key: String, _ v: Int64) { defaults.set(v, forKey: key) }

    public func string(_ key: String, _ def: String?) -> String? {
        guard let v = defaults.object(forKey: key) else { return def }
        return v as? String ?? def
    }

    /// nil 删除该 key（Android putString(null) 等价于 remove）
    public func setString(_ key: String, _ v: String?) {
        if let v { defaults.set(v, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    /// 对应 `getIntFromStr`：值以字符串保存，解析失败返回默认值（也兼容数字类型）
    public func intFromStr(_ key: String, _ def: Int) -> Int {
        guard let v = defaults.object(forKey: key) else { return def }
        if let s = v as? String { return Int32(s).map(Int.init) ?? def }
        if let n = v as? NSNumber { return n.intValue }
        return def
    }

    /// 对应 `putIntToStr`
    public func setIntToStr(_ key: String, _ v: Int) { defaults.set(String(v), forKey: key) }

    public func contains(_ key: String) -> Bool { defaults.object(forKey: key) != nil }

    public func remove(_ key: String) { defaults.removeObject(forKey: key) }

    // MARK: - 初始化修正

    /// 对应 `fixDefaultValue`：中国大陆地区首次启动时显式打开内置 hosts 与域前置
    public func fixDefaultValue(regionCode: String?) {
        guard regionCode == "CN" else { return }
        if !contains(Key.builtInHosts) {
            builtInHosts = true
            builtExHosts = true
        }
        if !contains(Key.domainFronting) {
            domainFronting = true
        }
    }

    /// 对应 `initialize` 中的暗色模式处理：系统为暗色且开启自动切换时设为暗色主题
    public func applySystemDarkMode(_ isDark: Bool) {
        if isDark && themeAutoSwitch { theme = .dark }
    }

    // MARK: - 通用

    public var versionCode: Int {
        get { int(Key.versionCode, 0) }
        set { setInt(Key.versionCode, newValue) }
    }

    public var displayName: String? {
        get { string(Key.displayName, nil) }
        set { setString(Key.displayName, newValue) }
    }

    public var avatar: String? {
        get { string(Key.avatar, nil) }
        set { setString(Key.avatar, newValue) }
    }

    public var showWarning: Bool {
        get { bool(Key.showWarning, true) }
        set { setBool(Key.showWarning, newValue) }
    }

    /// 删除下载时同时删除图片文件
    public var removeImageFiles: Bool {
        get { bool(Key.removeImageFiles, true) }
        set { setBool(Key.removeImageFiles, newValue) }
    }

    public var needSignIn: Bool {
        get { bool(Key.needSignIn, true) }
        set { setBool(Key.needSignIn, newValue) }
    }

    public var selectSite: Bool {
        get { bool(Key.selectSite, true) }
        set { setBool(Key.selectSite, newValue) }
    }

    public var quickSearchTip: Bool {
        get { bool(Key.quickSearchTip, true) }
        set { setBool(Key.quickSearchTip, newValue) }
    }

    // MARK: - Eh

    public var theme: Theme {
        get { Theme(rawValue: intFromStr(Key.theme, Theme.light.rawValue)) ?? .light }
        set { setIntToStr(Key.theme, newValue.rawValue) }
    }

    public var themeAutoSwitch: Bool {
        get { bool(Key.themeAutoSwitch, false) }
        set { setBool(Key.themeAutoSwitch, newValue) }
    }

    public var gallerySite: EhSite {
        get { EhSite(rawValue: intFromStr(Key.gallerySite, 0)) ?? .e }
        set { setIntToStr(Key.gallerySite, newValue.rawValue) }
    }

    public var launchPage: LaunchPage {
        get { LaunchPage(rawValue: intFromStr(Key.launchPage, 0)) ?? .homepage }
        set { setIntToStr(Key.launchPage, newValue.rawValue) }
    }

    public var listMode: ListMode {
        get { ListMode(rawValue: intFromStr(Key.listMode, 0)) ?? .detail }
        set { setIntToStr(Key.listMode, newValue.rawValue) }
    }

    public var detailSize: DetailSize {
        get { DetailSize(rawValue: intFromStr(Key.detailSize, 0)) ?? .long }
        set { setIntToStr(Key.detailSize, newValue.rawValue) }
    }

    public var thumbSize: ThumbSize {
        get { ThumbSize(rawValue: intFromStr(Key.thumbSize, 1)) ?? .middle }
        set { setIntToStr(Key.thumbSize, newValue.rawValue) }
    }

    public var thumbResolution: ThumbResolution {
        get { ThumbResolution(rawValue: intFromStr(Key.thumbResolution, 0)) ?? .auto }
        set { setIntToStr(Key.thumbResolution, newValue.rawValue) }
    }

    public var fixThumbUrl: Bool {
        get { bool(Key.fixThumbUrl, false) }
        set { setBool(Key.fixThumbUrl, newValue) }
    }

    public var showJpnTitle: Bool {
        get { bool(Key.showJpnTitle, false) }
        set { setBool(Key.showJpnTitle, newValue) }
    }

    public var showGalleryPages: Bool {
        get { bool(Key.showGalleryPages, false) }
        set { setBool(Key.showGalleryPages, newValue) }
    }

    public var showTagTranslations: Bool {
        get { bool(Key.showTagTranslations, true) }
        set { setBool(Key.showTagTranslations, newValue) }
    }

    /// 默认分类位掩码，默认 `EhConfig.ALL_CATEGORY`
    public var defaultCategories: Int {
        get { int(Key.defaultCategories, EhCategory.all.rawValue) }
        set { setInt(Key.defaultCategories, newValue) }
    }

    /// 排除的 tag 命名空间位掩码（`EhConfig.NAMESPACES_*`）
    public var excludedTagNamespaces: Int {
        get { int(Key.excludedTagNamespaces, 0) }
        set { setInt(Key.excludedTagNamespaces, newValue) }
    }

    /// 排除的语言（uconfig xl，形如 "0x1x1024"）
    public var excludedLanguages: String? {
        get { string(Key.excludedLanguages, nil) }
        set { setString(Key.excludedLanguages, newValue) }
    }

    public var cellularNetworkWarning: Bool {
        get { bool(Key.cellularNetworkWarning, false) }
        set { setBool(Key.cellularNetworkWarning, newValue) }
    }

    public var showGalleryComment: Bool {
        get { bool(Key.showGalleryComment, true) }
        set { setBool(Key.showGalleryComment, newValue) }
    }

    public var showGalleryRating: Bool {
        get { bool(Key.showGalleryRating, true) }
        set { setBool(Key.showGalleryRating, newValue) }
    }

    /// 读取时与 `isLogin` 取与（与 Android 一致），写入只写原值
    public var showEhEvents: Bool {
        get { bool(Key.showEhEvents, true) && isLogin }
        set { setBool(Key.showEhEvents, newValue) }
    }

    /// 读取时与 `isLogin` 取与
    public var showEhLimits: Bool {
        get { bool(Key.showEhLimits, true) && isLogin }
        set { setBool(Key.showEhLimits, newValue) }
    }

    public var showReadProgress: Bool {
        get { bool(Key.showReadProgress, true) }
        set { setBool(Key.showReadProgress, newValue) }
    }

    /// 历史记录上限。小于 100（含 -1）时重置为 100 并写回（与 Android 一致）
    public var historyInfoSize: Int {
        get {
            let size = intFromStr(Key.historyInfoSize, Self.defaultHistoryInfoSize)
            if size < Self.defaultHistoryInfoSize {
                setIntToStr(Key.historyInfoSize, Self.defaultHistoryInfoSize)
                return Self.defaultHistoryInfoSize
            }
            return size
        }
        set { setIntToStr(Key.historyInfoSize, newValue) }
    }

    // MARK: - Read

    public var screenRotation: ScreenRotation {
        get { ScreenRotation(rawValue: intFromStr(Key.screenRotation, 0)) ?? .default }
        set { setIntToStr(Key.screenRotation, newValue.rawValue) }
    }

    public var readingRefreshRate: ReadingRefreshRate {
        get { .sanitize(intFromStr(Key.readingRefreshRate, 0)) }
        set { setIntToStr(Key.readingRefreshRate, newValue.rawValue) }
    }

    /// 默认从右到左
    public var readingDirection: ReadingDirection {
        get { .sanitize(intFromStr(Key.readingDirection, ReadingDirection.rightToLeft.rawValue)) }
        set { setIntToStr(Key.readingDirection, newValue.rawValue) }
    }

    public var pageScaling: PageScaling {
        get { .sanitize(intFromStr(Key.pageScaling, PageScaling.fit.rawValue)) }
        set { setIntToStr(Key.pageScaling, newValue.rawValue) }
    }

    public var startPosition: StartPosition {
        get { .sanitize(intFromStr(Key.startPosition, StartPosition.topRight.rawValue)) }
        set { setIntToStr(Key.startPosition, newValue.rawValue) }
    }

    /// 翻页动画时长档位（SeekBar，默认 2）
    public var startTransferTime: Int {
        get { int(Key.startTransferTime, 2) }
        set { setInt(Key.startTransferTime, newValue) }
    }

    public var keepScreenOn: Bool {
        get { bool(Key.keepScreenOn, false) }
        set { setBool(Key.keepScreenOn, newValue) }
    }

    public var showClock: Bool {
        get { bool(Key.showClock, true) }
        set { setBool(Key.showClock, newValue) }
    }

    public var showProgress: Bool {
        get { bool(Key.showProgress, true) }
        set { setBool(Key.showProgress, newValue) }
    }

    public var showBattery: Bool {
        get { bool(Key.showBattery, true) }
        set { setBool(Key.showBattery, newValue) }
    }

    public var showPageInterval: Bool {
        get { bool(Key.showPageInterval, true) }
        set { setBool(Key.showPageInterval, newValue) }
    }

    public var volumePage: Bool {
        get { bool(Key.volumePage, false) }
        set { setBool(Key.volumePage, newValue) }
    }

    public var reverseVolumePage: Bool {
        get { bool(Key.reverseVolumePage, false) }
        set { setBool(Key.reverseVolumePage, newValue) }
    }

    public var readingFullscreen: Bool {
        get { bool(Key.readingFullscreen, true) }
        set { setBool(Key.readingFullscreen, newValue) }
    }

    public var customScreenLightness: Bool {
        get { bool(Key.customScreenLightness, false) }
        set { setBool(Key.customScreenLightness, newValue) }
    }

    /// 0..100，默认 50
    public var screenLightness: Int {
        get { int(Key.screenLightness, 50) }
        set { setInt(Key.screenLightness, newValue) }
    }

    // MARK: - Privacy and Security

    /// 防截屏 / 后台模糊（Android FLAG_SECURE）。
    /// 注：Android `putEnabledSecurity` 误写到 reading_fullscreen，这里写入正确的 key。
    public var enabledSecurity: Bool {
        get { bool(Key.secSecurity, false) }
        set { setBool(Key.secSecurity, newValue) }
    }

    /// 手势密码（Android 存 pattern 字符串）
    public var security: String {
        get { string(Key.security, "") ?? "" }
        set { setString(Key.security, newValue) }
    }

    /// 生物识别解锁（iOS 对应 Face ID / Touch ID）
    public var enableFingerprint: Bool {
        get { bool(Key.enableFingerprint, false) }
        set { setBool(Key.enableFingerprint, newValue) }
    }

    // MARK: - Download

    public var syncDownloadWhileReading: Bool {
        get { bool(Key.syncDownloadWhileReading, false) }
        set { setBool(Key.syncDownloadWhileReading, newValue) }
    }

    public var recentDownloadLabel: String? {
        get { string(Key.recentDownloadLabel, nil) }
        set { setString(Key.recentDownloadLabel, newValue) }
    }

    public var hasDefaultDownloadLabel: Bool {
        get { bool(Key.hasDefaultDownloadLabel, false) }
        set { setBool(Key.hasDefaultDownloadLabel, newValue) }
    }

    public var defaultDownloadLabel: String? {
        get { string(Key.defaultDownloadLabel, nil) }
        set { setString(Key.defaultDownloadLabel, newValue) }
    }

    /// 下载线程数，默认 3
    public var multiThreadDownload: Int {
        get { intFromStr(Key.multiThreadDownload, 3) }
        set { setIntToStr(Key.multiThreadDownload, newValue) }
    }

    /// 阅读预加载页数，默认 5
    public var preloadImage: Int {
        get { intFromStr(Key.preloadImage, 5) }
        set { setIntToStr(Key.preloadImage, newValue) }
    }

    /// 图片分辨率。读到 "980" 时迁移为 "780" 并写回（与 Android 一致）
    public var imageResolution: ImageResolution {
        get {
            let raw = string(Key.imageResolution, ImageResolution.auto.rawValue) ?? ImageResolution.auto.rawValue
            if raw == ImageResolution.x980.rawValue {
                setString(Key.imageResolution, ImageResolution.x780.rawValue)
                return .x780
            }
            return ImageResolution(rawValue: raw) ?? .auto
        }
        set { setString(Key.imageResolution, newValue.rawValue) }
    }

    public var downloadOriginImage: Bool {
        get { bool(Key.downloadOriginImage, false) }
        set { setBool(Key.downloadOriginImage, newValue) }
    }

    /// 下载间隔（毫秒），默认 0
    public var downloadDelay: Int {
        get { intFromStr(Key.downloadDelay, 0) }
        set { setIntToStr(Key.downloadDelay, newValue) }
    }

    /// 下载超时（秒），0 = 默认；负数读作 0
    public var downloadTimeout: Int {
        get { max(intFromStr(Key.downloadTimeout, 0), 0) }
        set { setIntToStr(Key.downloadTimeout, newValue) }
    }

    /// 下载列表按时间升序
    public var downloadOrderAsc: Bool {
        get { bool(Key.downloadOrderAsc, true) }
        set { setBool(Key.downloadOrderAsc, newValue) }
    }

    public var downloadPagination: Bool {
        get { bool(Key.downloadListPagination, true) }
        set { setBool(Key.downloadListPagination, newValue) }
    }

    public var dragDownloadGallery: Bool {
        get { bool(Key.dragDownloadGallery, false) }
        set { setBool(Key.dragDownloadGallery, newValue) }
    }

    // MARK: - Favorites

    /// 10 个云收藏夹名称，默认 "Favorites N"
    public var favCat: [String] {
        get { (0 ..< 10).map { string(Key.favCat($0), "Favorites \($0)") ?? "Favorites \($0)" } }
        set {
            precondition(newValue.count == 10, "favCat 必须为 10 项")
            for (i, v) in newValue.enumerated() { setString(Key.favCat(i), v) }
        }
    }

    /// 10 个云收藏夹数量
    public var favCount: [Int] {
        get { (0 ..< 10).map { int(Key.favCount($0), 0) } }
        set {
            precondition(newValue.count == 10, "favCount 必须为 10 项")
            for (i, v) in newValue.enumerated() { setInt(Key.favCount(i), v) }
        }
    }

    public var favLocalCount: Int {
        get { int(Key.favLocal, 0) }
        set { setInt(Key.favLocal, newValue) }
    }

    public var favCloudCount: Int {
        get { int(Key.favCloud, 0) }
        set { setInt(Key.favCloud, newValue) }
    }

    /// 最近打开的收藏夹，默认 -1（全部）
    public var recentFavCat: Int {
        get { int(Key.recentFavCat, Self.favCatAll) }
        set { setInt(Key.recentFavCat, newValue) }
    }

    /// 默认收藏位置：-1 本地，0..9 云端，-2 未设置
    public var defaultFavSlot: Int {
        get { int(Key.defaultFavSlot, Self.invalidDefaultFavSlot) }
        set { setInt(Key.defaultFavSlot, newValue) }
    }

    // MARK: - Analytics

    public var askAnalytics: Bool {
        get { bool(Key.askAnalytics, true) }
        set { setBool(Key.askAnalytics, newValue) }
    }

    public var enableAnalytics: Bool {
        get { bool(Key.enableAnalytics, false) }
        set { setBool(Key.enableAnalytics, newValue) }
    }

    /// 对应 `getUserID`：32 位 [0-9a-z]，无效时生成并保存（Android 另会写外部存储文件，iOS 省略）
    public var userID: String {
        if let id = string(Key.userID, nil), Self.isValidUserID(id) { return id }
        let id = Self.generateUserID()
        setString(Key.userID, id)
        return id
    }

    static func isValidUserID(_ id: String) -> Bool {
        id.utf8.count == userIDLength && id.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x7A) }
    }

    static func generateUserID() -> String {
        let chars = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        return String((0 ..< userIDLength).map { _ in chars.randomElement()! })
    }

    // MARK: - Advanced

    /// Android 默认值为 BuildConfig BETA；iOS 默认 false
    public var saveParseErrorBody: Bool {
        get { bool(Key.saveParseErrorBody, false) }
        set { setBool(Key.saveParseErrorBody, newValue) }
    }

    public var saveCrashLog: Bool {
        get { bool(Key.saveCrashLog, false) }
        set { setBool(Key.saveCrashLog, newValue) }
    }

    /// 阅读图片缓存大小（MB），默认 160。使用时按 Android 夹到 40...640
    public var readCacheSize: Int {
        get { intFromStr(Key.readCacheSize, Self.defaultReadCacheSize) }
        set { setIntToStr(Key.readCacheSize, newValue) }
    }

    public var builtInHosts: Bool {
        get { bool(Key.builtInHosts, true) }
        set { setBool(Key.builtInHosts, newValue) }
    }

    public var builtExHosts: Bool {
        get { bool(Key.builtExHosts, true) }
        set { setBool(Key.builtExHosts, newValue) }
    }

    /// "system" 或语言代码
    public var appLanguage: String {
        get { string(Key.appLanguage, "system") ?? "system" }
        set { setString(Key.appLanguage, newValue) }
    }

    public var proxyType: ProxyType {
        get { ProxyType(rawValue: int(Key.proxyType, ProxyType.system.rawValue)) ?? .system }
        set { setInt(Key.proxyType, newValue.rawValue) }
    }

    public var proxyIp: String? {
        get { string(Key.proxyIp, nil) }
        set { setString(Key.proxyIp, newValue) }
    }

    public var proxyPort: Int {
        get { int(Key.proxyPort, -1) }
        set { setInt(Key.proxyPort, newValue) }
    }

    public var doH: Bool {
        get { bool(Key.doH, false) }
        set { setBool(Key.doH, newValue) }
    }

    /// 域前置（Android `getDF`），默认 true
    public var domainFronting: Bool {
        get { bool(Key.domainFronting, true) }
        set { setBool(Key.domainFronting, newValue) }
    }

    // MARK: - Guide

    public var guideQuickSearch: Bool {
        get { bool(Key.guideQuickSearch, true) }
        set { setBool(Key.guideQuickSearch, newValue) }
    }

    public var guideCollections: Bool {
        get { bool(Key.guideCollections, true) }
        set { setBool(Key.guideCollections, newValue) }
    }

    public var guideDownloadThumb: Bool {
        get { bool(Key.guideDownloadThumb, true) }
        set { setBool(Key.guideDownloadThumb, newValue) }
    }

    public var guideDownloadLabels: Bool {
        get { bool(Key.guideDownloadLabels, true) }
        set { setBool(Key.guideDownloadLabels, newValue) }
    }

    public var guideGallery: Bool {
        get { bool(Key.guideGallery, true) }
        set { setBool(Key.guideGallery, newValue) }
    }

    // MARK: - Misc

    public var clipboardTextHashCode: Int {
        get { int(Key.clipboardTextHashCode, 0) }
        set { setInt(Key.clipboardTextHashCode, newValue) }
    }

    public var isLogin: Bool {
        get { bool(Key.isLogin, false) }
        set { setBool(Key.isLogin, newValue) }
    }

    /// 用户自定义背景图路径（对应 `USER_BACKGROUND_IMAGE`）
    public var backgroundImagePath: String? {
        get { string(Key.backgroundImagePath, nil).flatMap { $0.isEmpty ? nil : $0 } }
        set { setString(Key.backgroundImagePath, newValue) }
    }

    /// 用户自定义头像路径（对应 `USER_AVATAR_IMAGE`）
    public var avatarImagePath: String? {
        get { string(Key.avatarImagePath, nil).flatMap { $0.isEmpty ? nil : $0 } }
        set { setString(Key.avatarImagePath, newValue) }
    }

    /// 对应 `getUserImageFile`：路径非空且文件存在时返回
    public func userImageFile(_ key: String, fileManager: FileManager = .default) -> URL? {
        guard let path = string(key, ""), !path.isEmpty, fileManager.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }
}
