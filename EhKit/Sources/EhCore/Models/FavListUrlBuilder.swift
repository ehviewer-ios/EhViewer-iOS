import Foundation

/// 收藏夹列表 URL 构造。对应 Android `client/data/FavListUrlBuilder`；站点改为 `build(site:)` 参数传入。
public struct FavListUrlBuilder: Codable, Sendable, Hashable {
    /// 全部云端收藏
    public static let FAV_CAT_ALL = -1
    /// 本地收藏
    public static let FAV_CAT_LOCAL = -2

    /// 旧版页码（>0 时附加 page=）
    public var index: Int = 0
    public var keyword: String?
    /// 0-9 为云端收藏夹编号，-1 全部，-2 本地
    public var favCat: Int = FavListUrlBuilder.FAV_CAT_ALL

    public init(index: Int = 0, keyword: String? = nil, favCat: Int = FavListUrlBuilder.FAV_CAT_ALL) {
        self.index = index
        self.keyword = keyword
        self.favCat = favCat
    }

    public static func isValidFavCat(_ favCat: Int) -> Bool {
        favCat >= 0 && favCat <= 9
    }

    public var isLocalFavCat: Bool { favCat == Self.FAV_CAT_LOCAL }

    /// 新版游标分页。对应 `build(int pageAction, GalleryInfoContentHelper)`
    public func build(pageAction: ListPageAction, hrefs: ListPageHrefs) -> String? {
        ListPageHrefSupport.build(pageAction, hrefs)
    }

    /// 对应 `jumpHrefBuild`
    public func jumpHrefBuild(_ urlOld: String, appendParam: String) -> String {
        ListPageHrefSupport.jumpHrefBuild(urlOld, appendParam)
    }

    public func build(site: EhSite) -> String {
        var ub = QueryUrlBuilder(EhURL.favorites(site))
        if Self.isValidFavCat(favCat) {
            ub.addQuery("favcat", String(favCat))
        }
        if let keyword, !keyword.isEmpty {
            ub.addQuery("f_search", EhUtils.urlEncode(keyword))
            // 名称
            ub.addQuery("sn", "on")
            // tag
            ub.addQuery("st", "on")
            // 备注
            ub.addQuery("sf", "on")
        }
        if index > 0 {
            ub.addQuery("page", String(index))
        }
        return ub.build()
    }
}
