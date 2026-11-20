import Foundation

/// 站点 uconfig 配置（最终写入 cookie）。对应 Android `EhConfig`。
/// Java 版带脏标记缓存，这里 `uconfig` 为计算属性，值类型无需缓存。
public struct EhConfig: Codable, Sendable, Hashable {

    // MARK: Cookie 键

    /// uconfig 的 cookie 名
    public static let keyUconfig = "uconfig"
    /// lofi 分辨率 cookie 名
    public static let keyLofiResolution = "xres"
    /// 内容警告 cookie 名
    public static let keyContentWarning = "nw"

    // MARK: uconfig 内部键
    static let keyLoadFromHAH = "uh"
    static let keyImageSize = "xr"
    static let keyScaleWidth = "rx"
    static let keyScaleHeight = "ry"
    static let keyGalleryTitle = "tl"
    static let keyArchiverDownload = "ar"
    static let keyLayoutMode = "dm"
    static let keyPopular = "prn"
    static let keyDefaultCategories = "cats"
    static let keyFavoritesSort = "fs"
    static let keyExcludedNamespaces = "xns"
    static let keyExcludedLanguages = "xl"
    static let keyResultCount = "rc"
    static let keyMouseOver = "lt"
    static let keyPreviewSize = "ts"
    static let keyPreviewRow = "tr"
    static let keyCommentsSort = "cs"
    static let keyCommentsVotes = "sc"
    static let keyTagsSort = "to"
    static let keyShowGalleryIndex = "pn"
    static let keyHahClientIpPort = "hp"
    static let keyHahClientPasskey = "hk"
    static let keyEnableTagFlagging = "tf"
    static let keyAlwaysOriginal = "oi"
    static let keyMultiPage = "qb"
    static let keyMultiPageStyle = "ms"
    static let keyMultiPageThumb = "mt"

    // MARK: 取值常量

    public static let loadFromHAHYes = "y"
    public static let loadFromHAHNo = "n"

    public static let imageSizeAuto = "a"
    public static let imageSize780x = "780"
    /// 2024-09-11 站点已下线 980x
    @available(*, deprecated, message: "980x resample retired by site")
    public static let imageSize980x = "980"
    public static let imageSize1280x = "1280"
    public static let imageSize1600x = "1600"
    public static let imageSize2400x = "2400"

    static let galleryTitleDefault = "r"
    static let galleryTitleJapanese = "j"

    public static let archiverDownloadMAMS = "0"
    public static let archiverDownloadAAMS = "1"
    public static let archiverDownloadMAAS = "2"
    public static let archiverDownloadAAAS = "3"

    public static let layoutModeList = "l"
    public static let layoutModeThumb = "t"

    static let popularYes = "y"
    static let popularNo = "n"

    // 分类位掩码见 `EhCategory`

    public static let namespacesReclass = 0x1
    public static let namespacesLanguage = 0x2
    public static let namespacesParody = 0x4
    public static let namespacesCharacter = 0x8
    public static let namespacesGroup = 0x10
    public static let namespacesArtist = 0x20
    public static let namespacesMale = 0x40
    public static let namespacesFemale = 0x80

    /// 排除语言代码（`xl` 用 "x" 连接，如 "1x1024x2048"）。顺序：original / translated / rewrite
    public static let japaneseOriginal = "0", japaneseTranslated = "1024", japaneseRewrite = "2048"
    public static let englishOriginal = "1", englishTranslated = "1025", englishRewrite = "2049"
    public static let chineseOriginal = "10", chineseTranslated = "1034", chineseRewrite = "2058"
    public static let dutchOriginal = "20", dutchTranslated = "1044", dutchRewrite = "2068"
    public static let frenchOriginal = "30", frenchTranslated = "1054", frenchRewrite = "2078"
    public static let germanOriginal = "40", germanTranslated = "1064", germanRewrite = "2088"
    public static let hungarianOriginal = "50", hungarianTranslated = "1074", hungarianRewrite = "2098"
    public static let italianOriginal = "60", italianTranslated = "1084", italianRewrite = "2108"
    public static let koreanOriginal = "70", koreanTranslated = "1094", koreanRewrite = "2118"
    public static let polishOriginal = "80", polishTranslated = "1104", polishRewrite = "2128"
    public static let portugueseOriginal = "90", portugueseTranslated = "1114", portugueseRewrite = "2138"
    public static let russianOriginal = "100", russianTranslated = "1124", russianRewrite = "2148"
    public static let spanishOriginal = "110", spanishTranslated = "1134", spanishRewrite = "2158"
    public static let thaiOriginal = "120", thaiTranslated = "1144", thaiRewrite = "2168"
    public static let vietnameseOriginal = "130", vietnameseTranslated = "1154", vietnameseRewrite = "2178"
    public static let naOriginal = "254", naTranslated = "1278", naRewrite = "2302"
    public static let otherOriginal = "255", otherTranslated = "1279", otherRewrite = "2303"

    static let favoritesSortGalleryUpdateTime = "p"
    static let favoritesSortFavoritedTime = "f"

    public static let resultCount25 = "0"
    public static let resultCount50 = "1"
    public static let resultCount100 = "2"
    public static let resultCount200 = "3"

    public static let mouseOverYes = "m"
    public static let mouseOverNo = "p"

    public static let previewSizeNormal = "m"
    public static let previewSizeLarge = "l"

    public static let previewRow4 = "2"
    public static let previewRow10 = "5"
    public static let previewRow20 = "10"
    public static let previewRow40 = "20"

    public static let commentsSortOldestFirst = "a"
    public static let commentsSortRecentFirst = "d"
    public static let commentsSortHighestScoreFirst = "s"

    public static let commentsVotesPop = "0"
    public static let commentsVotesAlways = "1"

    public static let tagsSortAlphabetical = "a"
    public static let tagsSortPower = "p"

    public static let showGalleryIndexYes = "1"
    public static let showGalleryIndexNo = "0"

    public static let enableTagFlaggingYes = "y"
    public static let enableTagFlaggingNo = "n"

    public static let alwaysOriginalYes = "y"
    public static let alwaysOriginalNo = "n"

    public static let multiPageYes = "y"
    public static let multiPageNo = "n"

    public static let multiPageStyleN = "n"
    public static let multiPageStyleC = "c"
    public static let multiPageStyleY = "y"

    public static let multiPageThumbShow = "n"
    public static let multiPageThumbHide = "y"

    public static let lofiResolution460x = "1"
    public static let lofiResolution780x = "2"
    public static let lofiResolution980x = "3"

    public static let contentWarningShow = "0"
    public static let contentWarningNotShow = "1"

    public static let updatePath = "Ehviewer/Update/"
    public static let archiverPath = "Ehviewer/Archiver/"
    public static let torrentPath = "Ehviewer/Torrent/"

    /// 收藏夹排序：收藏时间 / 发布时间
    public static let orderByFavTime = "f"
    public static let orderByPubTime = "p"

    // MARK: 字段

    public var loadFromHAH = EhConfig.loadFromHAHYes
    public var imageSize = EhConfig.imageSizeAuto
    /// 0 表示不限制
    public var scaleWidth = 0
    public var scaleHeight = 0
    public var galleryTitle = EhConfig.galleryTitleDefault
    public var archiverDownload = EhConfig.archiverDownloadMAMS
    public var layoutMode = EhConfig.layoutModeList
    public var popular = EhConfig.popularYes
    /// 首页默认分类位掩码，0 = 无
    public var defaultCategories = 0
    public var favoritesSort = EhConfig.favoritesSortFavoritedTime
    /// 默认标签搜索排除的命名空间位掩码
    public var excludedNamespaces = 0
    /// 排除语言，"x" 连接
    public var excludedLanguages = ""
    public var resultCount = EhConfig.resultCount25
    public var mouseOver = EhConfig.mouseOverYes
    public var previewSize = EhConfig.previewSizeLarge
    public var previewRow = EhConfig.previewRow4
    public var commentSort = EhConfig.commentsSortOldestFirst
    public var commentVotes = EhConfig.commentsVotesPop
    public var tagSort = EhConfig.tagsSortAlphabetical
    public var showGalleryIndex = EhConfig.showGalleryIndexYes
    public var hahClientIp = ""
    public var hahClientPort = -1
    public var hahClientPasskey = ""
    public var enableTagFlagging = EhConfig.enableTagFlaggingNo
    public var alwaysOriginal = EhConfig.alwaysOriginalNo
    public var multiPage = EhConfig.multiPageNo
    public var multiPageStyle = EhConfig.multiPageStyleN
    public var multiPageThumb = EhConfig.multiPageThumbShow
    public var lofiResolution = EhConfig.lofiResolution980x
    public var contentWarning = EhConfig.contentWarningNotShow

    public init() {}

    /// cookie `uconfig` 的值。对应 `uconfig()` / `updateUconfig()`
    public var uconfig: String {
        let ipPort = (Self.isValidInet4Address(hahClientIp) && Self.isValidInetPort(hahClientPort))
            ? hahClientIp + "%3A" + String(hahClientPort) : ""
        let pairs: [(String, String)] = [
            (Self.keyLoadFromHAH, loadFromHAH),
            (Self.keyImageSize, imageSize),
            (Self.keyScaleWidth, String(scaleWidth)),
            (Self.keyScaleHeight, String(scaleHeight)),
            (Self.keyGalleryTitle, galleryTitle),
            (Self.keyArchiverDownload, archiverDownload),
            (Self.keyLayoutMode, layoutMode),
            (Self.keyPopular, popular),
            (Self.keyDefaultCategories, String(defaultCategories)),
            (Self.keyFavoritesSort, favoritesSort),
            (Self.keyExcludedNamespaces, String(excludedNamespaces)),
            (Self.keyExcludedLanguages, excludedLanguages),
            (Self.keyResultCount, resultCount),
            (Self.keyMouseOver, mouseOver),
            (Self.keyPreviewSize, previewSize),
            (Self.keyPreviewRow, previewRow),
            (Self.keyCommentsSort, commentSort),
            (Self.keyCommentsVotes, commentVotes),
            (Self.keyTagsSort, tagSort),
            (Self.keyShowGalleryIndex, showGalleryIndex),
            (Self.keyHahClientIpPort, ipPort),
            (Self.keyHahClientPasskey, hahClientPasskey),
            (Self.keyEnableTagFlagging, enableTagFlagging),
            (Self.keyAlwaysOriginal, alwaysOriginal),
            (Self.keyMultiPage, multiPage),
            (Self.keyMultiPageStyle, multiPageStyle),
            (Self.keyMultiPageThumb, multiPageThumb),
        ]
        return pairs.map { $0.0 + "_" + $0.1 }.joined(separator: "-")
    }

    /// e-hentai 域固定附加的内容警告 cookie（`nw=1`）。对应 `EhCookieStore.sTipsCookie`；
    /// 请求 e-hentai.org 时应移除已存的 `nw` 与 `uconfig` cookie 并加上此项（见 `EhCookieStore.loadForRequest`）
    public static let tipsCookie = (name: keyContentWarning, value: contentWarningNotShow)

    // MARK: InetValidator

    /// 对应 `com.hippo.network.InetValidator.isValidInet4Address`
    public static func isValidInet4Address(_ address: String?) -> Bool {
        guard let address,
              let m = ipv4Regex.firstMatch(in: address) else { return false }
        for i in 1...4 {
            guard let seg = m[i], !seg.isEmpty, let v = Int(seg) else { return false }
            if v > 255 { return false }
            if seg.count > 1 && seg.hasPrefix("0") { return false }
        }
        return true
    }

    /// 对应 `InetValidator.isValidInetPort`
    public static func isValidInetPort(_ port: Int) -> Bool {
        port >= 0 && port <= 65535
    }

    private static let ipv4Regex = Regex2(#"^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$"#)
}
