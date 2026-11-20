import Foundation

/// 详情页 tag 分组（如 "female" -> ["big breasts", ...]）。对应 `GalleryTagGroup`
public struct GalleryTagGroup: Codable, Sendable, Hashable {
    public var groupName: String
    public var tags: [String]
    public init(groupName: String, tags: [String] = []) {
        self.groupName = groupName
        self.tags = tags
    }
}

/// 评论。对应 `GalleryComment`
public struct GalleryComment: Codable, Sendable, Hashable, Identifiable {
    public var id: Int64
    public var score: Int
    public var editable: Bool
    public var voteUpAble: Bool
    public var voteUpEd: Bool
    public var voteDownAble: Bool
    public var voteDownEd: Bool
    public var voteState: String?
    /// 毫秒时间戳
    public var time: Int64
    public var user: String?
    /// HTML 片段（评论正文保留原始 HTML，由 UI 层渲染）
    public var comment: String
    /// 毫秒时间戳，0 = 未编辑
    public var lastEdited: Int64

    public init(
        id: Int64 = 0, score: Int = 0, editable: Bool = false, voteUpAble: Bool = false,
        voteUpEd: Bool = false, voteDownAble: Bool = false, voteDownEd: Bool = false,
        voteState: String? = nil, time: Int64 = 0, user: String? = nil, comment: String = "",
        lastEdited: Int64 = 0
    ) {
        self.id = id; self.score = score; self.editable = editable; self.voteUpAble = voteUpAble
        self.voteUpEd = voteUpEd; self.voteDownAble = voteDownAble; self.voteDownEd = voteDownEd
        self.voteState = voteState; self.time = time; self.user = user; self.comment = comment
        self.lastEdited = lastEdited
    }

    /// id 为 0 表示上传者评论（不可投票）
    public var isUploaderComment: Bool { id == 0 }
}

public struct GalleryCommentList: Codable, Sendable, Hashable {
    public var comments: [GalleryComment]
    public var hasMore: Bool
    public init(comments: [GalleryComment] = [], hasMore: Bool = false) {
        self.comments = comments
        self.hasMore = hasMore
    }
}

/// 单个预览缩略图。合并了 Android `NormalPreviewSet`（雪碧图裁剪）与 `LargePreviewSet`（大图）
public struct GalleryPreview: Codable, Sendable, Hashable {
    /// 页序号，从 0 开始
    public var position: Int
    public var imageUrl: String
    public var pageUrl: String
    /// 雪碧图裁剪区域；nil 表示大图预览、无需裁剪
    public var clip: Clip?

    public struct Clip: Codable, Sendable, Hashable {
        public var x: Int
        public var y: Int
        public var width: Int
        public var height: Int
        public init(x: Int, y: Int, width: Int, height: Int) {
            self.x = x; self.y = y; self.width = width; self.height = height
        }
    }

    public init(position: Int, imageUrl: String, pageUrl: String, clip: Clip? = nil) {
        self.position = position
        self.imageUrl = imageUrl
        self.pageUrl = pageUrl
        self.clip = clip
    }
}

/// 一页预览。对应 Android `PreviewSet`
public struct PreviewSet: Codable, Sendable, Hashable {
    public var isLarge: Bool
    public var items: [GalleryPreview]
    public init(isLarge: Bool, items: [GalleryPreview] = []) {
        self.isLarge = isLarge
        self.items = items
    }

    /// 对应 `PreviewSet.size()`
    public var count: Int { items.count }
    public var isEmpty: Bool { items.isEmpty }
    /// 对应 `getPosition(index)`
    public func position(at index: Int) -> Int { items[index].position }
    /// 对应 `getPageUrlAt(index)`
    public func pageUrl(at index: Int) -> String { items[index].pageUrl }

    /// 对应 `NormalPreviewSet.addItem`：雪碧图裁剪预览
    public mutating func addNormalItem(position: Int, imageUrl: String, xOffset: Int, yOffset: Int, width: Int, height: Int, pageUrl: String) {
        items.append(GalleryPreview(
            position: position, imageUrl: imageUrl, pageUrl: pageUrl,
            clip: .init(x: xOffset, y: yOffset, width: width, height: height)
        ))
    }

    /// 对应 `LargePreviewSet.addItem`：大图预览
    public mutating func addLargeItem(position: Int, imageUrl: String, pageUrl: String) {
        items.append(GalleryPreview(position: position, imageUrl: imageUrl, pageUrl: pageUrl))
    }
}

/// 画廊新版本。对应 `NewVersion`
public struct GalleryNewVersion: Codable, Sendable, Hashable {
    public var versionUrl: String
    public var versionName: String
    public init(versionUrl: String, versionName: String) {
        self.versionUrl = versionUrl
        self.versionName = versionName
    }
}

/// 详情页。对应 Android `GalleryDetail extends GalleryInfo`（这里改为组合）
public struct GalleryDetail: Codable, Sendable, Hashable {
    public var info: GalleryInfo
    public var apiUid: Int64 = -1
    public var apiKey: String?
    public var torrentCount: Int = 0
    public var torrentUrl: String?
    public var archiveUrl: String?
    public var parent: String?
    public var visible: String?
    public var language: String?
    public var size: String?
    public var favoriteCount: Int = 0
    public var isFavorited: Bool = false
    public var ratingCount: Int = 0
    public var tags: [GalleryTagGroup] = []
    public var comments: GalleryCommentList = .init()
    /// 预览总页数
    public var previewPages: Int = 0
    public var previewSet: PreviewSet?
    public var newVersions: [GalleryNewVersion] = []
    /// 以下三个字段用正则（而非 DOM）从同一页面解析，供 SpiderInfo 使用。对应 Java `SpiderInfoPages` 等
    public var spiderInfoPages: Int = 0
    public var spiderInfoPreviewPages: Int = 0
    public var spiderInfoPreviewSet: PreviewSet?

    public init(info: GalleryInfo) {
        self.info = info
    }

    private enum CodingKeys: String, CodingKey {
        case info, apiUid, apiKey, torrentCount, torrentUrl, archiveUrl, parent, visible, language, size
        case favoriteCount, isFavorited, ratingCount, tags, comments, previewPages, previewSet, newVersions
        case spiderInfoPages, spiderInfoPreviewPages, spiderInfoPreviewSet
    }

    /// 缺失字段使用默认值，保证旧版本编码的数据仍可解码
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        info = try c.decode(GalleryInfo.self, forKey: .info)
        apiUid = try c.decodeIfPresent(Int64.self, forKey: .apiUid) ?? -1
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey)
        torrentCount = try c.decodeIfPresent(Int.self, forKey: .torrentCount) ?? 0
        torrentUrl = try c.decodeIfPresent(String.self, forKey: .torrentUrl)
        archiveUrl = try c.decodeIfPresent(String.self, forKey: .archiveUrl)
        parent = try c.decodeIfPresent(String.self, forKey: .parent)
        visible = try c.decodeIfPresent(String.self, forKey: .visible)
        language = try c.decodeIfPresent(String.self, forKey: .language)
        size = try c.decodeIfPresent(String.self, forKey: .size)
        favoriteCount = try c.decodeIfPresent(Int.self, forKey: .favoriteCount) ?? 0
        isFavorited = try c.decodeIfPresent(Bool.self, forKey: .isFavorited) ?? false
        ratingCount = try c.decodeIfPresent(Int.self, forKey: .ratingCount) ?? 0
        tags = try c.decodeIfPresent([GalleryTagGroup].self, forKey: .tags) ?? []
        comments = try c.decodeIfPresent(GalleryCommentList.self, forKey: .comments) ?? .init()
        previewPages = try c.decodeIfPresent(Int.self, forKey: .previewPages) ?? 0
        previewSet = try c.decodeIfPresent(PreviewSet.self, forKey: .previewSet)
        newVersions = try c.decodeIfPresent([GalleryNewVersion].self, forKey: .newVersions) ?? []
        spiderInfoPages = try c.decodeIfPresent(Int.self, forKey: .spiderInfoPages) ?? 0
        spiderInfoPreviewPages = try c.decodeIfPresent(Int.self, forKey: .spiderInfoPreviewPages) ?? 0
        spiderInfoPreviewSet = try c.decodeIfPresent(PreviewSet.self, forKey: .spiderInfoPreviewSet)
    }

    /// 对应 `getUpdateVersionName`
    public var updateVersionNames: [String] { newVersions.map(\.versionName) }

    public var gid: Int64 { info.gid }
    public var token: String { info.token }

    /// 对应 `getNewGalleryDetail`：用新版本 URL（.../g/{gid}/{token}/）构造新画廊的基本信息
    public func info(forNewVersion index: Int) -> GalleryInfo? {
        guard newVersions.indices.contains(index) else { return nil }
        let parts = newVersions[index].versionUrl.split(separator: "/").map(String.init)
        guard parts.count >= 2, let gid = Int64(parts[parts.count - 2]) else { return nil }
        var n = info
        n.gid = gid
        n.token = parts[parts.count - 1]
        return n
    }
}
