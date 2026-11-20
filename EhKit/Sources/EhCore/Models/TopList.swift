import Foundation

/// 排行榜单项。对应 Android `data/topList/TopListItem`
public struct TopListItem: Codable, Sendable, Hashable {
    public var href: String?
    public var gid: String?
    public var token: String?
    public var tag: String?
    /// 显示文本（画廊标题 / 用户名 / 标签）
    public var value: String?

    public init(href: String? = nil, gid: String? = nil, token: String? = nil, tag: String? = nil, value: String? = nil) {
        self.href = href; self.gid = gid; self.token = token; self.tag = tag; self.value = value
    }
}

/// 某时间段的榜单（最多 10 项）。对应 `TopListItemArray`
/// Java 版是定长 10 的数组（不足时为 null），这里只保存实际解析到的项
public struct TopListItemArray: Codable, Sendable, Hashable {
    public var itemArray: [TopListItem]
    public init(itemArray: [TopListItem] = []) { self.itemArray = itemArray }

    public var length: Int { itemArray.count }
    public func get(_ index: Int) -> TopListItem? {
        itemArray.indices.contains(index) ? itemArray[index] : nil
    }
}

/// 一类排行榜（四个时间段）。对应 `TopListInfo`
public struct TopListInfo: Codable, Sendable, Hashable {
    public var allTimeTopList: TopListItemArray
    public var pastYearTopList: TopListItemArray
    public var pastMonthTopList: TopListItemArray
    public var yesterdayTopList: TopListItemArray
    public var title: String?
    public var type: EhTopListDetail.ListType

    public init(
        type: EhTopListDetail.ListType, allTimeTopList: TopListItemArray = .init(),
        pastYearTopList: TopListItemArray = .init(), pastMonthTopList: TopListItemArray = .init(),
        yesterdayTopList: TopListItemArray = .init(), title: String? = nil
    ) {
        self.type = type; self.allTimeTopList = allTimeTopList; self.pastYearTopList = pastYearTopList
        self.pastMonthTopList = pastMonthTopList; self.yesterdayTopList = yesterdayTopList; self.title = title
    }

    /// 0 = 昨日，1 = 过去一月，2 = 过去一年，3 = 总榜
    public func get(_ index: Int) -> TopListItemArray? {
        switch index {
        case 0: return yesterdayTopList
        case 1: return pastMonthTopList
        case 2: return pastYearTopList
        case 3: return allTimeTopList
        default: return nil
        }
    }

    public var size: Int { 4 }
}

/// 排行榜页（toplist.php）。对应 `EhTopListDetail`
public struct EhTopListDetail: Codable, Sendable, Hashable {
    public enum ListType: Int, Codable, Sendable, CaseIterable {
        case gallery, uploader, tagging, hentaiHome, ehTracker, cleanup, ratingAndReviewing
    }

    public var title: String?
    public var galleryTopListInfo: TopListInfo
    public var uploaderTopListInfo: TopListInfo
    public var taggingTopListInfo: TopListInfo
    public var hentaiHomeTopListInfo: TopListInfo
    public var ehTrackerTopListInfo: TopListInfo
    public var cleanUpTopListInfo: TopListInfo
    public var ratingAndReviewingTopListInfo: TopListInfo

    public init(
        title: String? = nil,
        galleryTopListInfo: TopListInfo = .init(type: .gallery),
        uploaderTopListInfo: TopListInfo = .init(type: .uploader),
        taggingTopListInfo: TopListInfo = .init(type: .tagging),
        hentaiHomeTopListInfo: TopListInfo = .init(type: .hentaiHome),
        ehTrackerTopListInfo: TopListInfo = .init(type: .ehTracker),
        cleanUpTopListInfo: TopListInfo = .init(type: .cleanup),
        ratingAndReviewingTopListInfo: TopListInfo = .init(type: .ratingAndReviewing)
    ) {
        self.title = title
        self.galleryTopListInfo = galleryTopListInfo
        self.uploaderTopListInfo = uploaderTopListInfo
        self.taggingTopListInfo = taggingTopListInfo
        self.hentaiHomeTopListInfo = hentaiHomeTopListInfo
        self.ehTrackerTopListInfo = ehTrackerTopListInfo
        self.cleanUpTopListInfo = cleanUpTopListInfo
        self.ratingAndReviewingTopListInfo = ratingAndReviewingTopListInfo
    }

    /// 按 ListType 顺序取
    public func get(_ index: Int) -> TopListInfo? {
        switch index {
        case 0: return galleryTopListInfo
        case 1: return uploaderTopListInfo
        case 2: return taggingTopListInfo
        case 3: return hentaiHomeTopListInfo
        case 4: return ehTrackerTopListInfo
        case 5: return cleanUpTopListInfo
        case 6: return ratingAndReviewingTopListInfo
        default: return nil
        }
    }
}
