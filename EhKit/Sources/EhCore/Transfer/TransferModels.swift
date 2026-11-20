import Foundation

/// 帧的 dataType 与 JSON data 键名。对应 Android `ConnectThread.DATA_TYPE_*` / `*_KEY`
public enum TransferDataType {
    public static let quickSearch = 1001
    public static let downloadInfo = 1002
    public static let downloadLabel = 1003
    public static let favoriteInfo = 1004
    public static let downloadDirManifest = 1005
    public static let downloadDirAck = 1006
    public static let downloadDirFile = 1007
    /// iOS 扩展：浏览历史（Android 无此类型；Android 接收端会按“未知类型”直接回 RECEIVED，不会写入）
    public static let historyInfo = 1008

    public static let quickSearchKey = "quick_search"
    public static let downloadInfoKey = "download_info"
    public static let downloadLabelKey = "download_label"
    public static let favoriteInfoKey = "favorite_info"
    /// iOS 扩展
    public static let historyInfoKey = "history_info"
}

/// 可迁移的数据种类。rawValue 与 Android `WiFiServerActivity` 下拉框（`migrate_data_types`）的序号一致
public enum TransferDataKind: Int, Sendable, Hashable, CaseIterable, Codable {
    /// 快速搜索（Android 界面文案为“书签”）
    case quickSearch = 0
    /// 本地收藏
    case favorite = 1
    /// 下载列表（先发标签，再分页发下载项）
    case download = 2
    /// 下载目录（文件本体）
    case downloadDir = 3
    /// iOS 扩展：浏览历史
    case history = 100

    /// 接收到的 dataType 属于哪个种类
    public init?(dataType: Int) {
        switch dataType {
        case TransferDataType.quickSearch: self = .quickSearch
        case TransferDataType.favoriteInfo: self = .favorite
        case TransferDataType.downloadInfo, TransferDataType.downloadLabel: self = .download
        case TransferDataType.downloadDirManifest, TransferDataType.downloadDirAck,
             TransferDataType.downloadDirFile: self = .downloadDir
        case TransferDataType.historyInfo: self = .history
        default: return nil
        }
    }
}

// MARK: - GalleryInfo JSON（GalleryInfo.toJson / galleryInfoFromJson）

extension GalleryInfo {
    /// 对应 Android `GalleryInfo.toJson()`。
    ///
    /// - null 字段省略（fastjson 默认）；`rated`、`rating` 必须写出（Android 读取时为 null 会 NPE）
    /// - iOS 没有 spanSize / spanIndex / spanGroupIndex（瀑布流布局字段），固定写 0
    /// - `tgList` 按 Android 写法包一层：`[tgList]`，为空时为 `[null]`
    public var transferJSON: [String: TransferJSON] {
        var o: [String: TransferJSON] = [
            "gid": .int(gid),
            "token": .string(token),
            "category": .int(category.rawValue),
            "rating": .float(rating),
            "rated": .bool(rated),
            "thumbHeight": .int(thumbHeight),
            "thumbWidth": .int(thumbWidth),
            "spanSize": .int(0),
            "spanIndex": .int(0),
            "spanGroupIndex": .int(0),
            "favoriteSlot": .int(favoriteSlot),
            "tgList": .array([tgList.map { .array($0.map(TransferJSON.string)) } ?? .null]),
            "pages": .int(pages),
        ]
        if let title { o["title"] = .string(title) }
        if let titleJpn { o["titleJpn"] = .string(titleJpn) }
        if let thumb { o["thumb"] = .string(thumb) }
        if let posted { o["posted"] = .string(posted) }
        if let uploader { o["uploader"] = .string(uploader) }
        if let simpleLanguage { o["simpleLanguage"] = .string(simpleLanguage) }
        if let simpleTags { o["simpleTags"] = .array(simpleTags.map(TransferJSON.string)) }
        if let favoriteName { o["favoriteName"] = .string(favoriteName) }
        return o
    }

    /// 对应 Android `GalleryInfo.galleryInfoFromJson`。
    ///
    /// 与 Android 的差异：Android 误写为 `getString("")`，simpleLanguage 恒为 null；这里读取 "simpleLanguage"。
    /// tgList 兼容 `[[…]]`（Android 写法）与 `[…]` 两种形式。
    public init(transferJSON o: [String: TransferJSON]) {
        self.init()
        posted = o["posted"]?.stringValue
        category = EhCategory(rawValue: o["category"]?.intValue ?? 0)
        favoriteName = o["favoriteName"]?.stringValue
        favoriteSlot = o["favoriteSlot"]?.intValue ?? 0
        gid = o["gid"]?.int64Value ?? 0
        pages = o["pages"]?.intValue ?? 0
        rated = o["rated"]?.boolValue ?? false
        rating = o["rating"]?.floatValue ?? 0
        simpleLanguage = o["simpleLanguage"]?.stringValue
        if let arr = o["simpleTags"]?.arrayValue {
            simpleTags = arr.compactMap(\.stringValue)
        }
        if let arr = o["tgList"]?.arrayValue {
            var list: [String] = []
            for v in arr {
                if let inner = v.arrayValue {
                    list.append(contentsOf: inner.compactMap(\.stringValue))
                } else if case let .string(s) = v {
                    list.append(s)
                }
            }
            tgList = list.isEmpty ? nil : list
        }
        thumb = o["thumb"]?.stringValue
        thumbHeight = o["thumbHeight"]?.intValue ?? 0
        thumbWidth = o["thumbWidth"]?.intValue ?? 0
        title = o["title"]?.stringValue
        titleJpn = o["titleJpn"]?.stringValue
        token = o["token"]?.stringValue ?? ""
        uploader = o["uploader"]?.stringValue
    }
}

// MARK: - QuickSearch JSON

/// 快速搜索的传输形式。对应 Android `QuickSearch.toJson / quickSearchFromJson`（与 EhStorage `QuickSearch` 字段一致）
public struct TransferQuickSearch: Sendable, Hashable, Codable {
    public var name: String?
    public var mode: Int
    public var category: Int
    public var keyword: String?
    public var advanceSearch: Int
    public var minRating: Int
    public var pageFrom: Int
    public var pageTo: Int
    public var time: Int64

    public init(name: String? = nil, mode: Int = 0, category: Int = 0, keyword: String? = nil,
                advanceSearch: Int = 0, minRating: Int = 0, pageFrom: Int = -1, pageTo: Int = -1,
                time: Int64 = 0) {
        self.name = name; self.mode = mode; self.category = category; self.keyword = keyword
        self.advanceSearch = advanceSearch; self.minRating = minRating; self.pageFrom = pageFrom
        self.pageTo = pageTo; self.time = time
    }

    public var transferJSON: [String: TransferJSON] {
        var o: [String: TransferJSON] = [
            "mode": .int(mode), "category": .int(category), "advanceSearch": .int(advanceSearch),
            "minRating": .int(minRating), "pageFrom": .int(pageFrom), "pageTo": .int(pageTo),
            "time": .int(time),
        ]
        if let name { o["name"] = .string(name) }
        if let keyword { o["keyword"] = .string(keyword) }
        return o
    }

    /// 缺失的 int 字段为 0（fastjson `getIntValue`），与 Android 一致
    public init(transferJSON o: [String: TransferJSON]) {
        self.init(name: o["name"]?.stringValue, mode: o["mode"]?.intValue ?? 0,
                  category: o["category"]?.intValue ?? 0, keyword: o["keyword"]?.stringValue,
                  advanceSearch: o["advanceSearch"]?.intValue ?? 0, minRating: o["minRating"]?.intValue ?? 0,
                  pageFrom: o["pageFrom"]?.intValue ?? 0, pageTo: o["pageTo"]?.intValue ?? 0,
                  time: o["time"]?.int64Value ?? 0)
    }
}

// MARK: - DownloadInfo JSON

/// 下载项的传输形式。对应 Android `DownloadInfo.toJson / downloadInfoFromJson`：GalleryInfo 字段 + 下载字段
public struct TransferDownloadItem: Sendable, Hashable {
    public var info: GalleryInfo
    public var finished: Int
    public var legacy: Int
    public var label: String?
    public var downloaded: Int
    public var remaining: Int64
    public var speed: Int64
    public var state: Int
    public var time: Int64
    public var total: Int
    /// Android 为 SAF `content://` URI，跨设备无意义；iOS 发送时不写，接收时忽略
    public var archiveUri: String?

    public init(info: GalleryInfo, finished: Int = 0, legacy: Int = 0, label: String? = nil, downloaded: Int = 0,
                remaining: Int64 = 0, speed: Int64 = 0, state: Int = 0, time: Int64 = 0, total: Int = 0,
                archiveUri: String? = nil) {
        self.info = info; self.finished = finished; self.legacy = legacy; self.label = label
        self.downloaded = downloaded; self.remaining = remaining; self.speed = speed; self.state = state
        self.time = time; self.total = total; self.archiveUri = archiveUri
    }

    public var transferJSON: [String: TransferJSON] {
        var o = info.transferJSON
        o["finished"] = .int(finished)
        o["legacy"] = .int(legacy)
        o["downloaded"] = .int(downloaded)
        o["remaining"] = .int(remaining)
        o["speed"] = .int(speed)
        o["state"] = .int(state)
        o["time"] = .int(time)
        o["total"] = .int(total)
        if let label { o["label"] = .string(label) }
        if let archiveUri { o["archiveUri"] = .string(archiveUri) }
        return o
    }

    /// 注意：Android 端 `downloadInfoFromJson` 把 GalleryInfo 强转为 DownloadInfo，必然抛 ClassCastException，
    /// 因此 Android 接收端实际上从未导入过下载项；iOS 按字段正常解析。
    public init(transferJSON o: [String: TransferJSON]) {
        self.init(info: GalleryInfo(transferJSON: o), finished: o["finished"]?.intValue ?? 0,
                  legacy: o["legacy"]?.intValue ?? 0, label: o["label"]?.stringValue,
                  downloaded: o["downloaded"]?.intValue ?? 0, remaining: o["remaining"]?.int64Value ?? 0,
                  speed: o["speed"]?.int64Value ?? 0, state: o["state"]?.intValue ?? 0,
                  time: o["time"]?.int64Value ?? 0, total: o["total"]?.intValue ?? 0,
                  archiveUri: o["archiveUri"]?.stringValue)
    }
}

// MARK: - HistoryInfo JSON（iOS 扩展）

/// 浏览历史的传输形式（iOS 扩展，dataType 1008）：GalleryInfo 字段 + mode + time
public struct TransferHistoryItem: Sendable, Hashable {
    public var info: GalleryInfo
    public var mode: Int
    public var time: Int64

    public init(info: GalleryInfo, mode: Int = 0, time: Int64 = 0) {
        self.info = info; self.mode = mode; self.time = time
    }

    public var transferJSON: [String: TransferJSON] {
        var o = info.transferJSON
        o["mode"] = .int(mode)
        o["time"] = .int(time)
        return o
    }

    public init(transferJSON o: [String: TransferJSON]) {
        self.init(info: GalleryInfo(transferJSON: o), mode: o["mode"]?.intValue ?? 0,
                  time: o["time"]?.int64Value ?? 0)
    }
}
