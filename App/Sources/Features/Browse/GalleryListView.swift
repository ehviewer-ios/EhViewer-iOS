import SwiftUI
import EhCore
import EhStorage

/// 画廊列表（首页 / 订阅 / 热门 / 搜索 / 上传者 / 标签 / 以图搜图 / 排行榜完整榜单）。
/// 对应 Android `GalleryListScene`：搜索（带标签翻译建议与历史）、搜索范围、分类与高级搜索、以图搜图、
/// 快速搜索、跳页（页码 / 日期 seek）、列表/网格两种布局、长按菜单。
struct GalleryListView: View {
    let builder: ListUrlBuilder
    var title: String?

    @Environment(AppModel.self) private var model
    @Environment(\.navigate) private var navigate
    @State private var vm: GalleryListModel

    /// 搜索框。未在编辑时显示当前条件对应的搜索词（标签、上传者页为站点搜索语法），点按即可在此基础上修改；
    /// 滚动后搜索框收起，可用导航栏的搜索按钮打开
    @State private var search = SubmittedSearchState()

    @State private var scope: BrowseSearchScope = .keyword
    @State private var tagSuggestions: [TagSuggestion] = []
    @State private var suggestTask: Task<Void, Never>?

    @State private var sheet: SheetKind?
    @State private var confirmClearHistory = false

    private enum SheetKind: String, Identifiable {
        case filter, imageSearch, quickSearch, jump
        var id: String { rawValue }
    }

    init(builder: ListUrlBuilder, title: String? = nil) {
        self.builder = builder
        self.title = title
        _vm = State(initialValue: GalleryListModel(builder: builder))
    }

    var body: some View {
        content
            .overlay {
                if search.isPresented, BrowseSearchSuggestions.hasContent(text: search.text, tagSuggestions: tagSuggestions) {
                    BrowseSearchSuggestions(text: search.text, scope: scope, tagSuggestions: tagSuggestions,
                                            onOpenRoute: { open($0) },
                                            onSearch: { searchHistory($0) },
                                            onFillText: { search.text = $0 },
                                            onRequestClearHistory: { confirmClearHistory = true })
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .submittedSearch(search, committed: { vm.searchBarText },
                             prompt: model.site == .ex ? "搜索 ExHentai" : "搜索 E-Hentai",
                             onSubmit: { performSearch($0) },
                             onClear: { if vm.isModified { vm.reset() } },
                             onEdit: { updateTagSuggestions($0) },
                             onEndEditing: {
                                 suggestTask?.cancel()
                                 tagSuggestions = []
                             },
                             // 搜索范围回到“关键词”，便于在搜索词后面追加条件
                             onSync: { if scope != .keyword { scope = .keyword } })
            // 只在编辑时显示搜索范围（搜索框里有文字时系统默认也会显示）
            .searchScopes($scope, activation: .onSearchPresentation) {
                ForEach(BrowseSearchScope.allCases, id: \.self) { s in
                    Text(s.title).tag(s)
                }
            }
            .confirmationDialog("清除搜索历史？", isPresented: $confirmClearHistory, titleVisibility: .visible) {
                Button("清除搜索历史", role: .destructive) { SearchHistoryStore.shared.clear() }
            } message: {
                Text("将删除全部 \(SearchHistoryStore.shared.items.count) 条搜索记录，此操作无法撤销。")
            }
            .toolbar { toolbarContent }
            .sheet(item: $sheet) { kind in sheetView(kind) }
            .task { vm.start(model) }
            .onChange(of: model.site) { _, _ in
                Task { await vm.refresh() }
            }
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        if vm.items.isEmpty {
            switch vm.phase {
            case .idle, .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed:
                ScrollView {
                    VStack {
                        headerBar
                        ErrorStateView(error: vm.lastError ?? EhError.other("未知错误")) {
                            Task { await vm.refresh() }
                        }
                        .padding(.top, 60)
                    }
                }
                .refreshable { await vm.refresh() }
            case .loaded:
                ScrollView {
                    VStack {
                        headerBar
                        emptyResultView
                            .padding(.top, 60)
                        if vm.footer == .loading { ProgressView() }
                    }
                }
                .refreshable { await vm.refresh() }
            }
        } else if model.setting(\.listMode) == .thumb {
            gridView
        } else {
            listView
        }
    }

    /// 无结果：有关键词时按系统搜索无结果样式显示，条件被修改过时提供“重置条件”
    @ViewBuilder
    private var emptyResultView: some View {
        let keyword = vm.builder.keyword ?? ""
        let isSearch = vm.isModified && !keyword.isEmpty
            && (vm.builder.mode == .normal || vm.builder.mode == .subscription)
        ContentUnavailableView {
            if isSearch {
                Label("没有“\(keyword)”的结果", systemImage: "magnifyingglass")
            } else {
                Label(vm.emptyMessage, systemImage: "magnifyingglass")
            }
        } description: {
            if isSearch { Text("请检查拼写，或调整筛选条件后重试。") }
        } actions: {
            if vm.isModified {
                Button("重置条件") { resetConditions() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func resetConditions() {
        vm.reset()
    }

    private var listView: some View {
        List {
            if showsHeader {
                headerBar
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    .listRowSeparator(.hidden)
            }
            previousButton
            ForEach(Array(vm.items.enumerated()), id: \.element.gid) { index, info in
                NavigationLink(value: Route.gallery(info, origin: vm.listID)) {
                    GalleryRow(info: info, thumbWidth: model.setting(\.detailSize) == .short ? 64 : 84) {
                        if let state = model.downloadState(gid: info.gid) {
                            HStack { Spacer(); GalleryDownloadBadge(state: state) }
                        }
                    }
                }
                .accessibilityIdentifier("gallery-item")
                .contextMenu {
                    contextMenu(info)
                } preview: {
                    GalleryContextPreview(info: info).environment(model)
                }
                .onAppear { itemAppeared(index) }
            }
            LoadMoreFooter(state: vm.footer, onAppear: { vm.loadMore() }, retry: { vm.retryLoadMore() })
        }
        .listStyle(.plain)
        .refreshable { await vm.refresh() }
        .accessibilityIdentifier("gallery-list")
    }

    private var gridView: some View {
        ScrollView {
            if showsHeader {
                headerBar.padding(.horizontal, 16).padding(.top, 4)
            }
            previousButton
            let minWidth = GalleryCellStyle.gridMinimumWidth(for: model.setting(\.thumbSize).rawValue)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: minWidth), spacing: 10)], spacing: 14) {
                ForEach(Array(vm.items.enumerated()), id: \.element.gid) { index, info in
                    NavigationLink(value: Route.gallery(info, origin: vm.listID)) {
                        GalleryGridCell(info: info) {
                            if let state = model.downloadState(gid: info.gid) {
                                HStack {
                                    GalleryDownloadBadge(state: state)
                                        .padding(4)
                                        .background(.ultraThinMaterial, in: Circle())
                                    Spacer()
                                }
                                .padding(4)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("gallery-item")
                    .contextMenu {
                        contextMenu(info)
                    } preview: {
                        GalleryContextPreview(info: info).environment(model)
                    }
                    .onAppear { itemAppeared(index) }
                }
            }
            .padding(.horizontal, 12)
            LoadMoreFooter(state: vm.footer, onAppear: { vm.loadMore() }, retry: { vm.retryLoadMore() })
        }
        .refreshable { await vm.refresh() }
        .accessibilityIdentifier("gallery-list")
    }

    @ViewBuilder
    private var previousButton: some View {
        if vm.canLoadPrevious {
            HStack {
                Spacer()
                if vm.isLoadingPrevious {
                    ProgressView()
                } else {
                    Button {
                        vm.loadPrevious()
                    } label: {
                        Label("加载上一页", systemImage: "arrow.up.circle")
                            .font(.footnote)
                    }
                    .buttonStyle(.borderless)
                }
                Spacer()
            }
            .padding(.vertical, 6)
            .listRowSeparator(.hidden)
        }
    }

    private func contextMenu(_ info: GalleryInfo) -> some View {
        GalleryContextMenu(info: info, onFavoriteChanged: { slot, name in
            vm.updateFavorite(gid: info.gid, slot: slot, name: name)
        })
    }

    private func itemAppeared(_ index: Int) {
        if index >= vm.items.count - 6 { vm.loadMore() }
    }

    // MARK: 顶部条件栏

    private var showsHeader: Bool {
        vm.isModified || !(vm.resultCount ?? "").isEmpty
    }

    @ViewBuilder
    private var headerBar: some View {
        if showsHeader {
            HStack(spacing: 8) {
                Image(systemName: vm.builder.mode == .imageSearch ? "photo" : "line.3.horizontal.decrease.circle")
                    .foregroundStyle(.secondary)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    let summary = conditionSummary
                    if !summary.isEmpty {
                        Text(summary).font(.footnote).lineLimit(2)
                    }
                    if let count = vm.resultCount, !count.isEmpty {
                        Text("约 \(count) 个结果").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if vm.isModified {
                    ConditionBarButton(title: "重置", action: resetConditions)
                        .accessibilityLabel(Text("重置条件"))
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, vm.isModified ? 4 : 12)
            .padding(.vertical, vm.isModified ? 2 : 8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    /// 当前条件的简述，如 "上传者：xxx · 3 个分类 · 高级搜索"
    private var conditionSummary: String {
        let b = vm.builder
        guard vm.isModified else { return "" }
        var parts: [String] = []
        switch b.mode {
        case .uploader: parts.append("上传者：\(b.keyword ?? "")")
        case .tag: parts.append("标签：\(displayTag(b.keyword ?? ""))")
        case .imageSearch: parts.append("以图搜图")
        case .whatsHot: parts.append("热门")
        case .subscription:
            parts.append("订阅")
            if let k = b.keyword, !k.isEmpty { parts.append("“\(k)”") }
        default:
            if let k = b.keyword, !k.isEmpty { parts.append("“\(k)”") }
        }
        if b.category != EhUtils.NONE, b.category & EhUtils.ALL_CATEGORY != 0 {
            let n = EhCategory.ordered.filter { b.category & $0.rawValue != 0 }.count
            parts.append("\(n) 个分类")
        }
        if b.advanceSearch != -1 {
            parts.append("高级搜索")
            if b.minRating > 0 { parts.append("≥\(b.minRating) 星") }
        }
        return parts.joined(separator: " · ")
    }

    // MARK: 标题

    private var navigationTitle: String {
        if let title, !title.isEmpty { return title }
        return Self.defaultTitle(for: builder, displayTag: displayTag)
    }

    static func defaultTitle(for b: ListUrlBuilder, displayTag: (String) -> String = { $0 }) -> String {
        switch b.mode {
        case .normal:
            if let k = b.keyword, !k.isEmpty { return k }
            return "首页"
        case .subscription: return "订阅"
        case .whatsHot: return "热门"
        case .uploader: return b.keyword ?? "上传者"
        case .tag: return displayTag(b.keyword ?? "标签")
        case .imageSearch: return "以图搜图"
        case .topList: return "排行榜"
        case .filter: return b.keyword ?? "搜索"
        }
    }

    private func displayTag(_ tag: String) -> String {
        let parts = tag.split(separator: ":", maxSplits: 1).map(String.init)
        if parts.count == 2 {
            return model.displayNamespace(parts[0]) + ":" + model.displayTag(parts[1], namespace: parts[0])
        }
        return model.displayTag(tag)
    }

    // MARK: 工具栏

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if vm.supportsFilter {
                Button {
                    sheet = .filter
                } label: {
                    Label("筛选", systemImage: filterActive
                          ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
            }
            Button {
                sheet = .quickSearch
            } label: {
                Label("快速搜索", systemImage: "bookmark")
            }
            Menu {
                Picker("布局", selection: model.binding(\.listMode)) {
                    Label("列表", systemImage: "list.bullet").tag(EhSettings.ListMode.detail)
                    Label("网格", systemImage: "square.grid.2x2").tag(EhSettings.ListMode.thumb)
                }
                Section {
                    Button {
                        sheet = .jump
                    } label: {
                        Label(vm.isNewStylePaging ? "按日期跳转" : "跳页",
                              systemImage: vm.isNewStylePaging ? "calendar" : "arrow.right.to.line")
                    }
                    .disabled(!vm.canJump)
                    Button {
                        sheet = .imageSearch
                    } label: {
                        Label("以图搜图", systemImage: "photo.badge.magnifyingglass")
                    }
                    Button {
                        if let info = vm.items.randomElement() { navigate(.gallery(info)) }
                    } label: {
                        Label("随机打开", systemImage: "shuffle")
                    }
                    .disabled(vm.items.isEmpty)
                    Button {
                        Task { await vm.refresh() }
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                }
            } label: {
                Label("更多", systemImage: "ellipsis.circle")
            }
            ListSearchButton { search.present() }
        }
    }

    private var filterActive: Bool {
        let b = vm.builder
        return (b.category != EhUtils.NONE && b.category & EhUtils.ALL_CATEGORY != 0) || b.advanceSearch != -1
    }

    @ViewBuilder
    private func sheetView(_ kind: SheetKind) -> some View {
        switch kind {
        case .filter:
            AdvancedSearchSheet(builder: vm.keywordSearchBase()) { b in
                vm.apply(b)
            }
            .environment(model)
        case .imageSearch:
            ImageSearchSheet { b in
                vm.apply(b)
            }
            .presentationDetents([.medium, .large])
        case .quickSearch:
            QuickSearchView(current: vm.builder, suggestedName: quickSearchName) { b in
                vm.apply(b)
            }
            .environment(model)
        case .jump:
            JumpSheet(vm: vm)
                .presentationDetents(vm.isNewStylePaging ? [.large] : [.medium])
        }
    }

    private var quickSearchName: String {
        let b = vm.builder
        if let k = b.keyword, !k.isEmpty {
            return b.mode == .tag ? displayTag(k) : k
        }
        return Self.defaultTitle(for: b)
    }

    // MARK: 搜索

    /// 执行搜索（键盘搜索键、点搜索历史）。输入的是站内链接时直接打开
    private func performSearch(_ query: String) {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("http"), let route = EhUrlRoute.parseEhUrl(text) {
            switch route {
            case let .galleryDetail(gid, token):
                open(.galleryToken(gid: gid, token: token))
                return
            case let .galleryList(b):
                open(.list(b, title: nil))
                return
            default:
                break
            }
        }
        SearchHistoryStore.shared.add(text)
        vm.search(text, scope: scope)
    }

    /// 点按搜索历史：写入搜索框并搜索。对应 Android 搜索后回到 STATE_NORMAL（收起搜索框，导航栏按钮恢复显示）
    private func searchHistory(_ query: String) {
        search.text = query
        performSearch(query)
        search.endEditingBySubmit()
    }

    /// 从搜索框打开页面：先收起搜索框
    private func open(_ route: Route) {
        search.endEditingBySubmit()
        navigate(route)
    }

    private func updateTagSuggestions(_ text: String) {
        suggestTask?.cancel()
        let keyword = scope == .keyword ? TagSuggestionHelper.pendingKeyword(in: text) : text.trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty, let translation = model.tagTranslation else {
            tagSuggestions = []
            return
        }
        suggestTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .userInitiated) {
                translation.suggest(keyword)
            }.value
            guard !Task.isCancelled else { return }
            tagSuggestions = result
        }
    }
}

/// 条件栏（筛选 / 搜索摘要）右侧的文字按钮：视觉紧凑，触控区不小于 44pt
struct ConditionBarButton: View {
    let title: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 8)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
    }
}
