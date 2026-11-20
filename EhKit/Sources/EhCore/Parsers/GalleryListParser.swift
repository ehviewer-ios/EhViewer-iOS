import Foundation
import SwiftSoup

/// 画廊列表页解析（首页 / 搜索 / 上传者 / tag / 订阅 / 收藏夹等），
/// 支持 Minimal、Minimal+、Compact、Extended、Thumbnail 五种显示模式，以及旧版页码（ptt）与新版 prev/next 游标（searchnav）两种分页。
/// 对应 Android `client/parser/GalleryListParser`
public enum GalleryListParser {
    public struct Result: Sendable, Hashable {
        /// 旧版分页的总页数；新版游标分页为 -1；"No hits found" 为 0；无法解析时为 1 或 Int.max（与 Java 一致）
        public var pages: Int = 0
        /// 旧版分页的下一页页码（来自 `page=N`）；新版游标分页为 -1
        public var nextPage: Int = 0
        /// 搜索结果数（如 "1,000+"、"12,345"），仅新版页面
        public var resultCount: String?
        public var firstHref: String?
        public var prevHref: String?
        public var nextHref: String?
        public var lastHref: String?
        public var customErrorString: String?
        /// 订阅页没有设置任何 watched tag
        public var noWatchedTags: Bool = false
        public var galleryInfoList: [GalleryInfo] = []

        public init() {}

        /// 新版分页游标，供 `ListUrlBuilder.build(pageAction:hrefs:)` 使用
        public var hrefs: ListPageHrefs {
            ListPageHrefs(firstHref: firstHref, prevHref: prevHref, nextHref: nextHref, lastHref: lastHref)
        }
    }

    static let patternRating = Regex2(#"\d+px"#)
    static let patternThumbSize = Regex2(#"height:(\d+)px;width:(\d+)px"#)
    static let patternFavoriteSlot = Regex2(#"background-color:rgba\((\d+),(\d+),(\d+),"#)
    static let patternPages = Regex2(#"(\d+) page"#)
    static let patternNextPage = Regex2(#"page=(\d+)"#)
    static let patternNextExPage = Regex2(#"next=(\d+)"#)
    static let patternResultCountPage = Regex2(#"Found .* results"#)

    /// 收藏夹 0-9 对应的颜色
    static let favoriteSlotRGB: [(String, String, String)] = [
        ("0", "0", "0"),
        ("240", "0", "0"),
        ("240", "160", "0"),
        ("208", "208", "0"),
        ("0", "128", "0"),
        ("144", "240", "64"),
        ("64", "176", "240"),
        ("0", "0", "240"),
        ("80", "0", "128"),
        ("224", "128", "224"),
    ]

    /// - Parameters:
    ///   - thumbResolution: 对应 `Settings.getThumbResolution()`（0 原样 / 1 = 250 / 2 = 300）
    ///   - isLocalFavorite: 对应 `EhDB.containLocalFavorites(gid)`；页面上没有收藏颜色时用它判断是否为本地收藏（favoriteSlot = -1）
    public static func parse(
        _ body: String,
        thumbResolution: Int = 0,
        isLocalFavorite: ((Int64) -> Bool)? = nil
    ) throws -> Result {
        guard let d = GallerySoup.parse(body) else {
            throw EhError.parseFailure("Can't parse gallery list", html: body)
        }
        return try parse(document: d, body: body, thumbResolution: thumbResolution, isLocalFavorite: isLocalFavorite)
    }

    public static func parse(
        document d: Document,
        body: String,
        thumbResolution: Int = 0,
        isLocalFavorite: ((Int64) -> Bool)? = nil
    ) throws -> Result {
        var result = Result()

        if !parsePagination(d, into: &result) {
            // 对应 Java 的 catch 分支
            result.noWatchedTags = body.contains("<p>You do not have any watched tags")
            if body.contains("No hits found</p>") {
                result.pages = 0
                result.galleryInfoList = []
                return result
            } else if d.glAllByClass("ptt") == nil {
                result.pages = 1
            } else {
                result.pages = Int.max
            }
        }

        guard let itg = d.glFirstByClass("itg") else {
            throw EhError.parseFailure("Can't parse gallery list", html: body)
        }
        let rows: [Element]
        if itg.tagName().caseInsensitiveCompare("table") == .orderedSame {
            guard let tbody = itg.glChild(0) else {
                throw EhError.parseFailure("Can't parse gallery list", html: body)
            }
            rows = tbody.children().array()
        } else {
            rows = itg.children().array()
        }
        // 表头等无标题的行会被 parseGalleryInfo 过滤掉
        let list = rows.compactMap {
            parseGalleryInfo($0, thumbResolution: thumbResolution, isLocalFavorite: isLocalFavorite)
        }
        if list.isEmpty {
            // Compact 模式下空列表会有一行提示文字（如 "No unfiltered results in this page range..."），视为正常的空页
            let pageMessage = (try? d.select(".itg.gltc"))?.first()?
                .glChild(0)?.glChild(1)?.glChild(0)?.glText
            if pageMessage?.isEmpty ?? true {
                throw EhError.parseFailure("No gallery", html: body)
            }
        }
        result.galleryInfoList = list
        // Java 端此处还会触发 GalleryListTagsSyncTask（tag 翻译同步），属于存储层职责，不在解析器中处理
        return result
    }

    /// 解析分页信息；返回 false 表示进入 Java 的异常分支
    private static func parsePagination(_ d: Document, into result: inout Result) -> Bool {
        if let ptt = d.glFirstByClass("ptt") {
            // 旧版页码分页
            guard let es = ptt.glChild(0)?.glChild(0)?.children().array(), es.count >= 2,
                  let pages = Int(GallerySoup.trim(es[es.count - 2].glText)) else { return false }
            result.pages = pages
            if let a = es[es.count - 1].children().first(),
               let m = patternNextPage.firstMatch(in: a.glAttr("href")) {
                result.nextPage = GallerySoup.parseInt(m[1], 0)
            }
            return true
        }

        // 新版 prev/next 游标分页
        guard let searchNav = d.glFirstByClass("searchnav") else { return false }
        result.pages = -1
        result.nextPage = -1
        // Java 端使用 "uFirst"（大小写与页面的 "ufirst" 不一致，永远取不到），这里两者都尝试
        result.firstHref = (searchNav.glById("uFirst") ?? searchNav.glById("ufirst"))?.glAttr("href") ?? ""
        result.prevHref = searchNav.glById("uprev")?.glAttr("href") ?? ""
        result.nextHref = searchNav.glById("unext")?.glAttr("href") ?? ""
        result.lastHref = searchNav.glById("ulast")?.glAttr("href") ?? ""

        if let st = d.glFirstByClass("searchtext") {
            if let m = patternResultCountPage.firstMatch(in: st.glText), let found = m[0] {
                result.resultCount = parseResultCount(found)
            }
        } else {
            result.resultCount = ""
        }
        return true
    }

    /// "Found about 12,345 results" -> "12,345+"；"Found thousands of results" -> "1,000+"；"Found 123 results" -> "123"
    static func parseResultCount(_ found: String) -> String {
        // 与 Java String.split(" ") 一致：去掉末尾空串
        var arr = found.components(separatedBy: " ")
        while arr.last == "" { arr.removeLast() }
        if arr.count > 3 {
            switch arr[1] {
            case "thousands": return "1,000+"
            case "about": return arr[2] + "+"
            default: return arr[1..<(arr.count - 1)].joined()
            }
        } else if arr.count == 3 {
            return arr[1]
        }
        return ""
    }

    /// 评分星级由背景图偏移表示：`background-position:-16px -21px` -> 3.5
    static func parseRating(_ ratingStyle: String) -> String? {
        let ms = patternRating.allMatches(in: ratingStyle)
        guard ms.count >= 2 else { return nil }
        let num1 = ParserUtils.parseInt(ms[0][0]?.replacingOccurrences(of: "px", with: ""), Int.min)
        let num2 = ParserUtils.parseInt(ms[1][0]?.replacingOccurrences(of: "px", with: ""), Int.min)
        if num1 == Int.min || num2 == Int.min { return nil }
        var rate = 5 - num1 / 16
        if num2 == 21 {
            rate -= 1
            return "\(rate).5"
        }
        return "\(rate)"
    }

    static func parseFavoriteSlot(_ style: String) -> Int {
        guard let m = patternFavoriteSlot.firstMatch(in: style) else { return -2 }
        for (slot, rgb) in favoriteSlotRGB.enumerated() where m[1] == rgb.0 && m[2] == rgb.1 && m[3] == rgb.2 {
            return slot
        }
        return -2
    }

    /// 解析单个列表条目（表格行或 Thumbnail 模式的 div）。没有标题时返回 nil（例如表头）
    public static func parseGalleryInfo(
        _ e: Element,
        thumbResolution: Int = 0,
        isLocalFavorite: ((Int64) -> Bool)? = nil
    ) -> GalleryInfo? {
        var gi = GalleryInfo()

        // 标题、gid、token（必须）、tags
        if let glname = e.glFirstByClass("glname") {
            var a = glname.glFirstByTag("a")
            if a == nil, let parent = glname.parent(), parent.tagName() == "a" {
                a = parent
            }
            if let a, let r = GalleryDetailUrlParser.parse(a.glAttr("href")) {
                gi.gid = r.gid
                gi.token = r.token
            }

            // 取最深的第一个子元素的文本作为标题
            var child = glname
            var children = glname.children()
            while !children.isEmpty() {
                child = children.get(0)
                children = child.children()
            }
            gi.title = GallerySoup.trim(child.glText)

            if let tbody = glname.glFirstByTag("tbody") {
                var tags: [String] = []
                for group in GalleryDetailParser.parseTagGroups(tbody.children().array()) {
                    for tag in group.tags {
                        tags.append(group.groupName + ":" + tag)
                    }
                }
                gi.simpleTags = tags
            }
        }
        if gi.title == nil { return nil }

        // 分类
        gi.category = .unknown
        if let ce = e.glFirstByClass("cn") ?? e.glFirstByClass("cs") {
            gi.category = EhCategory.from(string: ce.glText)
        }

        // 缩略图（Minimal / Compact）
        if let glThumb = e.glFirstByClass("glthumb") {
            if let img = glThumb.glSelectFirst("div:nth-child(1)>img") {
                if let m = patternThumbSize.firstMatch(in: img.glAttr("style")) {
                    gi.thumbWidth = GallerySoup.parseInt(m[2], 0)
                    gi.thumbHeight = GallerySoup.parseInt(m[1], 0)
                } else {
                    gi.thumbWidth = 0
                    gi.thumbHeight = 0
                }
                var url: String? = img.glAttr("data-src")
                if url?.isEmpty ?? true { url = img.glAttr("src") }
                if url?.isEmpty ?? true { url = nil }
                gi.thumb = EhUtils.handleThumbUrlResolution(url, resolution: thumbResolution)
            }
            // 页数
            if let div = glThumb.glSelectFirst("div:nth-child(2)>div:nth-child(2)>div:nth-child(2)"),
               let m = patternPages.firstMatch(in: div.glText) {
                gi.pages = GallerySoup.parseInt(m[1], 0)
            }
        }
        // Extended / Thumbnail 模式
        if gi.thumb == nil, let gl = e.glFirstByClass("gl1e") ?? e.glFirstByClass("gl3t"),
           let img = gl.glFirstByTag("img") {
            if let m = patternThumbSize.firstMatch(in: img.glAttr("style")) {
                gi.thumbWidth = GallerySoup.parseInt(m[2], 0)
                gi.thumbHeight = GallerySoup.parseInt(m[1], 0)
            } else {
                gi.thumbWidth = 0
                gi.thumbHeight = 0
            }
            gi.thumb = EhUtils.handleThumbUrlResolution(img.glAttr("src"), resolution: thumbResolution)
        }

        // 发布时间 + 收藏夹颜色
        gi.favoriteSlot = -2
        if let posted = e.glById("posted_\(gi.gid)") {
            gi.posted = GallerySoup.trim(posted.glText)
            gi.favoriteSlot = parseFavoriteSlot(posted.glAttr("style"))
        }
        if gi.favoriteSlot == -2 {
            gi.favoriteSlot = (isLocalFavorite?(gi.gid) ?? false) ? -1 : -2
        }

        parseTag(&gi, e)

        // 评分
        if let ir = e.glFirstByClass("ir") {
            gi.rating = GallerySoup.parseFloat(parseRating(ir.glAttr("style")), -1)
            // TODO 与 Java 一致：没有这些 class 也可能已评分
            gi.rated = ir.hasClass("irr") || ir.hasClass("irg") || ir.hasClass("irb")
        }

        // 上传者与页数
        var gl = e.glFirstByClass("glhide")
        var uploaderIndex = 0
        var pagesIndex = 1
        if gl == nil {
            // Extended 模式
            gl = e.glFirstByClass("gl3e")
            uploaderIndex = 3
            pagesIndex = 4
        }
        if let gl {
            let children = gl.children()
            if children.count > uploaderIndex, let a = children.get(uploaderIndex).children().first() {
                gi.uploader = GallerySoup.trim(a.glText)
            }
            if children.count > pagesIndex, let m = patternPages.firstMatch(in: children.get(pagesIndex).glText) {
                gi.pages = GallerySoup.parseInt(m[1], 0)
            }
        }
        // Thumbnail 模式的页数
        if let gl5t = e.glFirstByClass("gl5t"),
           let div = gl5t.glSelectFirst("div:nth-child(2)>div:nth-child(2)"),
           let m = patternPages.firstMatch(in: div.glText) {
            gi.pages = GallerySoup.parseInt(m[1], 0)
        }

        gi.generateSimpleLanguage()
        return gi
    }

    /// 列表中显示的 tag（`.gt` / `.gtl` 的 title 属性，如 "female:big breasts"；对应 jsoup `eachAttr`，跳过无该属性的元素）
    private static func parseTag(_ gi: inout GalleryInfo, _ e: Element) {
        if let gts = e.glAllByClass("gt") {
            gi.tgList = gts.filter { $0.hasAttr("title") }.map { $0.glAttr("title") }
        }
        if let gtl = e.glAllByClass("gtl") {
            if gi.tgList == nil { gi.tgList = [] }
            gi.tgList?.append(contentsOf: gtl.filter { $0.hasAttr("title") }.map { $0.glAttr("title") })
        }
    }
}
