import SwiftUI
import UIKit
import EhCore
import EhStorage
import EhSpider

/// 下载标签页。对应 Android `DownloadsScene`（+ part/DownloadAdapter、DownloadBatchActions、DownloadSearchController、
/// DownloadArchiveImporter / DownloadAlbumImporter）与 `DownloadLabelsScene`：
/// 标签筛选（标题菜单）、状态 / 分类筛选、排序、搜索、行内进度与速度、左滑删除（可选删除文件）、
/// 右滑 / 按钮 开始与暂停、多选批量、全部开始 / 全部暂停、拖动排序、归档下载进度、导入（zip / 文件夹 / Android 下载目录）。
struct DownloadsTab: View {
    @Environment(AppModel.self) private var model
    @State private var path = NavigationPath()

    @AppStorage("downloads_label_filter") private var labelFilterRaw = ""
    @AppStorage("downloads_sort_order") private var sortRaw = DownloadSortOrder.default.rawValue
    @AppStorage("downloads_show_size") private var showSize = false
    @State private var stateFilter: DownloadStateFilter = .all
    @State private var categoryFilter: Int?
    /// 搜索：编辑中按输入实时筛选；提交后收起搜索框，按已提交的搜索词筛选（与浏览页的搜索一致）
    @State private var search = SubmittedSearchState()
    @State private var committedQuery = ""
    @State private var tagSuggestions: [DownloadTagSuggestion] = []
    @State private var suggestTask: Task<Void, Never>?

    @State private var editMode: EditMode = .inactive
    @State private var selection = Set<Int64>()
    @State private var pendingDelete: [Int64]?
    @State private var confirmResetProgress = false
    @State private var showLabels = false

    @State private var importKind: DownloadImportKind?
    @State private var showImporter = false
    @State private var isImporting = false
    /// 开始 / 暂停触感
    @State private var controlTick = 0

    @State private var archiveTasks = ArchiveTasksModel()
    @State private var sizes = DownloadSizeCache()

    private var downloads: DownloadManager { model.downloads }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .overlay {
                    if search.isPresented, !tagSuggestions.isEmpty {
                        DownloadTagSuggestionList(suggestions: tagSuggestions) { s in
                            search.text = TagSuggestionHelper.completion(of: search.text, withTag: s.tag)
                        }
                    }
                }
                .navigationTitle(labelTitle(labelFilter))
                .navigationBarTitleDisplayMode(.inline)
                .toolbarTitleMenu { labelMenu }
                .toolbar { toolbarContent }
                .toolbar(isEditing ? .hidden : .automatic, for: .tabBar)
                .submittedSearch(search, committed: { committedQuery }, prompt: "搜索标题或标签",
                                 onSubmit: { committedQuery = $0.trimmingCharacters(in: .whitespacesAndNewlines) },
                                 onClear: { committedQuery = "" },
                                 onEdit: { updateTagSuggestions($0) },
                                 onEndEditing: {
                                     suggestTask?.cancel()
                                     tagSuggestions = []
                                 })
                .environment(\.editMode, $editMode)
                .confirmationDialog(deleteTitle, isPresented: deleteDialogBinding, titleVisibility: .visible) {
                    Button("删除下载及文件", role: .destructive) { performDelete(deleteFiles: true) }
                    Button("仅从列表中移除") { performDelete(deleteFiles: false) }
                } message: {
                    Text("删除文件会同时移除已下载的图片，无法恢复。")
                }
                .confirmationDialog("重置所有下载的阅读进度？", isPresented: $confirmResetProgress,
                                    titleVisibility: .visible) {
                    Button("重置", role: .destructive) {
                        Task {
                            await downloads.resetAllReadingProgress()
                            model.toast.show("阅读进度已重置", systemImage: "arrow.counterclockwise")
                        }
                    }
                }
                .fileImporter(isPresented: $showImporter,
                              allowedContentTypes: importKind?.contentTypes ?? [.zip],
                              allowsMultipleSelection: importKind?.allowsMultipleSelection ?? false) { result in
                    handleImport(result)
                }
                .sensoryFeedback(.selection, trigger: selection)
                .sensoryFeedback(.impact(weight: .light), trigger: controlTick)
                .navigationDestination(isPresented: $showLabels) { DownloadLabelsView() }
                .withAppRoutes()
        }
        .navigate(appendingTo: $path)
        .task {
            DownloadNotifier.shared.start(model)
            await archiveTasks.run(model)
        }
        .task(id: sizeRequestKey) { requestSizes() }
        // 读取下载画廊的标签，缺少的用 gdata 补齐（标签搜索用）
        .task(id: downloads.order.count) { model.downloadTags.refresh(model) }
        .onChange(of: labelFilterRaw) { _, _ in exitEditing() }
    }

    private var isEditing: Bool { editMode.isEditing }

    // MARK: 筛选与排序

    private var labelFilter: DownloadLabelFilter {
        let f = DownloadLabelFilter(storageValue: labelFilterRaw)
        if case let .label(l) = f, !downloads.containLabel(l) { return .all }
        return f
    }

    private var sortOrder: DownloadSortOrder { DownloadSortOrder(rawValue: sortRaw) ?? .default }

    private var isFiltered: Bool {
        stateFilter != .all || categoryFilter != nil || sortOrder != .default || !committedQuery.isEmpty
    }

    /// 生效的搜索词：编辑中为输入内容（实时筛选），否则为已提交的搜索词
    private var activeQuery: String {
        (search.isPresented ? search.text : committedQuery).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 搜索语法与站点一致（见 `LocalGallerySearch`）：匹配标题、上传者、下载标签与画廊标签
    private var items: [DownloadInfo] {
        var list = downloads.allInfoList.filter { labelFilter.matches($0) && stateFilter.matches($0) }
        if let c = categoryFilter { list = list.filter { $0.category == c } }
        let query = LocalGallerySearch(activeQuery)
        if !query.isEmpty {
            let index = model.downloadTags
            list = list.filter { info in
                query.matches(LocalGallerySearch.Item(titles: [info.title, info.titleJpn].compactMap { $0 },
                                                      uploader: info.uploader, label: info.label,
                                                      tags: index.tags(for: info.gid)))
            }
        }
        return sortOrder.sorted(list, title: { model.title(of: $0.galleryInfo) }, size: { sizes.size($0) })
    }

    /// 可拖动排序：默认排序且未筛选 / 搜索
    private var canReorder: Bool {
        sortOrder == .default && stateFilter == .all && categoryFilter == nil && activeQuery.isEmpty
    }

    private func updateTagSuggestions(_ text: String) {
        suggestTask?.cancel()
        let keyword = TagSuggestionHelper.pendingKeyword(in: text)
        guard !keyword.isEmpty else {
            tagSuggestions = []
            return
        }
        let translation = model.setting(\.showTagTranslations) ? model.tagTranslation : nil
        let index = model.downloadTags
        suggestTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let result = await index.suggestions(for: keyword, translation: translation)
            guard !Task.isCancelled else { return }
            tagSuggestions = result
        }
    }

    private var sizeRequestKey: String {
        "\(showSize)-\(sortOrder.rawValue)-\(downloads.order.count)"
    }

    private func requestSizes() {
        guard showSize || sortOrder.needsFileSize else { return }
        for info in downloads.allInfoList where info.state == DownloadInfo.stateFinish {
            sizes.request(info, model: model)
        }
    }

    private func labelTitle(_ f: DownloadLabelFilter) -> String {
        switch f {
        case .all: return "全部下载"
        case .defaultLabel: return "默认"
        case let .label(l): return l
        }
    }

    @ViewBuilder
    private var labelMenu: some View {
        Picker("标签", selection: Binding(get: { labelFilter.storageValue }, set: { labelFilterRaw = $0 })) {
            Label("全部（\(downloads.order.count)）", systemImage: "tray.full")
                .tag(DownloadLabelFilter.all.storageValue)
            Label("默认（\(downloads.labelCount(nil))）", systemImage: "tray")
                .tag(DownloadLabelFilter.defaultLabel.storageValue)
            ForEach(downloads.labelList.compactMap(\.label), id: \.self) { l in
                Label("\(l)（\(downloads.labelCount(l))）", systemImage: "tag")
                    .tag(DownloadLabelFilter.label(l).storageValue)
            }
        }
        Button {
            showLabels = true
        } label: {
            Label("管理标签", systemImage: "tag")
        }
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        let list = items
        if list.isEmpty, archiveTasks.items.isEmpty {
            emptyView
        } else if model.setting(\.listMode) == .thumb {
            gridView(list)
        } else {
            listView(list)
        }
    }

    @ViewBuilder
    private var emptyView: some View {
        if downloads.order.isEmpty {
            ContentUnavailableView {
                Label("还没有下载", systemImage: "arrow.down.circle")
            } description: {
                Text("在画廊详情或长按菜单中下载画廊，也可以导入本地压缩包或文件夹。")
            } actions: {
                importMenu(label: Label("导入", systemImage: "square.and.arrow.down"))
                    .buttonStyle(.borderedProminent)
            }
        } else if !activeQuery.isEmpty {
            ContentUnavailableView {
                Label("没有“\(activeQuery)”的结果", systemImage: "magnifyingglass")
            } description: {
                Text("可以按标题、上传者或标签搜索，标签写法与站点搜索相同，如 l:chinese$。")
            } actions: {
                if !committedQuery.isEmpty, !search.isPresented { Button("清除搜索") { committedQuery = "" } }
            }
        } else {
            ContentUnavailableView {
                Label("没有符合条件的下载", systemImage: "line.3.horizontal.decrease.circle")
            } actions: {
                if isFiltered { Button("清除筛选") { clearFilters() } }
            }
        }
    }

    private var selectionBinding: Binding<Set<Int64>> {
        Binding(get: { selection }, set: { if isEditing { selection = $0 } })
    }

    private func listView(_ list: [DownloadInfo]) -> some View {
        List(selection: selectionBinding) {
            ArchiveTasksSection(tasks: archiveTasks)
            Section {
                filterHeader
                ForEach(list) { info in
                    row(info)
                        .tag(info.gid)
                }
                .onMove(perform: moveAction)
            } header: {
                if !archiveTasks.items.isEmpty, !list.isEmpty { Text("画廊") }
            }
        }
        .listStyle(.plain)
    }

    @ViewBuilder
    private func row(_ info: DownloadInfo) -> some View {
        DownloadItemRow(info: info, showsLabel: labelFilter == .all, showsSize: showSize,
                        fileSize: sizes.size(info.gid), isEditing: isEditing,
                        onOpen: { open(info) },
                        onOpenDetail: DownloadDisplay.isLocal(info) ? nil : { path.append(Route.gallery(info.galleryInfo)) },
                        onStart: { start([info.gid]) }, onStop: { stop([info.gid]) })
        .contextMenu { rowMenu(info) } preview: {
            GalleryContextPreview(info: DownloadDisplay.galleryInfo(for: info, model: model)).environment(model)
        }
        .swipeActions(edge: .leading) {
            if DownloadDisplay.canStart(info) {
                Button { start([info.gid]) } label: { Label("开始", systemImage: "play.fill") }
                    .tint(.green)
            } else if DownloadDisplay.canStop(info) {
                Button { stop([info.gid]) } label: { Label("暂停", systemImage: "pause.fill") }
                    .tint(.orange)
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                pendingDelete = [info.gid]
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private func gridView(_ list: [DownloadInfo]) -> some View {
        let minWidth = GalleryCellStyle.gridMinimumWidth(for: model.setting(\.thumbSize).rawValue)
        return ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if !archiveTasks.items.isEmpty {
                    Label("归档下载", systemImage: "archivebox").font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(archiveTasks.items) { item in
                        ArchiveTaskRow(item: item, title: archiveTasks.title(item.gid), tasks: archiveTasks)
                        Divider()
                    }
                }
                filterHeader
            }
            .padding(.horizontal, 16)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: minWidth), spacing: 10)], spacing: 14) {
                ForEach(list) { info in
                    gridCell(info)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
    }

    @ViewBuilder
    private func gridCell(_ info: DownloadInfo) -> some View {
        let cell = DownloadGridItem(info: info).contentShape(Rectangle())
        if isEditing {
            Button { toggle(info.gid) } label: {
                cell.gridSelectionOverlay(isEditing: true, selected: selection.contains(info.gid))
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selection.contains(info.gid) ? .isSelected : [])
        } else {
            Button { open(info) } label: { cell }
                .buttonStyle(.plain)
                .contextMenu { rowMenu(info) } preview: {
                    GalleryContextPreview(info: DownloadDisplay.galleryInfo(for: info, model: model)).environment(model)
                }
        }
    }

    @ViewBuilder
    private var filterHeader: some View {
        if isFiltered {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease.circle").foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(filterSummary).font(.footnote).lineLimit(2)
                    if !committedQuery.isEmpty {
                        Text("\(items.count) 项").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                ConditionBarButton(title: "清除筛选", action: clearFilters)
            }
            .padding(.leading, 12)
            .padding(.trailing, 4)
            .padding(.vertical, 2)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            .selectionDisabled()
        }
    }

    private var filterSummary: String {
        var parts: [String] = []
        if !committedQuery.isEmpty { parts.append("“\(committedQuery)”") }
        if stateFilter != .all { parts.append(stateFilter.title) }
        if let c = categoryFilter { parts.append(EhCategory(rawValue: c).displayName) }
        if sortOrder != .default { parts.append("排序：\(sortOrder.title)") }
        return parts.joined(separator: " · ")
    }

    private func clearFilters() {
        stateFilter = .all
        categoryFilter = nil
        sortRaw = DownloadSortOrder.default.rawValue
        committedQuery = ""
    }

    // MARK: 行菜单

    @ViewBuilder
    private func rowMenu(_ info: DownloadInfo) -> some View {
        let local = DownloadDisplay.isLocal(info)
        if isReadable(info) {
            Button { open(info) } label: { Label("阅读", systemImage: "book") }
        }
        if !local {
            Button {
                path.append(Route.gallery(info.galleryInfo))
            } label: {
                Label("详情", systemImage: "info.circle")
            }
        }
        if DownloadDisplay.canStart(info) {
            Button { start([info.gid]) } label: { Label("开始", systemImage: "play") }
        } else if DownloadDisplay.canStop(info) {
            Button { stop([info.gid]) } label: { Label("暂停", systemImage: "pause") }
        } else if !local, info.state == DownloadInfo.stateFinish {
            Button {
                downloads.startRangeDownload([info.gid])
            } label: {
                Label("重新检查下载", systemImage: "arrow.clockwise")
            }
        }
        moveLabelMenu([info.gid])
        if !local, let url = BrowseGalleryActions.galleryURL(info.galleryInfo, site: model.site) {
            Divider()
            Button {
                UIPasteboard.general.string = url.absoluteString
                model.toast.show("链接已复制", systemImage: "doc.on.doc")
            } label: {
                Label("复制链接", systemImage: "link")
            }
            ShareLink(item: url, subject: Text(model.title(of: info.galleryInfo))) {
                Label("分享", systemImage: "square.and.arrow.up")
            }
        }
        Divider()
        Button(role: .destructive) {
            pendingDelete = [info.gid]
        } label: {
            Label("删除", systemImage: "trash")
        }
    }

    private func moveLabelMenu(_ gids: [Int64]) -> some View {
        Menu {
            Button {
                downloads.changeLabel(gids, to: nil)
                afterBatch()
            } label: {
                Label("默认", systemImage: "tray")
            }
            ForEach(downloads.labelList.compactMap(\.label), id: \.self) { l in
                Button {
                    downloads.changeLabel(gids, to: l)
                    afterBatch()
                } label: {
                    Label(l, systemImage: "tag")
                }
            }
        } label: {
            Label("移动到标签", systemImage: "tag")
        }
    }

    // MARK: 工具栏

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if !items.isEmpty {
                Button(isEditing ? "完成" : "选择") {
                    withAnimation {
                        if isEditing { exitEditing() } else { editMode = .active }
                    }
                }
                .fontWeight(isEditing ? .semibold : .regular)
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if !isEditing {
                if isImporting {
                    ProgressView()
                        .accessibilityLabel(Text("正在导入"))
                } else {
                    importMenu(label: Label("导入", systemImage: "square.and.arrow.down"))
                }
                moreMenu
                ListSearchButton { search.present() }
            }
        }
        if isEditing {
            ToolbarItemGroup(placement: .bottomBar) {
                let visible = items
                let allSelected = !visible.isEmpty && selection.count == visible.count
                Button(allSelected ? "取消全选" : "全选") {
                    selection = allSelected ? [] : Set(visible.map(\.gid))
                }
                Spacer()
                Button {
                    start(Array(selection))
                    exitEditing()
                } label: {
                    Label("开始", systemImage: "play")
                }
                .disabled(selection.isEmpty)
                Spacer()
                Button {
                    stop(Array(selection))
                    exitEditing()
                } label: {
                    Label("暂停", systemImage: "pause")
                }
                .disabled(selection.isEmpty)
                Spacer()
                moveLabelMenu(Array(selection))
                    .disabled(selection.isEmpty)
                Spacer()
                Button(role: .destructive) {
                    pendingDelete = orderedSelection
                } label: {
                    Label("删除", systemImage: "trash")
                }
                .disabled(selection.isEmpty)
            }
        }
    }

    private func importMenu(label: Label<Text, Image>) -> some View {
        Menu {
            Button {
                beginImport(.archive)
            } label: {
                Label("导入压缩包（zip / cbz）", systemImage: "doc.zipper")
            }
            Button {
                beginImport(.folder)
            } label: {
                Label("导入文件夹", systemImage: "folder")
            }
            Button {
                beginImport(.downloadRoot)
            } label: {
                Label("导入 Android 下载目录", systemImage: "externaldrive")
            }
        } label: {
            label
        }
    }

    private var moreMenu: some View {
        Menu {
            Section {
                Button {
                    downloads.startAllDownload()
                    controlTick += 1
                } label: {
                    Label("全部开始", systemImage: "play")
                }
                .disabled(!downloads.allInfoList.contains(where: DownloadDisplay.canStart))
                Button {
                    downloads.stopAllDownload()
                    controlTick += 1
                } label: {
                    Label("全部暂停", systemImage: "pause")
                }
                .disabled(downloads.isIdle)
            }
            Section {
                Picker(selection: $stateFilter) {
                    ForEach(DownloadStateFilter.allCases, id: \.self) { s in
                        Label(s.title, systemImage: s.systemImage).tag(s)
                    }
                } label: {
                    Label("状态", systemImage: "line.3.horizontal.decrease.circle")
                }
                .pickerStyle(.menu)
                Picker(selection: $categoryFilter) {
                    Text("全部分类").tag(Int?.none)
                    ForEach(EhCategory.ordered + [EhCategory.unknown], id: \.rawValue) { c in
                        Text(c.displayName).tag(Int?.some(c.rawValue))
                    }
                } label: {
                    Label("分类", systemImage: "square.grid.3x3")
                }
                .pickerStyle(.menu)
                Picker(selection: $sortRaw) {
                    ForEach(DownloadSortOrder.allCases, id: \.self) { s in
                        Text(s.title).tag(s.rawValue)
                    }
                } label: {
                    Label("排序", systemImage: "arrow.up.arrow.down")
                }
                .pickerStyle(.menu)
            }
            Section {
                Picker("布局", selection: model.binding(\.listMode)) {
                    Label("列表", systemImage: "list.bullet").tag(EhSettings.ListMode.detail)
                    Label("网格", systemImage: "square.grid.2x2").tag(EhSettings.ListMode.thumb)
                }
                Toggle(isOn: $showSize) {
                    Label("显示页数与大小", systemImage: "internaldrive")
                }
            }
            Section {
                Button {
                    confirmResetProgress = true
                } label: {
                    Label("重置阅读进度", systemImage: "arrow.counterclockwise")
                }
                .disabled(downloads.order.isEmpty)
            }
        } label: {
            Label("更多", systemImage: "ellipsis.circle")
        }
    }

    // MARK: 操作

    private func isReadable(_ info: DownloadInfo) -> Bool {
        DownloadDisplay.isLocal(info) || info.state == DownloadInfo.stateFinish
            || info.state == DownloadInfo.stateDownload || downloads.currentGid == info.gid
    }

    /// 点击行：已完成 / 下载中 / 本地导入 → 阅读器；其余 → 详情（点击封面始终进入详情）
    private func open(_ info: DownloadInfo) {
        let title = model.title(of: info.galleryInfo)
        if DownloadManager.isLocalArchive(info), let s = info.archiveUri, let url = URL(string: s) {
            model.openReader(ReaderRequest(source: .archive(url, title: title)))
        } else if DownloadManager.isLocalAlbum(info) {
            if let dir = downloads.downloadDirectory(for: info.gid) {
                model.openReader(ReaderRequest(source: .directory(dir, title: title)))
            } else {
                model.toast.show("找不到导入的文件夹", systemImage: "exclamationmark.circle")
            }
        } else if isReadable(info) {
            model.openReader(info.galleryInfo)
        } else {
            path.append(Route.gallery(info.galleryInfo))
        }
    }

    /// 按当前显示顺序排列的选中项
    private var orderedSelection: [Int64] {
        items.map(\.gid).filter { selection.contains($0) }
    }

    private func start(_ gids: [Int64]) {
        controlTick += 1
        let ordered = downloads.order.filter { gids.contains($0) }
        if ordered.count == 1, let gid = ordered.first, let info = downloads.downloadInfo(gid) {
            downloads.startDownload(info.galleryInfo, label: info.label)
        } else {
            downloads.startRangeDownload(ordered)
        }
    }

    private func stop(_ gids: [Int64]) {
        controlTick += 1
        if gids.count == 1, let gid = gids.first {
            downloads.stopDownload(gid)
        } else {
            downloads.stopRangeDownload(gids)
        }
    }

    private var deleteDialogBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private var deleteTitle: String {
        guard let gids = pendingDelete else { return "删除下载" }
        if gids.count == 1, let info = downloads.downloadInfo(gids[0]) {
            return "删除“\(model.title(of: info.galleryInfo))”？"
        }
        return "删除选中的 \(gids.count) 项下载？"
    }

    private func performDelete(deleteFiles: Bool) {
        guard let gids = pendingDelete else { return }
        pendingDelete = nil
        DownloadImporter.delete(gids, deleteFiles: deleteFiles, model: model)
        for gid in gids { sizes.invalidate(gid) }
        if isEditing { exitEditing() }
    }

    private var moveAction: ((IndexSet, Int) -> Void)? {
        guard canReorder, isEditing else { return nil }
        return { move($0, $1) }
    }

    private func move(_ source: IndexSet, _ destination: Int) {
        guard let from = source.first else { return }
        let to = destination > from ? destination - 1 : destination
        switch labelFilter {
        case .all: downloads.moveDownload(label: nil, allLabels: true, from: from, to: to)
        case .defaultLabel: downloads.moveDownload(label: nil, from: from, to: to)
        case let .label(l): downloads.moveDownload(label: l, from: from, to: to)
        }
    }

    private func toggle(_ gid: Int64) {
        if selection.contains(gid) { selection.remove(gid) } else { selection.insert(gid) }
    }

    private func exitEditing() {
        editMode = .inactive
        selection = []
    }

    private func afterBatch() {
        if isEditing { exitEditing() }
    }

    // MARK: 导入

    private func beginImport(_ kind: DownloadImportKind) {
        importKind = kind
        showImporter = true
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        guard let kind = importKind else { return }
        switch result {
        case let .success(urls):
            guard !urls.isEmpty else { return }
            isImporting = true
            let label = labelFilter.labelValue
            Task {
                let summary = await DownloadImporter.run(kind, urls: urls, label: label, model: model)
                isImporting = false
                model.toast.show(summary.message,
                                 systemImage: summary.failures.isEmpty ? "square.and.arrow.down" : "exclamationmark.circle",
                                 duration: .seconds(summary.failures.isEmpty ? 2 : 4))
            }
        case let .failure(error):
            model.toast.error(error)
        }
    }
}
