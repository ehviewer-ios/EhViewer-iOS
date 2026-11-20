import Foundation
import EhCore
import EhNetwork
import EhStorage

/// 画廊列表的加载与分页。对应 Android `GalleryListScene.GalleryListHelper` + `GalleryInfoContentHelper`。
/// 同时兼容旧版页码分页（ptt，`pages > 0`）与新版游标分页（searchnav，`pages == -1`，使用 prev/next href）。
@MainActor @Observable
final class GalleryListModel {
    enum Phase: Equatable { case idle, loading, loaded, failed }

    /// 视图初始的列表条件（搜索/筛选可以回到这里）
    let base: ListUrlBuilder
    /// 当前生效的列表条件
    private(set) var builder: ListUrlBuilder

    private(set) var items: [GalleryInfo] = []
    private(set) var phase: Phase = .idle
    private(set) var lastError: Error?
    private(set) var footer: LoadMoreFooter.State = .idle
    private(set) var isLoadingPrevious = false
    private(set) var emptyMessage = "没有找到画廊"
    /// 搜索结果数（新版页面），如 "1,000+"
    private(set) var resultCount: String?

    /// 旧版分页总页数；新版游标分页为 -1；无结果为 0
    private(set) var pages = 0
    /// 旧版分页：当前已加载的第一页与最后一页（从 0 开始）
    private(set) var firstPage = 0
    private(set) var lastPage = 0
    /// 新版分页：第一段与最后一段页面给出的游标
    private var firstHrefs = ListPageHrefs()
    private var lastHrefs = ListPageHrefs()

    /// 列表实例标识，用作列表行导航值的来源（见 `Route.gallery`）
    @ObservationIgnored let listID = UUID()
    @ObservationIgnored private var app: AppModel?
    @ObservationIgnored private var gids: Set<Int64> = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var loadingMore = false
    @ObservationIgnored private var started = false

    init(builder: ListUrlBuilder) {
        base = builder
        self.builder = builder
    }

    // MARK: 状态

    var isNewStylePaging: Bool { pages == -1 }

    var hasMore: Bool {
        if pages == -1 { return !(lastHrefs.nextHref ?? "").isEmpty }
        if builder.mode == .imageSearch || builder.mode == .whatsHot { return false }
        return lastPage + 1 < pages
    }

    var canLoadPrevious: Bool {
        if pages == -1 { return !(firstHrefs.prevHref ?? "").isEmpty }
        return firstPage > 0
    }

    /// 是否可以跳页（旧版：多于一页；新版：有任何游标）
    var canJump: Bool {
        guard phase == .loaded, builder.mode != .imageSearch, builder.mode != .whatsHot else { return false }
        if pages == -1 {
            return !(lastHrefs.nextHref ?? "").isEmpty || !(firstHrefs.prevHref ?? "").isEmpty
        }
        return pages > 1
    }

    var canJumpToLast: Bool { pages == -1 && !(lastHrefs.lastHref ?? "").isEmpty }

    /// 是否偏离了初始条件（显示"重置"）
    var isModified: Bool { builder != base }

    /// 搜索框中显示的、与当前条件对应的搜索词（可直接在后面追加条件再搜索）
    var searchBarText: String { Self.searchBarText(for: builder) }

    /// 对应 Android `onUpdateUrlBuilder` 写入搜索栏的文字：标签、上传者转换为站点搜索语法，
    /// 如 `female:"big breasts$"`、`language:chinese$`、`uploader:"name"`；以图搜图、排行榜等为空
    static func searchBarText(for b: ListUrlBuilder) -> String {
        let keyword = (b.keyword ?? "").trimmingCharacters(in: .whitespaces)
        switch b.mode {
        case .normal, .subscription:
            return keyword
        case .tag:
            return TagSuggestionHelper.editableKeyword(forTag: keyword)
        case .uploader:
            guard !keyword.isEmpty else { return "" }
            return keyword.contains(" ") ? "uploader:\"\(keyword)\"" : "uploader:\(keyword)"
        default:
            return ""
        }
    }

    // MARK: 加载

    func start(_ model: AppModel) {
        app = model
        guard !started else { return }
        started = true
        Task { await refresh() }
    }

    /// 从头加载（下拉刷新 / 条件改变）
    func refresh() async {
        await runDetached { await self.loadFirst(url: nil, page: 0) }
    }

    /// 应用新的列表条件并重新加载
    func apply(_ newBuilder: ListUrlBuilder) {
        builder = newBuilder
        resetContent()
        Task { await refresh() }
    }

    func reset() {
        apply(base)
    }

    /// 搜索栏提交
    func search(_ text: String, scope: BrowseSearchScope) {
        // 对应 Android onApplySearch：过滤换行，避免影响搜索语法
        let q = text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var b: ListUrlBuilder
        switch scope {
        case .keyword:
            let source = keywordSearchBase()
            b = ListUrlBuilder()
            b.mode = base.mode == .subscription ? .subscription : .normal
            b.category = source.category
            b.advanceSearch = source.advanceSearch
            b.minRating = source.minRating
            b.pageFrom = source.pageFrom
            b.pageTo = source.pageTo
            b.keyword = q.isEmpty ? nil : q
        case .uploader:
            b = .uploader(q)
        case .tag:
            b = .tag(q)
        }
        apply(b)
    }

    /// 关键词/筛选可用的条件：上传者、tag 模式转换成普通搜索
    func keywordSearchBase() -> ListUrlBuilder {
        switch builder.mode {
        case .normal, .subscription:
            return builder
        case .uploader, .tag:
            var b = ListUrlBuilder()
            b.keyword = searchBarText
            return b
        default:
            return ListUrlBuilder()
        }
    }

    /// 是否支持分类/高级筛选
    var supportsFilter: Bool {
        [.normal, .subscription, .uploader, .tag].contains(builder.mode)
    }

    /// 滚动到底部附近时调用
    func loadMore() {
        guard phase == .loaded, !loadingMore, hasMore else { return }
        if case .failed = footer { return }
        loadingMore = true
        footer = .loading
        let gen = generation
        Task { await loadNext(gen: gen, autoContinue: 0) }
    }

    func retryLoadMore() {
        footer = .idle
        loadMore()
    }

    func loadPrevious() {
        guard phase == .loaded, !isLoadingPrevious, canLoadPrevious, let app else { return }
        isLoadingPrevious = true
        let gen = generation
        Task {
            defer { if gen == generation { isLoadingPrevious = false } }
            let url: String
            let page: Int
            if pages == -1 {
                url = firstHrefs.prevHref ?? ""
                page = firstPage - 1
            } else {
                var b = builder
                b.pageIndex = firstPage - 1
                url = b.build(site: app.site)
                page = firstPage - 1
            }
            do {
                let r = try await app.api.getGalleryList(url: url)
                guard gen == generation else { return }
                apply(result: r, kind: .prepend, page: page)
            } catch {
                guard gen == generation, !(error is CancellationError) else { return }
                app.toast.error(error)
            }
        }
    }

    /// 旧版分页：跳到第 page 页（从 0 开始）
    func jump(toPage page: Int) {
        guard let app else { return }
        var b = builder
        b.pageIndex = page
        let url = b.build(site: app.site)
        resetContent()
        Task { await runDetached { await self.loadFirst(url: url, page: page) } }
    }

    /// 新版分页：按日期（`seek=yyyy-mm-dd`）或时间跨度（`jump=1w` 等）跳转。对应 `onTimeSelected`
    func jump(appendParam: String) {
        guard let app, !appendParam.isEmpty else { return }
        let url: String
        if let next = lastHrefs.nextHref, !next.isEmpty {
            url = builder.jumpHrefBuild(next, appendParam: appendParam)
        } else {
            let u = builder.build(site: app.site)
            url = u + (u.contains("?") ? "&" : "?") + appendParam
        }
        resetContent()
        Task { await runDetached { await self.loadFirst(url: url, page: 0) } }
    }

    func jumpToLast() {
        guard let last = lastHrefs.lastHref, !last.isEmpty else { return }
        resetContent()
        Task { await runDetached { await self.loadFirst(url: last, page: 0) } }
    }

    // MARK: 条目更新

    func updateFavorite(gid: Int64, slot: Int, name: String?) {
        guard let i = items.firstIndex(where: { $0.gid == gid }) else { return }
        items[i].favoriteSlot = slot
        items[i].favoriteName = name
    }

    // MARK: 内部

    private enum ApplyKind { case replace, append, prepend }

    private func resetContent() {
        generation += 1
        items = []
        gids = []
        phase = .idle
        footer = .idle
        resultCount = nil
        loadingMore = false
        isLoadingPrevious = false
    }

    /// 在非结构化任务中执行，避免 `.refreshable` 的任务被取消导致请求中断
    private func runDetached(_ work: @escaping @MainActor () async -> Void) async {
        await Task { @MainActor in await work() }.value
    }

    private func loadFirst(url: String?, page: Int) async {
        guard let app else { return }
        generation += 1
        let gen = generation
        loadingMore = false
        if items.isEmpty { phase = .loading }
        do {
            let r: GalleryListParser.Result
            if url == nil, builder.mode == .imageSearch, let path = builder.imagePath {
                r = try await app.api.imageSearch(imageFile: URL(fileURLWithPath: path),
                                                  uss: builder.useSimilarityScan,
                                                  osc: builder.onlySearchCovers,
                                                  se: builder.showExpunged)
            } else {
                r = try await app.api.getGalleryList(url: url ?? builder.build(site: app.site))
            }
            guard gen == generation else { return }
            apply(result: r, kind: .replace, page: page)
            // 第一页被过滤器全部滤掉时自动加载后续页面
            if items.isEmpty, hasMore {
                loadingMore = true
                footer = .loading
                await loadNext(gen: gen, autoContinue: 1)
            }
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

    private func loadNext(gen: Int, autoContinue: Int) async {
        guard let app else { return }
        let url: String
        let page = lastPage + 1
        if pages == -1 {
            url = lastHrefs.nextHref ?? ""
        } else {
            var b = builder
            b.pageIndex = page
            url = b.build(site: app.site)
        }
        do {
            let r = try await app.api.getGalleryList(url: url)
            guard gen == generation else { return }
            let added = apply(result: r, kind: .append, page: page)
            loadingMore = false
            if r.galleryInfoList.isEmpty, pages != -1 {
                // 旧版分页返回空页，视为结束
                pages = lastPage + 1
                footer = .end
            }
            // 整页被过滤时继续加载，最多连续 5 次
            if added == 0, hasMore, autoContinue < 5 {
                loadingMore = true
                footer = .loading
                await loadNext(gen: gen, autoContinue: autoContinue + 1)
            }
        } catch {
            guard gen == generation else { return }
            loadingMore = false
            if error is CancellationError {
                footer = .idle
            } else {
                footer = .failed(error.localizedDescription)
            }
        }
    }

    @discardableResult
    private func apply(result r: GalleryListParser.Result, kind: ApplyKind, page: Int) -> Int {
        if let c = r.resultCount, !c.isEmpty { resultCount = c }
        if let custom = r.customErrorString {
            emptyMessage = custom
        } else if builder.mode == .subscription, r.noWatchedTags {
            emptyMessage = "还没有订阅任何标签"
        } else {
            emptyMessage = "没有找到画廊"
        }

        var fresh: [GalleryInfo] = []
        if kind == .replace { gids = [] }
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
        return fresh.count
    }
}
