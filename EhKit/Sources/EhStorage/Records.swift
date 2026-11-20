import Foundation
import GRDB

// 数据库实体。表名 / 列名与 greenDAO 生成的 SQLite 完全一致（见 Android `dao/*Dao.java` 的 createTable），
// 使 Android 导出的 .db 可直接被 iOS 打开 / 导入，反之亦然。

/// 含 GalleryInfo 基础列（GID … SIMPLE_LANGUAGE）的实体共用协议。
/// 对应 Android 中 `extends GalleryInfo` 的 DownloadInfo / HistoryInfo / LocalFavoriteInfo / BookmarkInfo。
public protocol GalleryInfoRecord {
    var gid: Int64 { get set }
    var token: String? { get set }
    var title: String? { get set }
    var titleJpn: String? { get set }
    var thumb: String? { get set }
    var category: Int { get set }
    var posted: String? { get set }
    var uploader: String? { get set }
    var rating: Float { get set }
    var simpleLanguage: String? { get set }
}

public extension GalleryInfoRecord {
    /// 转为 `EhCore.GalleryInfo`（只含数据库中持久化的字段）
    var galleryInfo: GalleryInfo {
        GalleryInfo(
            gid: gid, token: token ?? "", title: title, titleJpn: titleJpn, thumb: thumb,
            category: EhCategory(rawValue: category), posted: posted, uploader: uploader,
            rating: rating, simpleLanguage: simpleLanguage
        )
    }

    /// 从 GalleryInfo 复制基础列
    mutating func copyGalleryInfo(_ info: GalleryInfo) {
        gid = info.gid
        token = info.token
        title = info.title
        titleJpn = info.titleJpn
        thumb = info.thumb
        category = info.category.rawValue
        posted = info.posted
        uploader = info.uploader
        rating = info.rating
        simpleLanguage = info.simpleLanguage
    }
}

/// 列名常量（与 greenDAO Properties 的 columnName 一致）
enum Col {
    static let gid = "GID", token = "TOKEN", title = "TITLE", titleJpn = "TITLE_JPN", thumb = "THUMB"
    static let category = "CATEGORY", posted = "POSTED", uploader = "UPLOADER", rating = "RATING"
    static let simpleLanguage = "SIMPLE_LANGUAGE", time = "TIME", id = "_id", label = "LABEL"
}

// MARK: - DOWNLOADS

/// 下载项。对应 Android `dao/DownloadInfo`（表 DOWNLOADS）。
public struct DownloadInfo: GalleryInfoRecord, Codable, Sendable, Hashable, Identifiable,
    FetchableRecord, PersistableRecord {
    public static let databaseTableName = "DOWNLOADS"

    public static let stateInvalid = -1
    public static let stateNone = 0
    public static let stateWait = 1
    public static let stateDownload = 2
    public static let stateFinish = 3
    public static let stateFailed = 4
    public static let stateUpdate = 5
    public static let gotoNew = 6

    public var gid: Int64
    public var token: String?
    public var title: String?
    public var titleJpn: String?
    public var thumb: String?
    public var category: Int
    public var posted: String?
    public var uploader: String?
    public var rating: Float
    public var simpleLanguage: String?
    public var state: Int
    public var legacy: Int
    public var time: Int64
    public var label: String?
    /// 导入压缩包的 URI（Android 为 content://，iOS 可存 file URL / bookmark）
    public var archiveUri: String?

    // 运行时字段（不入库）
    public var speed: Int64 = 0
    public var remaining: Int64 = 0
    public var finished: Int = 0
    public var downloaded: Int = 0
    public var total: Int = 0
    /// 文件夹总大小（字节），-1 表示未计算
    public var fileSize: Int64 = -1

    public var id: Int64 { gid }

    enum CodingKeys: String, CodingKey {
        case gid = "GID", token = "TOKEN", title = "TITLE", titleJpn = "TITLE_JPN", thumb = "THUMB"
        case category = "CATEGORY", posted = "POSTED", uploader = "UPLOADER", rating = "RATING"
        case simpleLanguage = "SIMPLE_LANGUAGE", state = "STATE", legacy = "LEGACY", time = "TIME"
        case label = "LABEL", archiveUri = "ARCHIVE_URI"
    }

    public init(
        gid: Int64, token: String? = nil, title: String? = nil, titleJpn: String? = nil,
        thumb: String? = nil, category: Int = EhCategory.unknown.rawValue, posted: String? = nil,
        uploader: String? = nil, rating: Float = 0, simpleLanguage: String? = nil,
        state: Int = DownloadInfo.stateNone, legacy: Int = 0, time: Int64 = 0,
        label: String? = nil, archiveUri: String? = nil
    ) {
        self.gid = gid; self.token = token; self.title = title; self.titleJpn = titleJpn
        self.thumb = thumb; self.category = category; self.posted = posted; self.uploader = uploader
        self.rating = rating; self.simpleLanguage = simpleLanguage; self.state = state
        self.legacy = legacy; self.time = time; self.label = label; self.archiveUri = archiveUri
    }

    /// 对应 `new DownloadInfo(GalleryInfo)`
    public init(
        _ info: GalleryInfo, state: Int = DownloadInfo.stateNone, time: Int64 = 0, label: String? = nil,
        archiveUri: String? = nil
    ) {
        self.init(gid: info.gid, state: state, time: time, label: label, archiveUri: archiveUri)
        copyGalleryInfo(info)
    }
}

// MARK: - DOWNLOAD_LABELS

/// 下载标签。对应 `dao/DownloadLabel`（表 DOWNLOAD_LABELS）。顺序由 TIME 升序决定。
public struct DownloadLabel: Codable, Sendable, Hashable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "DOWNLOAD_LABELS"

    public var id: Int64?
    public var label: String?
    public var time: Int64

    enum CodingKeys: String, CodingKey {
        case id = "_id", label = "LABEL", time = "TIME"
    }

    public init(id: Int64? = nil, label: String?, time: Int64) {
        self.id = id; self.label = label; self.time = time
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - DOWNLOAD_DIRNAME

/// gid → 下载目录名。对应 `dao/DownloadDirname`（表 DOWNLOAD_DIRNAME）
public struct DownloadDirname: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "DOWNLOAD_DIRNAME"

    public var gid: Int64
    public var dirname: String?

    enum CodingKeys: String, CodingKey {
        case gid = "GID", dirname = "DIRNAME"
    }

    public init(gid: Int64, dirname: String?) {
        self.gid = gid; self.dirname = dirname
    }
}

// MARK: - HISTORY

/// 浏览历史。对应 `dao/HistoryInfo`（表 HISTORY）
public struct HistoryInfo: GalleryInfoRecord, Codable, Sendable, Hashable, Identifiable,
    FetchableRecord, PersistableRecord {
    public static let databaseTableName = "HISTORY"

    public var gid: Int64
    public var token: String?
    public var title: String?
    public var titleJpn: String?
    public var thumb: String?
    public var category: Int
    public var posted: String?
    public var uploader: String?
    public var rating: Float
    public var simpleLanguage: String?
    public var mode: Int
    public var time: Int64

    public var id: Int64 { gid }

    enum CodingKeys: String, CodingKey {
        case gid = "GID", token = "TOKEN", title = "TITLE", titleJpn = "TITLE_JPN", thumb = "THUMB"
        case category = "CATEGORY", posted = "POSTED", uploader = "UPLOADER", rating = "RATING"
        case simpleLanguage = "SIMPLE_LANGUAGE", mode = "MODE", time = "TIME"
    }

    public init(
        gid: Int64, token: String? = nil, title: String? = nil, titleJpn: String? = nil,
        thumb: String? = nil, category: Int = EhCategory.unknown.rawValue, posted: String? = nil,
        uploader: String? = nil, rating: Float = 0, simpleLanguage: String? = nil,
        mode: Int = 0, time: Int64 = 0
    ) {
        self.gid = gid; self.token = token; self.title = title; self.titleJpn = titleJpn
        self.thumb = thumb; self.category = category; self.posted = posted; self.uploader = uploader
        self.rating = rating; self.simpleLanguage = simpleLanguage; self.mode = mode; self.time = time
    }

    public init(_ info: GalleryInfo, mode: Int = 0, time: Int64 = 0) {
        self.init(gid: info.gid, mode: mode, time: time)
        copyGalleryInfo(info)
    }
}

// MARK: - QUICK_SEARCH

/// 快速搜索。对应 `dao/QuickSearch`（表 QUICK_SEARCH）。顺序由 TIME 升序决定。
public struct QuickSearch: Codable, Sendable, Hashable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "QUICK_SEARCH"

    public var id: Int64?
    public var name: String?
    public var mode: Int
    public var category: Int
    public var keyword: String?
    public var advanceSearch: Int
    public var minRating: Int
    public var pageFrom: Int
    public var pageTo: Int
    public var time: Int64

    enum CodingKeys: String, CodingKey {
        case id = "_id", name = "NAME", mode = "MODE", category = "CATEGORY", keyword = "KEYWORD"
        case advanceSearch = "ADVANCE_SEARCH", minRating = "MIN_RATING", pageFrom = "PAGE_FROM"
        case pageTo = "PAGE_TO", time = "TIME"
    }

    public init(
        id: Int64? = nil, name: String? = nil, mode: Int = 0, category: Int = 0, keyword: String? = nil,
        advanceSearch: Int = 0, minRating: Int = 0, pageFrom: Int = -1, pageTo: Int = -1, time: Int64 = 0
    ) {
        self.id = id; self.name = name; self.mode = mode; self.category = category; self.keyword = keyword
        self.advanceSearch = advanceSearch; self.minRating = minRating; self.pageFrom = pageFrom
        self.pageTo = pageTo; self.time = time
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    /// 对应 `QuickSearch.toJson()` 的字段（用于与 Android 互传的 JSON）
    public var jsonObject: [String: Any] {
        var o: [String: Any] = [
            "mode": mode, "category": category, "advanceSearch": advanceSearch,
            "minRating": minRating, "pageFrom": pageFrom, "pageTo": pageTo, "time": time,
        ]
        if let name { o["name"] = name }
        if let keyword { o["keyword"] = keyword }
        return o
    }

    /// 对应 `QuickSearch.quickSearchFromJson`
    public init(jsonObject o: [String: Any]) {
        func int(_ k: String) -> Int { (o[k] as? NSNumber)?.intValue ?? Int(o[k] as? String ?? "") ?? 0 }
        self.init(
            name: o["name"] as? String, mode: int("mode"), category: int("category"),
            keyword: o["keyword"] as? String, advanceSearch: int("advanceSearch"),
            minRating: int("minRating"), pageFrom: int("pageFrom"), pageTo: int("pageTo"),
            time: (o["time"] as? NSNumber)?.int64Value ?? 0
        )
    }
}

// MARK: - LOCAL_FAVORITES

/// 本地收藏。对应 `dao/LocalFavoriteInfo`（表 LOCAL_FAVORITES）
public struct LocalFavoriteInfo: GalleryInfoRecord, Codable, Sendable, Hashable, Identifiable,
    FetchableRecord, PersistableRecord {
    public static let databaseTableName = "LOCAL_FAVORITES"

    public var gid: Int64
    public var token: String?
    public var title: String?
    public var titleJpn: String?
    public var thumb: String?
    public var category: Int
    public var posted: String?
    public var uploader: String?
    public var rating: Float
    public var simpleLanguage: String?
    public var time: Int64

    public var id: Int64 { gid }

    enum CodingKeys: String, CodingKey {
        case gid = "GID", token = "TOKEN", title = "TITLE", titleJpn = "TITLE_JPN", thumb = "THUMB"
        case category = "CATEGORY", posted = "POSTED", uploader = "UPLOADER", rating = "RATING"
        case simpleLanguage = "SIMPLE_LANGUAGE", time = "TIME"
    }

    public init(
        gid: Int64, token: String? = nil, title: String? = nil, titleJpn: String? = nil,
        thumb: String? = nil, category: Int = EhCategory.unknown.rawValue, posted: String? = nil,
        uploader: String? = nil, rating: Float = 0, simpleLanguage: String? = nil, time: Int64 = 0
    ) {
        self.gid = gid; self.token = token; self.title = title; self.titleJpn = titleJpn
        self.thumb = thumb; self.category = category; self.posted = posted; self.uploader = uploader
        self.rating = rating; self.simpleLanguage = simpleLanguage; self.time = time
    }

    public init(_ info: GalleryInfo, time: Int64 = 0) {
        self.init(gid: info.gid, time: time)
        copyGalleryInfo(info)
    }
}

// MARK: - BOOKMARKS

/// 阅读书签。对应 `dao/BookmarkInfo`（表 BOOKMARKS）
public struct BookmarkInfo: GalleryInfoRecord, Codable, Sendable, Hashable, Identifiable,
    FetchableRecord, PersistableRecord {
    public static let databaseTableName = "BOOKMARKS"

    public var gid: Int64
    public var token: String?
    public var title: String?
    public var titleJpn: String?
    public var thumb: String?
    public var category: Int
    public var posted: String?
    public var uploader: String?
    public var rating: Float
    public var simpleLanguage: String?
    public var page: Int
    public var time: Int64

    public var id: Int64 { gid }

    enum CodingKeys: String, CodingKey {
        case gid = "GID", token = "TOKEN", title = "TITLE", titleJpn = "TITLE_JPN", thumb = "THUMB"
        case category = "CATEGORY", posted = "POSTED", uploader = "UPLOADER", rating = "RATING"
        case simpleLanguage = "SIMPLE_LANGUAGE", page = "PAGE", time = "TIME"
    }

    public init(
        gid: Int64, token: String? = nil, title: String? = nil, titleJpn: String? = nil,
        thumb: String? = nil, category: Int = EhCategory.unknown.rawValue, posted: String? = nil,
        uploader: String? = nil, rating: Float = 0, simpleLanguage: String? = nil,
        page: Int = 0, time: Int64 = 0
    ) {
        self.gid = gid; self.token = token; self.title = title; self.titleJpn = titleJpn
        self.thumb = thumb; self.category = category; self.posted = posted; self.uploader = uploader
        self.rating = rating; self.simpleLanguage = simpleLanguage; self.page = page; self.time = time
    }

    public init(_ info: GalleryInfo, page: Int = 0, time: Int64 = 0) {
        self.init(gid: info.gid, page: page, time: time)
        copyGalleryInfo(info)
    }
}

// MARK: - FILTER

/// 过滤规则。对应 `dao/Filter`（表 FILTER）。
/// Android 的 equals/hashCode 只比较 mode + text，这里用 `isSameRule(_:)` 表达，`Hashable` 仍按全部字段。
public struct Filter: Codable, Sendable, Hashable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "FILTER"

    public var id: Int64?
    /// 见 `EhFilter.Mode`
    public var mode: Int
    public var text: String?
    /// 可空（旧版本没有此列）。nil 视为启用，与 2→3 升级时填 1 的语义一致
    public var enable: Bool?

    public var isEnabled: Bool { enable ?? true }

    enum CodingKeys: String, CodingKey {
        case id = "_id", mode = "MODE", text = "TEXT", enable = "ENABLE"
    }

    public init(id: Int64? = nil, mode: Int, text: String?, enable: Bool? = true) {
        self.id = id; self.mode = mode; self.text = text; self.enable = enable
    }

    /// 对应 Android `Filter.equals`
    public func isSameRule(_ other: Filter) -> Bool {
        mode == other.mode && text == other.text
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Black_List

/// 评论黑名单。对应 `dao/BlackList`（表 Black_List）
public struct BlackList: Codable, Sendable, Hashable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "Black_List"

    public var id: Int64?
    public var badgayname: String?
    public var reason: String?
    public var angrywith: String?
    /// Android 存的是格式化时间字符串（`TimeUtils.timeNow`）
    public var add_time: String?
    public var mode: Int?

    enum CodingKeys: String, CodingKey {
        case id = "_id", badgayname = "BADGAYNAME", reason = "REASON", angrywith = "ANGRYWITH"
        case add_time = "ADD_TIME", mode = "MODE"
    }

    public init(
        id: Int64? = nil, badgayname: String?, reason: String? = nil, angrywith: String? = nil,
        add_time: String? = nil, mode: Int? = nil
    ) {
        self.id = id; self.badgayname = badgayname; self.reason = reason
        self.angrywith = angrywith; self.add_time = add_time; self.mode = mode
    }

    /// 对应 `BlackListUtils.parseBlacklist(comment)`：用评论者与评论内容构造
    public static func fromComment(user: String?, comment: String?, now: Date = Date()) -> BlackList {
        BlackList(badgayname: user, angrywith: comment, add_time: timeNow(now), mode: 1)
    }

    /// 对应 `TimeUtils.timeNow`（yyyy-MM-dd HH:mm:ss）
    static func timeNow(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: date)
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Gallery_Tags

/// 画廊 tag 缓存（按命名空间分列，各列为逗号分隔字符串）。对应 `dao/GalleryTags`（表 Gallery_Tags）。
/// greenDAO 的 Date 列存毫秒整数，这里通过日期编码策略保持一致。
public struct GalleryTags: Codable, Sendable, Hashable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "Gallery_Tags"

    public var gid: Int64
    public var rows: String?
    public var artist: String?
    public var cosplayer: String?
    public var character: String?
    public var female: String?
    public var group: String?
    public var language: String?
    public var male: String?
    public var misc: String?
    public var mixed: String?
    public var other: String?
    public var parody: String?
    public var reclass: String?
    public var create_time: Date?
    public var update_time: Date?
    public var location: String?

    public var id: Int64 { gid }

    enum CodingKeys: String, CodingKey {
        case gid = "GID", rows = "ROWS", artist = "ARTIST", cosplayer = "COSPLAYER"
        case character = "CHARACTER", female = "FEMALE", group = "GROUP", language = "LANGUAGE"
        case male = "MALE", misc = "MISC", mixed = "MIXED", other = "OTHER", parody = "PARODY"
        case reclass = "RECLASS", create_time = "CREATE_TIME", update_time = "UPDATE_TIME"
        case location = "LOCATION"
    }

    public init(
        gid: Int64, rows: String? = nil, artist: String? = nil, cosplayer: String? = nil,
        character: String? = nil, female: String? = nil, group: String? = nil, language: String? = nil,
        male: String? = nil, misc: String? = nil, mixed: String? = nil, other: String? = nil,
        parody: String? = nil, reclass: String? = nil, create_time: Date? = nil,
        update_time: Date? = nil, location: String? = nil
    ) {
        self.gid = gid; self.rows = rows; self.artist = artist; self.cosplayer = cosplayer
        self.character = character; self.female = female; self.group = group; self.language = language
        self.male = male; self.misc = misc; self.mixed = mixed; self.other = other
        self.parody = parody; self.reclass = reclass; self.create_time = create_time
        self.update_time = update_time; self.location = location
    }

    /// 毫秒整数，四舍五入（GRDB 内置的 .millisecondsSince1970 用 floor，浮点误差可能少 1 ms）
    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        .custom { date in Int64((date.timeIntervalSince1970 * 1000).rounded()) }
    }

    /// 毫秒 → Date
    public static func date(millis: Int64) -> Date {
        Date(timeIntervalSince1970: Double(millis) / 1000)
    }

    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        .millisecondsSince1970
    }
}
