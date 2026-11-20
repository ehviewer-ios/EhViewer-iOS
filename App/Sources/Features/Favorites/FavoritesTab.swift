import SwiftUI
import EhCore
import EhStorage

/// 收藏标签页。对应 Android `FavoritesScene`：
/// 收藏夹切换（全部 / 0–9 / 本地，标题菜单）、云端分页加载、搜索、排序（收藏时间 / 发布时间）、
/// 多选批量移动 / 删除 / 下载、下拉刷新、按日期跳转、随机打开、列表 / 网格。
struct FavoritesTab: View {
    @Environment(AppModel.self) private var model
    @State private var path = NavigationPath()
    @State private var vm = FavoritesModel()

    @State private var editMode: EditMode = .inactive
    @State private var selection = Set<Int64>()
    @State private var searchText = ""
    @State private var searchPresented = false
    @State private var confirmDelete = false
    @State private var showJump = false
    @State private var showSignIn = false

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle(vm.name(of: vm.favCat))
                .navigationBarTitleDisplayMode(.inline)
                .toolbarTitleMenu { folderPicker }
                .toolbar { toolbarContent }
                .toolbar(isEditing ? .hidden : .automatic, for: .tabBar)
                .listSearchable(text: $searchText, isPresented: $searchPresented,
                                prompt: "搜索\(vm.name(of: vm.favCat))")
                .onSubmit(of: .search) { vm.search(searchText) }
                .onChange(of: searchText) { _, text in
                    if vm.isLocal {
                        vm.localFilter = text
                    } else if text.isEmpty, vm.keyword != nil {
                        vm.search(nil)
                    }
                }
                .environment(\.editMode, $editMode)
                .confirmationDialog("取消收藏 \(selection.count) 项？", isPresented: $confirmDelete,
                                    titleVisibility: .visible) {
                    Button("取消收藏", role: .destructive) { modifySelected(.delete) }
                } message: {
                    Text("选中的画廊将从\(vm.name(of: vm.favCat))中移除。")
                }
                .sheet(isPresented: $showJump) {
                    FavoritesDateJumpSheet { vm.jump(to: $0) }
                        .presentationDetents([.medium, .large])
                }
                .sheet(isPresented: $showSignIn) { SignInSheet() }
                .sensoryFeedback(.selection, trigger: selection)
                .withAppRoutes()
        }
        .navigate(appendingTo: $path)
        .task { vm.start(model) }
        .onChange(of: model.isSignedIn) { _, _ in
            Task { await vm.refresh() }
        }
        .onChange(of: model.site) { _, _ in
            Task { await vm.refresh() }
        }
        .onChange(of: vm.favCat) { _, _ in
            searchText = ""
            exitEditing()
        }
    }

    private var isEditing: Bool { editMode.isEditing }

    // MARK: 收藏夹选择

    private var favCatBinding: Binding<Int> {
        Binding(get: { vm.favCat }, set: { vm.select($0) })
    }

    @ViewBuilder
    private var folderPicker: some View {
        Picker("收藏夹", selection: favCatBinding) {
            Section {
                Label("全部收藏（\(vm.count(of: FavoritesModel.all))）", systemImage: "heart.text.square")
                    .tag(FavoritesModel.all)
            }
            Section {
                ForEach(0..<10, id: \.self) { i in
                    Label("\(vm.name(of: i))（\(vm.count(of: i))）", systemImage: "\(i).circle")
                        .tag(i)
                }
            }
            Section {
                Label("本地收藏（\(vm.localCount)）", systemImage: "iphone")
                    .tag(FavoritesModel.local)
            }
        }
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        if vm.isLocal {
            if !vm.localLoaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.visibleItems.isEmpty {
                EmptyStateView(title: vm.localFilter.isEmpty ? "还没有本地收藏" : "没有匹配的收藏",
                               systemImage: vm.localFilter.isEmpty ? "heart" : "magnifyingglass",
                               message: vm.localFilter.isEmpty ? "在画廊长按菜单或详情页中可加入本地收藏。" : nil)
            } else {
                galleryList
            }
        } else if !model.isSignedIn || isNotSignedInError {
            signInPrompt
        } else if vm.items.isEmpty {
            switch vm.phase {
            case .idle, .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed:
                ScrollView {
                    ErrorStateView(error: vm.lastError ?? EhError.other("未知错误")) {
                        Task { await vm.refresh() }
                    }
                    .padding(.top, 60)
                }
                .refreshable { await vm.refresh() }
            case .loaded:
                ScrollView {
                    VStack {
                        previousButton
                        EmptyStateView(title: vm.keyword == nil ? "收藏夹是空的" : "没有找到收藏",
                                       systemImage: vm.keyword == nil ? "heart" : "magnifyingglass")
                            .padding(.top, 60)
                    }
                }
                .refreshable { await vm.refresh() }
            }
        } else {
            galleryList
        }
    }

    private var isNotSignedInError: Bool {
        guard vm.phase == .failed, let e = vm.lastError as? EhError else { return false }
        if case .notSignedIn = e { return true }
        return false
    }

    private var signInPrompt: some View {
        ContentUnavailableView {
            Label("需要登录", systemImage: "person.crop.circle.badge.questionmark")
        } description: {
            Text("登录后可查看云端收藏。本地收藏无需登录即可使用。")
        } actions: {
            Button("登录") { showSignIn = true }
                .buttonStyle(.borderedProminent)
            Button("查看本地收藏") { vm.select(FavoritesModel.local) }
        }
    }

    @ViewBuilder
    private var galleryList: some View {
        if model.setting(\.listMode) == .thumb {
            gridView
        } else {
            listView
        }
    }

    private var listView: some View {
        let items = vm.visibleItems
        return List(selection: Binding(get: { selection }, set: { if isEditing { selection = $0 } })) {
            header
            previousButton
            ForEach(Array(items.enumerated()), id: \.element.gid) { index, info in
                NavigationLink(value: Route.gallery(info)) {
                    GalleryRow(info: info, thumbWidth: model.setting(\.detailSize) == .short ? 64 : 84) {
                        if let state = model.downloadState(gid: info.gid) {
                            HStack { Spacer(); GalleryDownloadBadge(state: state) }
                        }
                    }
                }
                .tag(info.gid)
                .contextMenu { contextMenu(info) } preview: {
                    GalleryContextPreview(info: info).environment(model)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        Task { await vm.modify([info], to: .delete) }
                    } label: {
                        Label("取消收藏", systemImage: "heart.slash")
                    }
                }
                .onAppear { if index >= items.count - 6 { vm.loadMore() } }
            }
            if !vm.isLocal {
                LoadMoreFooter(state: vm.footer, onAppear: { vm.loadMore() }, retry: { vm.retryLoadMore() })
            }
        }
        .listStyle(.plain)
        .refreshable { await vm.refresh() }
    }

    private var gridView: some View {
        let items = vm.visibleItems
        let minWidth = GalleryCellStyle.gridMinimumWidth(for: model.setting(\.thumbSize).rawValue)
        return ScrollView {
            header.padding(.horizontal, 16)
            previousButton
            LazyVGrid(columns: [GridItem(.adaptive(minimum: minWidth), spacing: 10)], spacing: 14) {
                ForEach(Array(items.enumerated()), id: \.element.gid) { index, info in
                    gridCell(info)
                        .onAppear { if index >= items.count - 6 { vm.loadMore() } }
                }
            }
            .padding(.horizontal, 12)
            if !vm.isLocal {
                LoadMoreFooter(state: vm.footer, onAppear: { vm.loadMore() }, retry: { vm.retryLoadMore() })
            }
        }
        .refreshable { await vm.refresh() }
    }

    @ViewBuilder
    private func gridCell(_ info: GalleryInfo) -> some View {
        let cell = GalleryGridCell(info: info) {
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
        if isEditing {
            Button { toggle(info.gid) } label: {
                cell.gridSelectionOverlay(isEditing: true, selected: selection.contains(info.gid))
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selection.contains(info.gid) ? .isSelected : [])
        } else {
            NavigationLink(value: Route.gallery(info)) { cell }
                .buttonStyle(.plain)
                .contextMenu { contextMenu(info) } preview: {
                    GalleryContextPreview(info: info).environment(model)
                }
        }
    }

    @ViewBuilder
    private var header: some View {
        if !vm.isLocal, let kw = vm.keyword {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("“\(kw)”").font(.footnote).lineLimit(1)
                    if let c = vm.resultCount, !c.isEmpty {
                        Text("约 \(c) 个结果").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                ConditionBarButton(title: "清除") {
                    searchText = ""
                    vm.search(nil)
                }
                .accessibilityLabel(Text("清除搜索"))
            }
            .padding(.leading, 12)
            .padding(.trailing, 4)
            .padding(.vertical, 2)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
        }
    }

    @ViewBuilder
    private var previousButton: some View {
        if !vm.isLocal, vm.canLoadPrevious {
            HStack {
                Spacer()
                if vm.isLoadingPrevious {
                    ProgressView()
                } else {
                    Button {
                        vm.loadPrevious()
                    } label: {
                        Label("加载上一页", systemImage: "arrow.up.circle").font(.footnote)
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
            vm.favoriteChanged(gid: info.gid, slot: slot, name: name)
        })
    }

    // MARK: 工具栏

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if canSelect {
                Button(isEditing ? "完成" : "选择") {
                    withAnimation {
                        if isEditing { exitEditing() } else { editMode = .active }
                    }
                }
                .fontWeight(isEditing ? .semibold : .regular)
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if vm.isModifying {
                ProgressView()
                    .accessibilityLabel(Text("正在处理"))
            }
            moreMenu
            if !isEditing {
                ListSearchButton { searchPresented = true }
            }
        }
        if isEditing {
            ToolbarItemGroup(placement: .bottomBar) {
                let allSelected = !vm.visibleItems.isEmpty && selection.count == vm.visibleItems.count
                Button(allSelected ? "取消全选" : "全选") {
                    selection = allSelected ? [] : Set(vm.visibleItems.map(\.gid))
                }
                Spacer()
                Button {
                    downloadSelected()
                } label: {
                    Label("下载", systemImage: "arrow.down.circle")
                }
                .disabled(selection.isEmpty)
                Spacer()
                moveMenu
                    .disabled(selection.isEmpty || vm.isModifying)
                Spacer()
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Label("取消收藏", systemImage: "heart.slash")
                }
                .disabled(selection.isEmpty || vm.isModifying)
            }
        }
    }

    private var canSelect: Bool {
        !vm.visibleItems.isEmpty && (vm.isLocal || model.isSignedIn)
    }

    private var moveMenu: some View {
        Menu {
            if !vm.isLocal {
                Button {
                    modifySelected(.local)
                } label: {
                    Label("本地收藏", systemImage: "iphone")
                }
            }
            if model.isSignedIn {
                Section("云端收藏夹") {
                    ForEach(0..<10, id: \.self) { i in
                        if i != vm.favCat {
                            Button("\(vm.name(of: i))") { modifySelected(.cloud(i)) }
                        }
                    }
                }
            }
        } label: {
            Label("移动", systemImage: "folder")
        }
    }

    private var moreMenu: some View {
        Menu {
            Picker("布局", selection: model.binding(\.listMode)) {
                Label("列表", systemImage: "list.bullet").tag(EhSettings.ListMode.detail)
                Label("网格", systemImage: "square.grid.2x2").tag(EhSettings.ListMode.thumb)
            }
            if !vm.isLocal, model.isSignedIn {
                Picker("排序", selection: Binding(get: { vm.favOrder ?? "" }, set: { vm.setOrder($0) })) {
                    Label("按收藏时间", systemImage: "heart").tag("f")
                    Label("按发布时间", systemImage: "calendar").tag("p")
                }
                .pickerStyle(.menu)
                .disabled(vm.favOrder == nil)
                Section {
                    Button {
                        showJump = true
                    } label: {
                        Label("按日期跳转", systemImage: "calendar")
                    }
                    .disabled(!vm.canJump)
                    Button {
                        Task { await vm.refresh() }
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                }
            }
            Button {
                if let info = vm.visibleItems.randomElement() { path.append(Route.gallery(info)) }
            } label: {
                Label("随机打开", systemImage: "shuffle")
            }
            .disabled(vm.visibleItems.isEmpty)
        } label: {
            Label("更多", systemImage: "ellipsis.circle")
        }
    }

    // MARK: 多选

    private var selectedItems: [GalleryInfo] {
        vm.visibleItems.filter { selection.contains($0.gid) }
    }

    private func toggle(_ gid: Int64) {
        if selection.contains(gid) { selection.remove(gid) } else { selection.insert(gid) }
    }

    private func exitEditing() {
        editMode = .inactive
        selection = []
    }

    /// 批量下载：逐个加入下载队列，只汇总提示一次
    private func downloadSelected() {
        let targets = selectedItems
        exitEditing()
        guard !targets.isEmpty else { return }
        let s = model.settings
        let label = s.hasDefaultDownloadLabel ? s.defaultDownloadLabel : nil
        for info in targets { model.downloads.startDownload(info, label: label) }
        if let label { s.recentDownloadLabel = label }
        Haptics.success()
        model.toast.show("已加入下载：\(targets.count) 个画廊", systemImage: "arrow.down.circle")
    }

    private func modifySelected(_ dst: FavoriteDestination) {
        let targets = selectedItems
        exitEditing()
        Task { await vm.modify(targets, to: dst) }
    }
}
