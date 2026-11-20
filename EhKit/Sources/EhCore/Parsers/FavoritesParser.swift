import Foundation
import SwiftSoup

/// 收藏夹页（favorites.php）解析：10 个收藏夹的名称与数量、排序方式，列表部分复用 GalleryListParser。
/// 对应 Android `client/parser/FavoritesParser`
public enum FavoritesParser {
    public struct Result: Sendable, Hashable {
        /// 10 个收藏夹名称
        public var catArray: [String] = []
        /// 10 个收藏夹中的画廊数
        public var countArray: [Int] = []
        public var pages: Int = 0
        public var nextPage: Int = 0
        public var resultCount: String?
        public var firstHref: String?
        public var prevHref: String?
        public var nextHref: String?
        public var lastHref: String?
        /// 排序方式："p" 发布时间 / "f" 收藏时间
        public var favOrder: String?
        public var galleryInfoList: [GalleryInfo] = []

        public init() {}

        public var hrefs: ListPageHrefs {
            ListPageHrefs(firstHref: firstHref, prevHref: prevHref, nextHref: nextHref, lastHref: lastHref)
        }
    }

    public static func parse(
        _ body: String,
        thumbResolution: Int = 0,
        isLocalFavorite: ((Int64) -> Bool)? = nil
    ) throws -> Result {
        if body.contains("This page requires you to log on.</p>") {
            throw EhError.notSignedIn
        }
        var re = Result()
        var catArray = [String](repeating: "", count: 10)
        var countArray = [Int](repeating: 0, count: 10)

        guard let d = GallerySoup.parse(body),
              let ido = d.glFirstByClass("ido"),
              let fps = ido.glAllByClass("fp"),
              // 最后一个是 "fp fps"
              fps.count == 11 else {
            throw EhError.parseFailure("Parse favorites error", html: body)
        }
        for i in 0..<10 {
            let fp = fps[i]
            guard let c0 = fp.glChild(0), let c2 = fp.glChild(2) else {
                throw EhError.parseFailure("Parse favorites error", html: body)
            }
            countArray[i] = ParserUtils.parseInt(c0.glText, 0)
            catArray[i] = ParserUtils.trim(c2.glText)
        }
        if let order = d.glFirstByClass("searchnav"),
           let sel = order.glFirstByTag("select") {
            // 对应 jsoup Elements.attr：取第一个带该属性的元素
            let selected = (try? sel.getElementsByAttribute("selected"))?.array() ?? []
            re.favOrder = selected.first(where: { $0.hasAttr("value") })?.glAttr("value") ?? ""
        }

        let result = try GalleryListParser.parse(
            document: d, body: body, thumbResolution: thumbResolution, isLocalFavorite: isLocalFavorite
        )
        re.catArray = catArray
        re.countArray = countArray
        re.pages = result.pages
        re.nextPage = result.nextPage
        re.resultCount = result.resultCount
        re.firstHref = result.firstHref
        re.prevHref = result.prevHref
        re.nextHref = result.nextHref
        re.lastHref = result.lastHref
        re.galleryInfoList = result.galleryInfoList
        return re
    }
}
