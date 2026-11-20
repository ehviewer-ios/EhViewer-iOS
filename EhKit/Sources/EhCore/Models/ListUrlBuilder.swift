import Foundation

/// 新版列表分页（prev/next 游标）的四个跳转链接，来自列表页的 `searchnav`。
/// 对应 Android `GalleryInfoContentHelper.firstHref/prevHref/nextHref/lastHref`
public struct ListPageHrefs: Codable, Sendable, Hashable {
    public var firstHref: String?
    public var prevHref: String?
    public var nextHref: String?
    public var lastHref: String?
    public init(firstHref: String? = nil, prevHref: String? = nil, nextHref: String? = nil, lastHref: String? = nil) {
        self.firstHref = firstHref
        self.prevHref = prevHref
        self.nextHref = nextHref
        self.lastHref = lastHref
    }
}

/// 列表翻页动作。对应 Android `ContentLayout.ContentHelper.GOTO_* / TYPE_SOMEWHERE`
public enum ListPageAction: Int, Codable, Sendable {
    case first = 0
    case prev = 1
    case next = 2
    case last = 3
    /// 跳转到指定日期/位置（jumpHrefBuild 改写后的 nextHref）
    case somewhere = 5
}

/// 新版游标分页的公共逻辑（ListUrlBuilder / FavListUrlBuilder 共用）
enum ListPageHrefSupport {
    static let patternSeekDate = Regex2(#"seek=(\d+)-(\d+)-(\d+)"#)
    static let patternJumpNode = Regex2(#"jump=(\d)[ymwd]"#)

    static func build(_ pageAction: ListPageAction, _ hrefs: ListPageHrefs) -> String? {
        switch pageAction {
        case .first: return hrefs.firstHref
        case .prev: return hrefs.prevHref
        case .next, .somewhere: return hrefs.nextHref
        case .last: return hrefs.lastHref
        }
    }

    /// 把 url 中已有的 `seek=yyyy-mm-dd` 或 `jump=Nx` 替换为 appendParam；都没有则追加 `&appendParam`
    static func jumpHrefBuild(_ urlOld: String, _ appendParam: String) -> String {
        if let m = patternSeekDate.firstMatch(in: urlOld), let g = m[0] {
            return urlOld.replacingOccurrences(of: g, with: appendParam)
        } else if let m = patternJumpNode.firstMatch(in: urlOld), let g = m[0] {
            return urlOld.replacingOccurrences(of: g, with: appendParam)
        }
        return urlOld + "&" + appendParam
    }
}

/// 有序的查询参数拼接。对应 Android `com.hippo.network.UrlBuilder`
/// （Java 端使用 HashMap，参数顺序不确定；这里按添加顺序输出，同名参数后者覆盖前者但保持原位置）
struct QueryUrlBuilder {
    private let root: String
    private var items: [(String, String)] = []

    init(_ root: String) { self.root = root }

    mutating func addQuery(_ key: String, _ value: CustomStringConvertible) {
        if let i = items.firstIndex(where: { $0.0 == key }) {
            items[i].1 = value.description
        } else {
            items.append((key, value.description))
        }
    }

    func build() -> String {
        if items.isEmpty { return root }
        return root + "?" + items.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
    }
}

/// 画廊列表 URL 构造（首页、搜索、上传者、tag、订阅、热门、以图搜图、排行榜）。
/// 对应 Android `client/data/ListUrlBuilder`；站点改为 `build(site:)` 参数传入，不读全局设置。
public struct ListUrlBuilder: Codable, Sendable, Hashable {
    /// 对应 `ListUrlBuilder.MODE_*`
    public enum Mode: Int, Codable, Sendable, Hashable {
        case normal = 0x0
        case uploader = 0x1
        case tag = 0x2
        case whatsHot = 0x3
        case imageSearch = 0x4
        case subscription = 0x5
        case filter = 0x6
        case topList = 0x7
    }

    /// 高级搜索选项位掩码。对应 Android `AdvanceSearchTable.S*`
    public enum AdvanceSearchTable {
        /// 搜索画廊名
        public static let SNAME = 0x1
        /// 搜索 tag
        public static let STAGS = 0x2
        /// 搜索描述
        public static let SDESC = 0x4
        /// 搜索种子文件名
        public static let STORR = 0x8
        /// 只显示有种子的画廊
        public static let STO = 0x10
        /// 搜索低权重 tag
        public static let SDT1 = 0x20
        /// 搜索被否决的 tag
        public static let SDT2 = 0x40
        /// 显示已删除（expunged）画廊
        public static let SH = 0x80
        /// 禁用语言过滤
        public static let SFL = 0x100
        /// 禁用上传者过滤
        public static let SFU = 0x200
        /// 禁用 tag 过滤
        public static let SFT = 0x400
    }

    public static let DEFAULT_ADVANCE = AdvanceSearchTable.SNAME | AdvanceSearchTable.STAGS
    public static let DEFAULT_MIN_RATING = 2

    public var mode: Mode = .normal
    public var pageIndex: Int = 0
    /// 分类位掩码，`EhUtils.NONE`(-1) 表示不限
    public var category: Int = EhUtils.NONE
    public var keyword: String?
    /// 排行榜模式下附加的查询串（如 "tl=15"）
    public var follow: String?
    /// -1 表示不启用高级搜索
    public var advanceSearch: Int = -1
    /// -1 表示不限最低评分
    public var minRating: Int = -1
    public var pageFrom: Int = -1
    public var pageTo: Int = -1
    public var imagePath: String?
    public var useSimilarityScan: Bool = false
    public var onlySearchCovers: Bool = false
    public var showExpunged: Bool = false

    public init() {}

    public init(mode: Mode, keyword: String? = nil, category: Int = EhUtils.NONE, pageIndex: Int = 0) {
        self.mode = mode
        self.keyword = keyword
        self.category = category
        self.pageIndex = pageIndex
    }

    /// 指向首页
    public mutating func reset() {
        mode = .normal
        pageIndex = 0
        category = EhUtils.NONE
        keyword = nil
        advanceSearch = -1
        minRating = -1
        pageFrom = -1
        pageTo = -1
        imagePath = nil
        useSimilarityScan = false
        onlySearchCovers = false
        showExpunged = false
    }

    /// 对应 `set(String q, int mode)`：只保留关键词与模式，其余条件清空
    public mutating func set(keyword q: String?, mode: Mode = .tag) {
        self.mode = mode
        category = -1
        keyword = q
        advanceSearch = -1
        minRating = -1
        pageFrom = -1
        pageTo = -1
        imagePath = nil
        useSimilarityScan = false
        onlySearchCovers = false
        showExpunged = false
    }

    public func equalKeyWord(_ keyword: String?) -> Bool {
        guard let mine = self.keyword else { return false }
        return mine == keyword
    }

    /// 从查询串（`xxx=yyy&mmm=nnn`，未解码）恢复搜索条件。对应 `setQuery`
    public mutating func setQuery(_ query: String?) {
        reset()
        guard let query, !query.isEmpty else { return }

        var category = 0
        var keyword: String?
        var enableAdvanceSearch = false
        var advanceSearch = 0
        var enableMinRating = false
        var minRating = -1
        var enablePage = false
        var pageFrom = -1
        var pageTo = -1

        for str in query.split(separator: "&", omittingEmptySubsequences: true) {
            guard let eq = str.firstIndex(of: "=") else { continue }
            let key = String(str[..<eq])
            let value = String(str[str.index(after: eq)...])
            let on = value == "on"
            switch key {
            case "f_cats":
                let cats = GallerySoup.parseInt(value, EhUtils.ALL_CATEGORY)
                category |= (~cats) & EhUtils.ALL_CATEGORY
            case "f_doujinshi": if value == "1" { category |= EhCategory.doujinshi.rawValue }
            case "f_manga": if value == "1" { category |= EhCategory.manga.rawValue }
            case "f_artistcg": if value == "1" { category |= EhCategory.artistCG.rawValue }
            case "f_gamecg": if value == "1" { category |= EhCategory.gameCG.rawValue }
            case "f_western": if value == "1" { category |= EhCategory.western.rawValue }
            case "f_non-h": if value == "1" { category |= EhCategory.nonH.rawValue }
            case "f_imageset": if value == "1" { category |= EhCategory.imageSet.rawValue }
            case "f_cosplay": if value == "1" { category |= EhCategory.cosplay.rawValue }
            case "f_asianporn": if value == "1" { category |= EhCategory.asianPorn.rawValue }
            case "f_misc": if value == "1" { category |= EhCategory.misc.rawValue }
            case "f_search":
                if let k = EhUtils.urlDecode(value) { keyword = k }
            case "advsearch": if value == "1" { enableAdvanceSearch = true }
            case "f_sname": if on { advanceSearch |= AdvanceSearchTable.SNAME }
            case "f_stags": if on { advanceSearch |= AdvanceSearchTable.STAGS }
            case "f_sdesc": if on { advanceSearch |= AdvanceSearchTable.SDESC }
            case "f_storr": if on { advanceSearch |= AdvanceSearchTable.STORR }
            case "f_sto": if on { advanceSearch |= AdvanceSearchTable.STO }
            case "f_sdt1": if on { advanceSearch |= AdvanceSearchTable.SDT1 }
            case "f_sdt2": if on { advanceSearch |= AdvanceSearchTable.SDT2 }
            case "f_sh": if on { advanceSearch |= AdvanceSearchTable.SH }
            case "f_sfl": if on { advanceSearch |= AdvanceSearchTable.SFL }
            case "f_sfu": if on { advanceSearch |= AdvanceSearchTable.SFU }
            case "f_sft": if on { advanceSearch |= AdvanceSearchTable.SFT }
            case "f_sr": if on { enableMinRating = true }
            case "f_srdd": minRating = GallerySoup.parseInt(value, -1)
            case "f_sp": if on { enablePage = true }
            case "f_spf": pageFrom = GallerySoup.parseInt(value, -1)
            case "f_spt": pageTo = GallerySoup.parseInt(value, -1)
            default: break
            }
        }

        self.category = category
        self.keyword = keyword
        if enableAdvanceSearch {
            self.advanceSearch = advanceSearch
            self.minRating = enableMinRating ? minRating : -1
            if enablePage {
                self.pageFrom = pageFrom
                self.pageTo = pageTo
            } else {
                self.pageFrom = -1
                self.pageTo = -1
            }
        } else {
            self.advanceSearch = -1
        }
    }

    /// 新版游标分页：根据翻页动作返回列表页给出的链接。对应 `build(int pageAction, GalleryInfoContentHelper)`
    public func build(pageAction: ListPageAction, hrefs: ListPageHrefs) -> String? {
        ListPageHrefSupport.build(pageAction, hrefs)
    }

    /// 跳转到指定日期/位置：替换 url 中的 `seek=` / `jump=` 参数，否则追加。对应 `jumpHrefBuild`
    public func jumpHrefBuild(_ urlOld: String, appendParam: String) -> String {
        ListPageHrefSupport.jumpHrefBuild(urlOld, appendParam)
    }

    /// 构造列表 URL。对应 `build()`
    public func build(site: EhSite) -> String {
        switch mode {
        case .normal, .subscription:
            var ub = QueryUrlBuilder(mode == .normal ? EhURL.host(site) : EhURL.watched(site))
            if category != EhUtils.NONE {
                ub.addQuery("f_cats", (~category) & EhUtils.ALL_CATEGORY)
            }
            if let keyword, !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ub.addQuery("f_search", EhUtils.urlEncode(keyword))
            }
            if pageIndex != 0 {
                ub.addQuery("page", pageIndex)
            }
            if advanceSearch != -1 {
                ub.addQuery("advsearch", "1")
                let flags: [(Int, String)] = [
                    (AdvanceSearchTable.SNAME, "f_sname"), (AdvanceSearchTable.STAGS, "f_stags"),
                    (AdvanceSearchTable.SDESC, "f_sdesc"), (AdvanceSearchTable.STORR, "f_storr"),
                    (AdvanceSearchTable.STO, "f_sto"), (AdvanceSearchTable.SDT1, "f_sdt1"),
                    (AdvanceSearchTable.SDT2, "f_sdt2"), (AdvanceSearchTable.SH, "f_sh"),
                    (AdvanceSearchTable.SFL, "f_sfl"), (AdvanceSearchTable.SFU, "f_sfu"),
                    (AdvanceSearchTable.SFT, "f_sft"),
                ]
                for (bit, key) in flags where advanceSearch & bit != 0 {
                    ub.addQuery(key, "on")
                }
                // 最低评分
                if minRating != -1 {
                    ub.addQuery("f_sr", "on")
                    ub.addQuery("f_srdd", minRating)
                }
                // 页数范围
                if pageFrom != -1 || pageTo != -1 {
                    ub.addQuery("f_sp", "on")
                    ub.addQuery("f_spf", pageFrom != -1 ? String(pageFrom) : "")
                    ub.addQuery("f_spt", pageTo != -1 ? String(pageTo) : "")
                }
            }
            return ub.build()

        case .uploader, .tag:
            var s = EhURL.host(site) + (mode == .uploader ? "uploader/" : "tag/")
            s += EhUtils.urlEncode(keyword ?? "")
            if pageIndex != 0 {
                s += "/\(pageIndex)"
            }
            return s

        case .filter:
            var s = EhURL.host(site) + "?"
            if pageIndex != 0 {
                s += "page=\(pageIndex)&"
            }
            s += "f_search=" + EhUtils.urlEncode(keyword ?? "")
            return s

        case .whatsHot:
            return EhURL.popular(site)

        case .imageSearch:
            return EhURL.imageSearch(site)

        case .topList:
            // 与 Java 一致：排行榜只有表站入口；页码超出 1..<200 时返回无效地址
            var s = EhURL.topList + "?" + (follow ?? "null")
            if pageIndex == 0 { return s }
            guard pageIndex > 0, pageIndex < 200 else { return "127.0.0.1:8888" }
            s += "&p=\(pageIndex)"
            return s
        }
    }
}
