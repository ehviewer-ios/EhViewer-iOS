import Foundation
import EhCore
import EhNetwork
import EhStorage

/// 批量操作的目标
enum FavoriteDestination: Hashable {
    /// 删除（云端为 favdel，本地为移出数据库）
    case delete
    case local
    case cloud(Int)
}

/// 收藏列表的加载、分页与批量修改。对应 Android `FavoritesScene`（FavoritesAdapter / ContentHelper / Move/DeleteDialogHelper）。
/// - 云端收藏：新版游标分页（prev/next href），兼容旧版页码分页
/// - 本地收藏：订阅数据库 `observeLocalFavorites`，搜索在内存中过滤（标题 / 日文标题 / 上传者）
@MainActor @Observable
final class FavoritesModel {
    enum Phase: Equatable { case idle, loading, loaded, failed }

    static let all = FavListUrlBuilder.FAV_CAT_ALL
    static let local = FavListUrlBuilder.FAV_CAT_LOCAL

    /// -1 全部，0..9 云端收藏夹，-2 本地收藏
    private(set) var favCat: Int = FavoritesModel.all
    /// 云端搜索关键词
    private(set) var keyword: String?
    /// 本地收藏的过滤文本（输入即过滤）
    var localFilter = ""

    private(set) var items: [GalleryInfo] = []
    private(set) var localItems: [GalleryInfo] = []
    private(set) var localLoaded = false
    private(set) var phase: Phase = .idle
    private(set) var lastError: Error?
    private(set) var footer: LoadMoreFooter.State = .idle
    private(set) var isLoadingPrevious = false
    /// 正在执行批量移动 / 删除
    private(set) var isModifying = false
    /// 排序："f" 收藏时间 / "p" 发布时间（来自页面）
    private(set) var favOrder: String?
    private(set) var resultCount: String?

    /// 10 个收藏夹名称与数量（来自站点，同步写回设置）
    private(set) var catNames: [String] = (0..<10).map { "Favorites \($0)" }
    private(set) var counts: [Int] = Array(repeating: 0, count: 10)

    private(set) var pages = 0
    private var firstPage = 0
    private var lastPage = 0
    private var firstHrefs = ListPageHrefs()
    private var lastHrefs = ListPageHrefs()

    @ObservationIgnored private var app: AppModel?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var loadingMore = false
    @ObservationIgnored private var started = false
    @ObservationIgnored private var gids: Set<Int64> = []
    @ObservationIgnored private var localTask: Task<Void, Never>?

    // MARK: 状态

    var isLocal: Bool { favCat == Self.local }

    var builder: FavListUrlBuilder {
        FavListUrlBuilder(index: 0, keyword: keyword, favCat: favCat)
    }

    /// 当前显示的条目
    var visibleItems: [GalleryInfo] {
        guard isLocal else { return items }
        let q = localFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return localItems }
        return localItems.filter { info in
            [info.title, info.titleJpn, info.uploader].contains { $0?.localizedCaseInsensitiveContains(q) ?? false }
        }
    }

    var localCount: Int { localItems.count }
    var cloudCount: Int { counts.reduce(0, +) }

    var isNewStylePaging: Bool { pages == -1 }

    var hasMore: Bool {
        if pages == -1 { return !(lastHrefs.nextHref ?? "").isEmpty }
        return lastPage + 1 < pages
    }

    var canLoadPrevious: Bool {
        if pages == -1 { return !(firstHrefs.prevHref ?? "").isEmpty }
        return firstPage > 0
    }

    /// 可以按日期跳转（新版分页且不止一页）
    var canJump: Bool {
        !isLocal && phase == .loaded && pages == -1
            && (!(lastHrefs.nextHref ?? "").isEmpty || !(firstHrefs.prevHref ?? "").isEmpty)
    }

    func name(of cat: Int) -> String {
        switch cat {
        case Self.all: return "全部收藏"
        case Self.local: return "本地收藏"
        default: return catNames.indices.contains(cat) ? catNames[cat] : "Favorites \(cat)"
        }
    }

    func count(of cat: Int) -> Int {
        switch cat {
        case Self.all: return cloudCount
        case Self.local: return localCount
        default: return counts.indices.contains(cat) ? counts[cat] : 0
        }
    }

    // MARK: 启动 / 切换

    func start(_ model: AppModel) {
        app = model
        guard !started else { return }
        started = true
        catNames = model.settings.favCat
        counts = model.settings.favCount
        let recent = model.settings.recentFavCat
        favCat = (recent == Self.local || recent == Self.all || (0...9).contains(recent)) ? recent : Self.all
        observeLocal()
        if !isLocal { Task { await refresh() } }
    }

    /// 切换收藏夹
    func select(_ cat: Int) {
        guard cat != favCat else { return }
        favCat = cat
        app?.settings.recentFavCat = cat
        keyword = nil
        localFilter = ""
        resetContent()
        if !isLocal { Task { await refresh() } }
    }

    /// 云端搜索（空字符串清除搜索）
    func search(_ text: String?) {
        let q = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let new = (q?.isEmpty ?? true) ? nil : q
        if isLocal {
            localFilter = new ?? ""
            return
        }
        guard new != keyword else { return }
        keyword = new
        resetContent()
        Task { await refresh() }
    }

    func refresh() async {
        guard !isLocal else { return }
        await runDetached { await self.loadFirst(url: nil, page: 0) }
    }

    /// 修改排序：收藏时间（"f"）/ 发布时间（"p"）。对应 `FavoriteListSortDialog`（`inline_set=fs_f|fs_p`）
    func setOrder(_ order: String) {
        guard let app, !isLocal, order != favOrder else { return }
        let url = Self.append(builder.build(site: app.site), "inline_set=fs_\(order)")
        resetContent()
        Task { await runDetached { await self.loadFirst(url: url, page: 0) } }
    }

    /// 按日期跳转（seek=yyyy-mm-dd）。对应 `onTimeSelected`
    func jump(to date: Date) {
        guard let app, !isLocal else { return }
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let param = "seek=" + f.string(from: date)
        let url: String
        if let next = lastHrefs.nextHref, !next.isEmpty {
            url = builder.jumpHrefBuild(next, appendParam: param)
        } else {
            url = Self.append(builder.build(site: app.site), param)
        }
        resetContent()
        Task { await runDetached { await self.loadFirst(url: url, page: 0) } }
    }

    func loadMore() {
        guard !isLocal, phase == .loaded, !loadingMore, hasMore else { return }
        if case .failed = footer { return }
        loadingMore = true
        footer = .loading
        let gen = generation
        Task { await loadNext(gen: gen) }
    }

    func retryLoadMore() {
        footer = .idle
        loadMore()
    }

    func loadPrevious() {
        guard let app, !isLocal, phase == .loaded, !isLoadingPrevious, canLoadPrevious else { return }
        isLoadingPrevious = true
        let gen = generation
        Task {
            defer { if gen == generation { isLoadingPrevious = false } }
            let url: String
            if pages == -1 {
                url = firstHrefs.prevHref ?? ""
            } else {
                var b = builder
                b.index = firstPage - 1
                url = b.build(site: app.site)
            }
            do {
                let r = try await app.api.getFavorites(url: url)
                guard gen == generation else { return }
                apply(r, kind: .prepend, page: firstPage - 1)
            } catch {
                guard gen == generation, !(error is CancellationError) else { return }
                app.toast.error(error)
            }
        }
    }

    // MARK: 条目更新

    /// 长按菜单改变了收藏状态
    func favoriteChanged(gid: Int64, slot: Int, name: String?) {
        guard !isLocal, let i = items.firstIndex(where: { $0.gid == gid }) else { return }
        // 不再属于当前收藏夹：移出列表
        if slot < 0 || (favCat >= 0 && slot != favCat) {
            items.remove(at: i)
            gids.remove(gid)
        } else {
            items[i].favoriteSlot = slot
            items[i].favoriteName = name
        }
    }

    // MARK: 批量修改

    /// 移动或删除。对应 `MoveDialogHelper` / `DeleteDialogHelper` + `getExPageData` 中的 modify 分支
    func modify(_ targets: [GalleryInfo], to dst: FavoriteDestination) async {
        guard let app, !targets.isEmpty, !isModifying else { return }
        if case let .cloud(n) = dst, n == favCat { return }
        if dst == .local, isLocal { return }
        isModifying = true
        defer { isModifying = false }
        let ids = targets.map(\.gid)
        do {
            if isLocal {
                switch dst {
                case .delete:
                    try app.database.removeLocalFavorites(gids: ids)
                    Haptics.success() // 条目从列表消失，无需提示
                case let .cloud(n):
                    guard app.isSignedIn else { throw EhError.notSignedIn }
                    try await app.api.addFavoritesRange(gids: ids, tokens: targets.map(\.token), dstCat: n)
                    try app.database.removeLocalFavorites(gids: ids)
                    app.toast.show("已移动到 \(name(of: n))", systemImage: "folder")
                case .local:
                    break
                }
                return
            }
            let url = builder.build(site: app.site)
            let result: FavoritesParser.Result
            switch dst {
            case .delete:
                result = try await app.api.modifyFavorites(url: url, gids: ids, dstCat: -1)
                Haptics.success() // 条目从列表消失，无需提示
            case .local:
                try app.database.putLocalFavorites(targets)
                result = try await app.api.modifyFavorites(url: url, gids: ids, dstCat: -1)
                app.toast.show("已移动到本地收藏", systemImage: "iphone")
            case let .cloud(n):
                result = try await app.api.modifyFavorites(url: url, gids: ids, dstCat: n)
                app.toast.show("已移动到 \(name(of: n))", systemImage: "folder")
            }
            generation += 1
            apply(result, kind: .replace, page: 0)
        } catch {
            guard !(error is CancellationError) else { return }
            app.toast.show("操作失败：\(error.localizedDescription)", systemImage: "exclamationmark.circle")
        }
    }

    // MARK: 内部

    private enum ApplyKind { case replace, append, prepend }

    private static func append(_ url: String, _ param: String) -> String {
        url + (url.contains("?") ? "&" : "?") + param
    }

    private func observeLocal() {
        guard let app else { return }
        localTask?.cancel()
        let db = app.database
        localTask = Task { [weak self] in
            do {
                for try await list in db.observeLocalFavorites() {
                    guard let self else { return }
                    self.localItems = list.map { record in
                        var gi = record.galleryInfo
                        gi.favoriteSlot = -1
                        gi.favoriteName = "本地收藏"
                        return gi
                    }
                    self.localLoaded = true
                    if self.app?.settings.favLocalCount != list.count {
                        self.app?.settings.favLocalCount = list.count
                    }
                }
            } catch {
                self?.localLoaded = true
            }
        }
    }

    private func resetContent() {
        generation += 1
        items = []
        gids = []
        phase = .idle
        footer = .idle
        resultCount = nil
        loadingMore = false
        isLoadingPrevious = false
        pages = 0
        firstHrefs = ListPageHrefs()
        lastHrefs = ListPageHrefs()
    }

    /// 在非结构化任务中执行，避免 `.refreshable` 的任务被取消导致请求中断
    private func runDetached(_ work: @escaping @MainActor () async -> Void) async {
        await Task { @MainActor in await work() }.value
    }

    private func loadFirst(url: String?, page: Int) async {
        guard let app, !isLocal else { return }
        generation += 1
        let gen = generation
        loadingMore = false
        guard app.isSignedIn else {
            // 未登录：不请求，界面显示登录提示
            items = []
            lastError = EhError.notSignedIn
            phase = .failed
            return
        }
        if items.isEmpty { phase = .loading }
        do {
            let r = try await app.api.getFavorites(url: url ?? builder.build(site: app.site))
            guard gen == generation else { return }
            apply(r, kind: .replace, page: page)
        } catch {
            guard gen == generation, !(error is CancellationError) else { return }
            lastError = error
            if items.isEmpty {
                phase = .failed
            } else {
                app.toast.error(error)
            }
        }
    }

    private func loadNext(gen: Int) async {
        guard let app else { return }
        let page = lastPage + 1
        let url: String
        if pages == -1 {
            url = lastHrefs.nextHref ?? ""
        } else {
            var b = builder
            b.index = page
            url = b.build(site: app.site)
        }
        do {
            let r = try await app.api.getFavorites(url: url)
            guard gen == generation else { return }
            apply(r, kind: .append, page: page)
            loadingMore = false
            if r.galleryInfoList.isEmpty, pages != -1 {
                pages = lastPage + 1
                footer = .end
            }
        } catch {
            guard gen == generation else { return }
            loadingMore = false
            footer = error is CancellationError ? .idle : .failed(error.localizedDescription)
        }
    }

    private func apply(_ r: FavoritesParser.Result, kind: ApplyKind, page: Int) {
        updateFolders(r)
        if let order = r.favOrder, !order.isEmpty { favOrder = order }
        if let c = r.resultCount, !c.isEmpty { resultCount = c }

        if kind == .replace { gids = [] }
        var fresh: [GalleryInfo] = []
        for gi in r.galleryInfoList where !gids.contains(gi.gid) {
            gids.insert(gi.gid)
            fresh.append(gi)
        }
        switch kind {
        case .replace:
            pages = r.pages
            items = fresh
            firstHrefs = r.hrefs
            lastHrefs = r.hrefs
            firstPage = page
            lastPage = page
        case .append:
            if r.pages != 0 { pages = r.pages }
            items.append(contentsOf: fresh)
            lastHrefs = r.hrefs
            lastPage = page
        case .prepend:
            items.insert(contentsOf: fresh, at: 0)
            firstHrefs = r.hrefs
            firstPage = page
        }
        phase = .loaded
        lastError = nil
        footer = hasMore ? .idle : .end
    }

    /// 收藏夹名称与数量写回设置。对应 `onGetFavoritesSuccess`
    private func updateFolders(_ r: FavoritesParser.Result) {
        guard let app, r.catArray.count == 10, r.countArray.count == 10 else { return }
        let namesChanged = r.catArray != catNames
        catNames = r.catArray
        counts = r.countArray
        app.settings.favCount = r.countArray
        app.settings.favCloudCount = r.countArray.reduce(0, +)
        if namesChanged {
            app.settings.favCat = r.catArray
            // 让读取收藏夹名的视图（长按菜单等）刷新
            app.settingsDidChange()
        }
    }
}
