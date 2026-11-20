import SwiftUI
import EhCore
import EhNetwork
import EhStorage

/// 画廊详情。对应 Android `GalleryDetailScene`
struct GalleryDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.navigate) private var navigate
    @State private var vm: GalleryDetailModel
    @State private var sheet: DetailSheet?
    @State private var showCover = false
    @State private var confirmRemoveFavorite = false
    @State private var pendingUploaderFilter: String?
    /// 需要登录的操作被点击：提示并提供登录入口
    @State private var signInPrompt: String?

    enum DetailSheet: String, Identifiable {
        case favorite, rating, archive, info, signIn
        var id: String { rawValue }
    }

    init(info: GalleryInfo) {
        _vm = State(initialValue: GalleryDetailModel(info: info))
    }

    init(gid: Int64, token: String) {
        _vm = State(initialValue: GalleryDetailModel(gid: gid, token: token))
    }

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                content(width: geo.size.width)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
            }
            .refreshable { await vm.load(model) }
            .accessibilityIdentifier("gallery-detail")
        }
        .navigationTitle(vm.info.map { model.title(of: $0) } ?? "画廊")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .task { await vm.setup(model) }
        .onChange(of: model.readerRequest == nil) { _, closed in
            if closed { vm.refreshLocalState(model) }
        }
        .environment(\.openURL, OpenURLAction { url in
            DetailLinkRouter.handle(url, app: model) { navigate($0) }
        })
        .sheet(item: $sheet) { s in
            switch s {
            case .favorite: FavoriteSheet(vm: vm)
            case .rating: RatingSheet(vm: vm)
            case .archive:
                if let d = vm.detail { ArchiveSheet(detail: d) }
            case .info:
                if let info = vm.info { GalleryInfoSheet(info: info, detail: vm.detail) }
            case .signIn:
                SignInSheet()
            }
        }
        .onChange(of: model.isSignedIn) { _, signedIn in
            // 登录后重新加载，取得 apikey 等
            if signedIn { Task { await vm.load(model) } }
        }
        .alert("需要登录", isPresented: Binding(get: { signInPrompt != nil }, set: { if !$0 { signInPrompt = nil } })) {
            Button("登录") { sheet = .signIn }
            Button("取消", role: .cancel) {}
        } message: {
            Text(signInPrompt ?? "")
        }
        .fullScreenCover(isPresented: $showCover) {
            DetailCoverViewer(url: vm.info?.thumb, referer: model.site.referer)
        }
        .confirmationDialog("移除收藏", isPresented: $confirmRemoveFavorite, titleVisibility: .hidden) {
            Button("移除收藏", role: .destructive) { Task { await vm.removeFavorite(model) } }
            Button("修改收藏夹…") { sheet = .favorite }
        } message: {
            if let name = vm.favoriteDisplayName(model) { Text("已收藏到「\(name)」") }
        }
        .confirmationDialog(
            "屏蔽上传者“\(pendingUploaderFilter ?? "")”？",
            isPresented: Binding(get: { pendingUploaderFilter != nil }, set: { if !$0 { pendingUploaderFilter = nil } }),
            titleVisibility: .visible
        ) {
            Button("加入过滤器", role: .destructive) {
                if let u = pendingUploaderFilter { addUploaderFilter(u) }
            }
        }
    }

    // MARK: - 布局

    @ViewBuilder
    private func content(width: CGFloat) -> some View {
        if let info = vm.info {
            if width >= 700 {
                HStack(alignment: .top, spacing: 28) {
                    VStack(alignment: .leading, spacing: 18) {
                        primarySections(info)
                    }
                    .frame(width: min(440, width * 0.42))
                    VStack(alignment: .leading, spacing: 24) {
                        secondarySections(info)
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(.top, 12)
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    primarySections(info)
                    secondarySections(info)
                }
                .padding(.top, 8)
            }
        } else if let error = vm.error {
            errorView(error)
                .frame(minHeight: 400)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 400)
        }
    }

    @ViewBuilder
    private func primarySections(_ info: GalleryInfo) -> some View {
        DetailHeaderView(
            info: info,
            detail: vm.detail,
            navigate: { navigate($0) },
            onCoverTap: { showCover = true },
            onFilterUploader: { pendingUploaderFilter = $0 }
        )
        DetailActionBar(
            vm: vm,
            info: info,
            onRead: { page in model.openReader(info, page: page) },
            onFavorite: onFavoriteTap,
            onQuickFavorite: { slot in Task { await vm.addFavorite(slot: slot, note: nil, model) } },
            onRemoveFavorite: { Task { await vm.removeFavorite(model) } },
            onRate: {
                guard requireSignIn("登录后才能为画廊评分。") else { return }
                sheet = .rating
            },
            onTorrent: { if let d = vm.detail { navigate(.torrents(d)) } },
            onArchive: {
                guard requireSignIn("登录后才能下载归档。") else { return }
                sheet = .archive
            },
            onSimilar: {
                if let b = vm.similarBuilder() { navigate(.list(b, title: "相似画廊")) }
            }
        )
        DetailInfoStrip(info: info, detail: vm.detail, navigate: { navigate($0) }, onShowInfo: { sheet = .info })

        if vm.detail == nil {
            if let error = vm.error {
                errorView(error)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 24)
            }
        }
    }

    @ViewBuilder
    private func secondarySections(_ info: GalleryInfo) -> some View {
        if let d = vm.detail {
            if !d.newVersions.isEmpty {
                newVersionBanner(d)
            }
            DetailTagSection(groups: d.tags, navigate: { navigate($0) })
            previewSection(d, info: info)
            if model.setting(\.showGalleryComment) {
                commentSection(d)
            }
        }
    }

    // MARK: - 新版本（对应 GalleryUpdateDialog）

    /// 单个新版本直接打开；多个新版本用菜单选择
    @ViewBuilder
    private func newVersionBanner(_ d: GalleryDetail) -> some View {
        if d.newVersions.count == 1 {
            Button {
                openNewVersion(d, index: 0)
            } label: {
                newVersionLabel(d, subtitle: d.newVersions[0].versionName, accessory: "chevron.right")
            }
            .buttonStyle(.plain)
        } else {
            Menu {
                ForEach(Array(d.newVersions.enumerated()), id: \.offset) { index, version in
                    Button(version.versionName) { openNewVersion(d, index: index) }
                }
            } label: {
                newVersionLabel(d, subtitle: "共 \(d.newVersions.count) 个新版本，最新：\(d.newVersions.last?.versionName ?? "")",
                                accessory: "chevron.up.chevron.down")
            }
            .buttonStyle(.plain)
        }
    }

    private func openNewVersion(_ d: GalleryDetail, index: Int) {
        if let gi = d.info(forNewVersion: index) {
            navigate(.galleryToken(gid: gi.gid, token: gi.token))
        }
    }

    private func newVersionLabel(_ d: GalleryDetail, subtitle: String, accessory: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles").font(.title3).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("此画廊有新版本").font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Image(systemName: accessory).font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    // MARK: - 预览

    @ViewBuilder
    private func previewSection(_ d: GalleryDetail, info: GalleryInfo) -> some View {
        let items = d.previewSet?.items ?? []
        let large = d.previewSet?.isLarge ?? false
        VStack(alignment: .leading, spacing: 10) {
            DetailSectionHeader(title: "预览") {
                if d.previewPages > 0 || !items.isEmpty {
                    NavigationLink(value: Route.previews(d)) {
                        Text(d.previewPages > 1 ? "全部（\(d.previewPages) 页）" : "全部")
                    }
                    .font(.subheadline)
                }
            }
            if items.isEmpty {
                Text("没有预览").font(.subheadline).foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: large ? 130 : 86), spacing: 8)], spacing: 12) {
                    ForEach(items, id: \.position) { preview in
                        Button {
                            model.openReader(info, page: preview.position)
                        } label: {
                            DetailPreviewCell(preview: preview, referer: model.site.referer)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("第 \(preview.position + 1) 页")
                    }
                }
            }
        }
    }

    // MARK: - 评论摘要

    @ViewBuilder
    private func commentSection(_ d: GalleryDetail) -> some View {
        let comments = Array(d.comments.comments.prefix(3))
        VStack(alignment: .leading, spacing: 10) {
            DetailSectionHeader(title: "评论") {
                NavigationLink(value: Route.comments(d)) {
                    Text(d.comments.hasMore || d.comments.comments.count > comments.count
                         ? "全部（\(d.comments.comments.count)\(d.comments.hasMore ? "+" : "")）" : "查看")
                }
                .font(.subheadline)
            }
            if comments.isEmpty {
                NavigationLink(value: Route.comments(d)) {
                    HStack {
                        Text("暂无评论，来发表第一条吧").foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .font(.subheadline)
                    .padding(12)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(comments.enumerated()), id: \.element.id) { index, comment in
                        if index > 0 { Divider() }
                        NavigationLink(value: Route.comments(d)) {
                            CommentRow(comment: comment, compact: true)
                                .padding(.vertical, 10)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    // MARK: - 错误

    @ViewBuilder
    private func errorView(_ error: Error) -> some View {
        switch error as? EhError {
        case .offensive?:
            ContentUnavailableView {
                Label("内容警告", systemImage: "exclamationmark.shield")
            } description: {
                Text("该画廊被标记为包含冒犯性内容。确认后继续访问即表示你同意查看。")
            } actions: {
                Button("仍要查看") { Task { await vm.confirmOffensive(model) } }
                    .buttonStyle(.borderedProminent)
            }
        case .pining?:
            ContentUnavailableView {
                Label("画廊已删除", systemImage: "trash")
            } description: {
                Text("This gallery is pining for the fjords.\n该画廊已被移除，无法访问。")
            } actions: {
                Button("重试") { Task { await vm.load(model) } }
            }
        case .banned?:
            ContentUnavailableView {
                Label("IP 被封禁", systemImage: "hand.raised")
            } description: {
                Text(error.localizedDescription)
            } actions: {
                Button("重试") { Task { await vm.load(model) } }
            }
        default:
            ErrorStateView(error: error) { Task { await vm.load(model) } }
        }
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if let url = URL(string: vm.galleryURL(site: model.site)) {
                ShareLink(item: url, subject: Text(vm.info.map { model.title(of: $0) } ?? "")) {
                    Label("分享", systemImage: "square.and.arrow.up")
                }
            }
            Menu {
                Button { Task { await vm.load(model) } } label: { Label("刷新", systemImage: "arrow.clockwise") }
                    .disabled(vm.isLoading)
                if let url = URL(string: vm.galleryURL(site: model.site)) {
                    Link(destination: url) { Label("在浏览器中打开", systemImage: "safari") }
                    Button { DetailClipboard.copy(url.absoluteString, model, message: "已复制链接") } label: {
                        Label("复制链接", systemImage: "link")
                    }
                }
                if vm.info != nil {
                    Button { sheet = .info } label: { Label("画廊信息", systemImage: "info.circle") }
                }
                Divider()
                if let info = vm.info {
                    Button { model.openReader(info, page: 0) } label: {
                        Label("从头阅读", systemImage: "arrow.counterclockwise")
                    }
                }
                Button {
                    if let b = vm.similarBuilder() { navigate(.list(b, title: "相似画廊")) }
                } label: {
                    Label("搜索相似画廊", systemImage: "square.stack.3d.up")
                }
                Button {
                    Task {
                        if let b = await vm.coverSearchBuilder(model) { navigate(.list(b, title: "以图搜图")) }
                    }
                } label: {
                    Label("以封面搜索", systemImage: "photo.badge.magnifyingglass")
                }
                .disabled((vm.info?.thumb ?? "").isEmpty)
                if let uploader = vm.info?.uploader, !uploader.isEmpty {
                    Divider()
                    Button(role: .destructive) { pendingUploaderFilter = uploader } label: {
                        Label("屏蔽上传者", systemImage: "eye.slash")
                    }
                }
            } label: {
                // iOS 26 起工具栏按钮自带圆形玻璃背景，ellipsis.circle 会出现双圆圈
                Label("更多", systemImage: "ellipsis")
            }
        }
    }

    // MARK: - 操作

    /// 未登录时提示登录（带“登录”按钮），返回是否可继续
    private func requireSignIn(_ message: String) -> Bool {
        if !model.isSignedIn {
            signInPrompt = message
            return false
        }
        if !vm.canUseAPI {
            model.toast.show("暂时无法使用，请刷新页面后重试", systemImage: "exclamationmark.circle")
            return false
        }
        return true
    }

    /// 对应 mHeartGroup 点击：已收藏 → 移除/修改；未收藏 → 选择收藏夹
    private func onFavoriteTap() {
        guard vm.info != nil else { return }
        if vm.isFavorited {
            confirmRemoveFavorite = true
        } else {
            sheet = .favorite
        }
    }

    /// 对应 showFilterUploaderDialog
    private func addUploaderFilter(_ uploader: String) {
        do {
            try model.filter.addFilter(Filter(mode: EhFilter.Mode.uploader.rawValue, text: uploader))
            model.toast.show("已添加过滤器", systemImage: "line.3.horizontal.decrease.circle")
        } catch {
            model.toast.error(error)
        }
    }
}
