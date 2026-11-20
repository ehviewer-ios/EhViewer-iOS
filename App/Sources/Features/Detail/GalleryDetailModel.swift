import SwiftUI
import EhCore
import EhNetwork
import EhStorage
import EhSpider

/// 画廊详情页状态。对应 Android `GalleryDetailScene` 中的数据与请求部分
@MainActor @Observable
final class GalleryDetailModel {
    let gid: Int64
    private(set) var token: String
    /// 列表传入的信息（详情加载前先显示头部）
    private(set) var listInfo: GalleryInfo?
    private(set) var detail: GalleryDetail?
    private(set) var isLoading = false
    private(set) var error: Error?
    /// 用户已确认查看 offensive 内容
    private(set) var allowOffensive = false

    // 收藏状态
    private(set) var isLocalFavorite = false
    private(set) var cloudFavorited = false
    /// 云收藏夹编号；已收藏但无法确定编号时为 nil
    private(set) var cloudSlot: Int?
    private(set) var cloudFavName: String?
    private(set) var isModifyingFavorite = false

    /// 阅读进度（从 0 开始的页码）；0 或 nil 表示没有进度
    private(set) var readProgress: Int?

    private var historyWritten = false
    private var didSetup = false

    init(info: GalleryInfo) {
        gid = info.gid
        token = info.token
        listInfo = info
        if (0...9).contains(info.favoriteSlot) {
            cloudFavorited = true
            cloudSlot = info.favoriteSlot
            cloudFavName = info.favoriteName
        }
    }

    init(gid: Int64, token: String) {
        self.gid = gid
        self.token = token
    }

    /// 当前用于显示的画廊信息（详情优先）
    var info: GalleryInfo? { detail?.info ?? listInfo }

    var isFavorited: Bool { isLocalFavorite || cloudFavorited }

    /// 是否可调用需要 apiuid/apikey 的接口（评分、评论投票等）
    var canUseAPI: Bool {
        guard let d = detail else { return false }
        return d.apiUid >= 0 && !(d.apiKey ?? "").isEmpty
    }

    func galleryURL(site: EhSite) -> String {
        EhURL.galleryDetail(site, gid: gid, token: token)
    }

    // MARK: - 加载

    /// 首次出现时调用：写历史、读取本地状态、加载详情
    func setup(_ app: AppModel) async {
        refreshLocalState(app)
        if !didSetup {
            didSetup = true
            if let info = listInfo { writeHistory(info, app) }
        }
        if detail == nil && !isLoading {
            await load(app)
        }
    }

    func load(_ app: AppModel) async {
        isLoading = true
        defer { isLoading = false }
        var url = galleryURL(site: app.site)
        if allowOffensive { url += (url.contains("?") ? "&" : "?") + "nw=session" }
        do {
            var d = try await app.api.getGalleryDetail(url: url)
            merge(&d)
            applyFavorite(from: d, favCat: app.settings.favCat)
            d.info.favoriteSlot = cloudFavorited ? (cloudSlot ?? -2) : -1
            detail = d
            token = d.token.isEmpty ? token : d.token
            error = nil
            writeHistory(d.info, app)
            app.downloadTags.record(gid: d.gid, groups: d.tags, isDownloaded: app.downloads.containDownloadInfo(d.gid))
            refreshLocalState(app)
        } catch {
            if Self.isCancellation(error) { return }
            if detail == nil {
                self.error = error
            } else {
                app.toast.error(error)
            }
        }
    }

    func confirmOffensive(_ app: AppModel) async {
        allowOffensive = true
        error = nil
        await load(app)
    }

    /// 详情缺少而列表有的字段补回；生成 simpleTags/simpleLanguage 便于写历史
    private func merge(_ d: inout GalleryDetail) {
        if (d.info.thumb ?? "").isEmpty { d.info.thumb = listInfo?.thumb }
        if d.info.thumbWidth == 0, let l = listInfo {
            d.info.thumbWidth = l.thumbWidth
            d.info.thumbHeight = l.thumbHeight
        }
        if d.info.simpleTags == nil {
            d.info.simpleTags = d.tags.flatMap { g in g.tags.map { "\(g.groupName):\($0)" } }
        }
        if d.info.simpleLanguage == nil { d.info.generateSimpleLanguage() }
        if d.info.simpleLanguage == nil { d.info.simpleLanguage = listInfo?.simpleLanguage }
        if !d.info.rated, let l = listInfo { d.info.rated = l.rated }
        d.info.disowned = d.info.disowned || (listInfo?.disowned ?? false)
    }

    private func applyFavorite(from d: GalleryDetail, favCat: [String]) {
        cloudFavorited = d.isFavorited
        cloudFavName = d.info.favoriteName
        if d.isFavorited {
            if let name = d.info.favoriteName, let i = favCat.firstIndex(of: name) {
                cloudSlot = i
            } else if let s = listInfo?.favoriteSlot, (0...9).contains(s) {
                cloudSlot = s
            } else {
                cloudSlot = nil
            }
        } else {
            cloudSlot = nil
        }
    }

    private func writeHistory(_ info: GalleryInfo, _ app: AppModel) {
        guard info.gid > 0, !info.token.isEmpty else { return }
        // putHistoryInfo 对已存在的记录只刷新时间；详情加载后再写一次以补全信息
        if historyWritten {
            try? app.database.putHistoryInfo(info)
            return
        }
        historyWritten = true
        try? app.database.putHistoryInfo(info)
    }

    /// 本地收藏、阅读进度
    func refreshLocalState(_ app: AppModel) {
        isLocalFavorite = (try? app.database.containLocalFavorites(gid: gid)) ?? false
        let gid = gid
        Task { [weak self] in
            self?.readProgress = await app.readProgress(gid: gid)
        }
    }

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if case EhError.cancelled = error { return true }
        return false
    }

    // MARK: - 收藏（对应 CommonOperations.addToFavorites / removeFromFavorites）

    /// slot：-1 本地收藏，0~9 云收藏夹。成功时只给触感（收藏按钮状态即结果）；
    /// 返回失败原因。showErrorToast 为 false 时由调用方（收藏 sheet）就地呈现错误
    @discardableResult
    func addFavorite(slot: Int, note: String?, _ app: AppModel, showErrorToast: Bool = true) async -> Error? {
        guard let gi = info, !isModifyingFavorite else { return nil }
        isModifyingFavorite = true
        defer { isModifyingFavorite = false }
        if slot == -1 {
            do {
                try app.database.putLocalFavorite(gi)
                isLocalFavorite = true
                Haptics.success()
                return nil
            } catch {
                Haptics.error()
                if showErrorToast { app.toast.error(error) }
                return error
            }
        }
        guard (0...9).contains(slot) else { return nil }
        do {
            let trimmed = note.map { String($0.prefix(250)) }
            try await app.api.addFavorites(gid: gid, token: token, dstCat: slot, note: trimmed)
            let name = app.settings.favCat[slot]
            cloudFavorited = true
            cloudSlot = slot
            cloudFavName = name
            detail?.isFavorited = true
            detail?.info.favoriteSlot = slot
            detail?.info.favoriteName = name
            Haptics.success()
            return nil
        } catch {
            if Self.isCancellation(error) { return nil }
            Haptics.error()
            if showErrorToast {
                app.toast.show("收藏失败：\(error.localizedDescription)", systemImage: "exclamationmark.circle")
            }
            return error
        }
    }

    func removeFavorite(_ app: AppModel) async {
        guard !isModifyingFavorite else { return }
        isModifyingFavorite = true
        defer { isModifyingFavorite = false }
        if isLocalFavorite {
            try? app.database.removeLocalFavorites(gid: gid)
            isLocalFavorite = false
        }
        if cloudFavorited {
            do {
                try await app.api.addFavorites(gid: gid, token: token, dstCat: -1)
                cloudFavorited = false
                cloudSlot = nil
                cloudFavName = nil
                detail?.isFavorited = false
                detail?.info.favoriteSlot = -1
                detail?.info.favoriteName = nil
            } catch {
                if !Self.isCancellation(error) {
                    Haptics.error()
                    app.toast.show("移除收藏失败：\(error.localizedDescription)", systemImage: "exclamationmark.circle")
                }
                return
            }
        }
        Haptics.success()
    }

    /// 当前收藏的显示名
    func favoriteDisplayName(_ app: AppModel) -> String? {
        if cloudFavorited {
            if let s = cloudSlot { return app.setting(\.favCat)[s] }
            return cloudFavName ?? "已收藏"
        }
        if isLocalFavorite { return "本地收藏" }
        return nil
    }

    // MARK: - 评分

    /// 评分。成功只给触感（评分区即结果）；失败抛出，由评分 sheet 就地呈现
    func rate(_ rating: Float, _ app: AppModel) async throws {
        guard let d = detail, canUseAPI else { throw DetailActionError.signInRequired }
        let r = try await app.api.rateGallery(apiUid: d.apiUid, apiKey: d.apiKey ?? "", gid: gid, token: token, rating: rating)
        detail?.info.rating = r.rating
        detail?.ratingCount = r.ratingCount
        detail?.info.rated = true
        Haptics.success()
    }

    // MARK: - 其他

    /// 评论页返回后同步评论（评论页可能有新评论）
    func updateComments(_ list: GalleryCommentList) {
        detail?.comments = list
    }

    /// 对应 `showSimilarGalleryList`：标题关键词 → 作者 tag → 上传者
    func similarBuilder() -> ListUrlBuilder? {
        guard let gi = info else { return nil }
        if let keyword = EhUtils.extractTitle(gi.title) {
            return ListUrlBuilder(mode: .normal, keyword: "\"" + keyword + "\"")
        }
        if let artist = detail?.tags.first(where: { $0.groupName == "artist" })?.tags.first {
            return ListUrlBuilder(mode: .tag, keyword: "artist:" + artist)
        }
        if let uploader = gi.uploader, !uploader.isEmpty {
            return .uploader(uploader)
        }
        return nil
    }

    /// 对应 `showCoverGalleryList`：下载封面到临时文件后以图搜图
    func coverSearchBuilder(_ app: AppModel) async -> ListUrlBuilder? {
        guard let thumb = info?.thumb, !thumb.isEmpty else { return nil }
        do {
            let data = try await app.api.client.fetchData(thumb, referer: app.site.referer)
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cover-search", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("\(gid).jpg")
            try data.write(to: file)
            var b = ListUrlBuilder(mode: .imageSearch)
            b.imagePath = file.path
            b.useSimilarityScan = true
            b.showExpunged = true
            return b
        } catch {
            if !Self.isCancellation(error) { app.toast.error(error) }
            return nil
        }
    }
}

// MARK: - 错误

enum DetailActionError: LocalizedError {
    case signInRequired

    var errorDescription: String? {
        switch self {
        case .signInRequired: return "需要登录后才能使用此功能。"
        }
    }
}

// MARK: - 文案

enum DetailText {
    /// 对应 Android `getRatingText`（R.string.rating0~10）
    static func ratingText(_ rating: Float) -> String {
        guard rating >= 0 else { return "暂无评分" }
        switch Int((rating * 2).rounded()) {
        case 0: return "…"
        case 1: return "快要窒息了"
        case 2: return "瞎眼"
        case 3: return "糟糕"
        case 4: return "不行"
        case 5: return "一般般"
        case 6: return "还行"
        case 7: return "不错"
        case 8: return "很棒"
        case 9: return "好极了"
        case 10: return "根本把持不住"
        default: return "暂无评分"
        }
    }
}

// MARK: - 剪贴板

@MainActor
enum DetailClipboard {
    static func copy(_ text: String, _ app: AppModel, message: String = "已复制到剪贴板") {
        UIPasteboard.general.string = text
        app.toast.show(message, systemImage: "doc.on.doc")
    }
}
