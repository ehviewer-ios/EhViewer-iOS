import SwiftUI
import EhCore
import EhNetwork
import EhStorage

// MARK: - 收藏（对应 CommonOperations.addToFavorites 的收藏夹选择对话框）

struct FavoriteSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let vm: GalleryDetailModel

    @State private var slot: Int = -1
    @State private var note = ""
    @State private var remember = false
    @State private var saving = false
    @State private var failure: String?

    /// 可用的默认收藏位置（快速收藏）
    private var quickSlot: Int? {
        let def = model.setting(\.defaultFavSlot)
        guard (-1...9).contains(def), def == -1 || model.isSignedIn else { return nil }
        return def
    }

    private func slotName(_ slot: Int) -> String {
        slot == -1 ? "本地收藏" : model.setting(\.favCat)[slot]
    }

    var body: some View {
        NavigationStack {
            Form {
                if let quick = quickSlot, !(vm.cloudFavorited && vm.cloudSlot == quick), !(quick == -1 && vm.isLocalFavorite) {
                    Section {
                        Button {
                            submit(slot: quick, note: nil)
                        } label: {
                            Label("快速收藏到「\(slotName(quick))」", systemImage: "bolt.heart")
                        }
                        .disabled(saving)
                    } footer: {
                        Text("默认收藏位置。也可以长按详情页的收藏按钮快速收藏。")
                    }
                }
                Section {
                    slotRow(-1, name: "本地收藏", icon: "iphone", count: nil)
                } header: {
                    Text("本地")
                }
                Section {
                    let names = model.setting(\.favCat)
                    let counts = model.setting(\.favCount)
                    ForEach(0..<10, id: \.self) { i in
                        slotRow(i, name: names[i], icon: "heart.fill", count: counts[i])
                            .disabled(!model.isSignedIn)
                    }
                } header: {
                    Text("云端收藏夹")
                } footer: {
                    if !model.isSignedIn { Text("登录后才能使用云端收藏夹") }
                }
                if slot >= 0 {
                    Section {
                        TextField("备注（可选，最多 250 字）", text: $note, axis: .vertical)
                            .lineLimit(2...5)
                            .onChange(of: note) { _, v in if v.count > 250 { note = String(v.prefix(250)) } }
                    } header: {
                        Text("备注")
                    }
                }
                Section {
                    Toggle("设为默认收藏位置", isOn: $remember)
                } footer: {
                    Text("开启后，可在此页顶部或长按收藏按钮一键收藏到此位置。")
                }
                if vm.isFavorited {
                    Section {
                        Button("移除收藏", role: .destructive) {
                            Task { await vm.removeFavorite(model) }
                            dismiss()
                        }
                    } footer: {
                        if let name = vm.favoriteDisplayName(model) { Text("当前：\(name)") }
                    }
                }
            }
            .navigationTitle(vm.isFavorited ? "修改收藏" : "添加收藏")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("收藏") {
                            if remember {
                                model.settings.defaultFavSlot = slot
                            } else if model.settings.defaultFavSlot == slot {
                                model.settings.defaultFavSlot = EhSettings.invalidDefaultFavSlot
                            }
                            model.settingsDidChange()
                            submit(slot: slot, note: note.isEmpty ? nil : note)
                        }
                        .disabled(slot >= 0 && !model.isSignedIn)
                    }
                }
            }
            .alert("收藏失败", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("好", role: .cancel) {}
            } message: {
                Text(failure ?? "")
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(saving)
        .onAppear {
            let def = model.settings.defaultFavSlot
            if let s = vm.cloudSlot {
                slot = s
            } else if (-1...9).contains(def), def == -1 || model.isSignedIn {
                slot = def
            } else {
                slot = model.isSignedIn ? 0 : -1
            }
            remember = (-1...9).contains(def) && def == slot
        }
    }

    /// 提交收藏；失败时 sheet 保留并就地提示
    private func submit(slot: Int, note: String?) {
        saving = true
        Task {
            let error = await vm.addFavorite(slot: slot, note: note, model, showErrorToast: false)
            saving = false
            if let error {
                failure = error.localizedDescription
            } else {
                dismiss()
            }
        }
    }

    private func slotRow(_ i: Int, name: String, icon: String, count: Int?) -> some View {
        Button {
            slot = i
            remember = model.settings.defaultFavSlot == i
        } label: {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(i >= 0 ? Self.slotColor(i) : .secondary)
                    .frame(width: 24)
                Text(name).foregroundStyle(.primary)
                if let count, count > 0 {
                    Text("\(count)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if slot == i {
                    Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .accessibilityAddTraits(slot == i ? .isSelected : [])
    }

    /// 站点收藏夹颜色
    static func slotColor(_ i: Int) -> Color {
        let colors: [Color] = [
            Color(white: 0.4), .red, .orange, .yellow, .green, Color(red: 0.6, green: 0.8, blue: 0.2), .cyan, .blue, .purple, .pink,
        ]
        return colors[max(0, min(i, 9))]
    }
}

// MARK: - 评分（对应 RateDialogHelper）

struct RatingSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let vm: GalleryDetailModel
    @State private var rating: Float = 2.5
    @State private var submitting = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Text(DetailText.ratingText(rating))
                    .font(.title3.weight(.semibold))
                    .contentTransition(.numericText())
                    .animation(.snappy, value: rating)
                RatingPicker(rating: $rating, size: 38)
                Text(String(format: "%.1f / 5", rating))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.top, 16)
            .padding(.horizontal)
            .navigationTitle("评分")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if submitting {
                        ProgressView()
                    } else {
                        Button("提交") {
                            submitting = true
                            Task {
                                do {
                                    try await vm.rate(rating, model)
                                    submitting = false
                                    dismiss()
                                } catch {
                                    submitting = false
                                    if !GalleryDetailModel.isCancellation(error) {
                                        Haptics.error()
                                        failure = error.localizedDescription
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .alert("评分失败", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("好", role: .cancel) {}
            } message: {
                Text(failure ?? "")
            }
        }
        .presentationDetents([.medium])
        .interactiveDismissDisabled(submitting)
        .onAppear {
            let r = vm.info?.rating ?? 0
            rating = r > 0 ? max(0.5, (r * 2).rounded() / 2) : 2.5
        }
    }
}

// MARK: - 归档下载（对应 ArchiverDownloadDialog + ArchiveListDialogHelper）

struct ArchiveSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let detail: GalleryDetail

    @State private var archiver: ArchiverData?
    @State private var hath: ArchiveParser.Result?
    @State private var loading = true
    @State private var error: Error?
    /// 正在提交的操作（"org" / "res" / H@H 分辨率）
    @State private var working: String?
    @State private var downloadURL: String?
    /// 等待确认的归档下载（会消耗 GP / Credits）
    @State private var pendingArchive: PendingArchive?
    /// 操作失败（sheet 内就地呈现）
    @State private var failure: String?

    private struct PendingArchive: Identifiable {
        let title: String
        let cost: String?
        let size: String?
        let url: String?
        let dltype: String
        let dlcheck: String
        var id: String { dltype }
    }

    private var archiveUrl: String {
        if let u = detail.archiveUrl, !u.isEmpty { return u }
        return EhURL.archiver(model.site, gid: detail.gid, token: detail.token, or: "")
    }

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error, archiver == nil, hath == nil {
                    ErrorStateView(error: error) { Task { await load() } }
                } else {
                    form
                }
            }
            .navigationTitle("归档下载")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
            .confirmationDialog(
                pendingArchive.map { "下载\($0.title)？" } ?? "",
                isPresented: Binding(get: { pendingArchive != nil }, set: { if !$0 { pendingArchive = nil } }),
                titleVisibility: .visible,
                presenting: pendingArchive
            ) { p in
                Button(p.cost.map { $0.isEmpty ? "下载" : "下载（消耗 \($0)）" } ?? "下载") {
                    Task { await requestArchive(url: p.url, dltype: p.dltype, dlcheck: p.dlcheck) }
                }
                Button("取消", role: .cancel) {}
            } message: { p in
                Text(confirmMessage(p))
            }
            .alert("操作失败", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("好", role: .cancel) {}
            } message: {
                Text(failure ?? "")
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(working != nil)
        .task { await load() }
    }

    private var form: some View {
        Form {
            if let url = downloadURL {
                Section {
                    Text(url)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(4)
                    Button { DetailClipboard.copy(url, model, message: "已复制下载链接") } label: {
                        Label("复制下载链接", systemImage: "doc.on.doc")
                    }
                    if let u = URL(string: url) {
                        Button { openURL(u) } label: { Label("在浏览器中下载", systemImage: "safari") }
                        ShareLink(item: u) { Label("分享链接", systemImage: "square.and.arrow.up") }
                    }
                } header: {
                    Text("归档已就绪")
                } footer: {
                    Text("已开始在应用内下载，完成后会自动解压并出现在“下载”中。如需用其他工具下载，请尽快使用此链接（有时效）。")
                }
            }

            if let a = archiver {
                Section {
                    if let funds = a.funds, !funds.isEmpty {
                        LabeledContent("当前拥有", value: funds)
                    }
                } header: {
                    Text("账户")
                }
                Section {
                    archiveOption(title: "原始档案", cost: a.originalCost, size: a.originalSize,
                                  enabled: a.originalUrl?.isEmpty == false, key: "org") {
                        pendingArchive = PendingArchive(title: "原始档案", cost: a.originalCost, size: a.originalSize,
                                                        url: a.originalUrl, dltype: "org", dlcheck: "Download Original Archive")
                    }
                    archiveOption(title: "重采样档案", cost: a.resampleCost, size: a.resampleSize,
                                  enabled: a.resampleUrl?.isEmpty == false, key: "res") {
                        pendingArchive = PendingArchive(title: "重采样档案", cost: a.resampleCost, size: a.resampleSize,
                                                        url: a.resampleUrl, dltype: "res", dlcheck: "Download Resample Archive")
                    }
                } header: {
                    Text("直接下载")
                } footer: {
                    Text("下载归档会消耗 GP / Credits（下载前会再次确认）；重采样档案体积更小。归档在应用内下载，完成后自动解压到“下载”。")
                }
            }

            Section {
                if let h = hath, !h.archiveList.isEmpty {
                    ForEach(h.archiveList, id: \.res) { item in
                        Button {
                            Task { await sendToHatH(item, or: h.paramOr) }
                        } label: {
                            HStack {
                                Label(item.name, systemImage: "server.rack")
                                Spacer()
                                if working == "hath-" + item.res { ProgressView() }
                            }
                        }
                        .disabled(working != nil)
                    }
                } else {
                    Text("没有可用的 H@H 下载选项").foregroundStyle(.secondary)
                }
            } header: {
                Text("发送到 H@H 客户端")
            } footer: {
                Text("需要账号绑定 Hentai@Home 客户端，文件会下载到 H@H 客户端所在的机器。")
            }
        }
    }

    private func archiveOption(title: String, cost: String?, size: String?, enabled: Bool, key: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).foregroundStyle(.primary)
                    HStack(spacing: 10) {
                        if let cost, !cost.isEmpty { Text("费用：\(cost)") }
                        if let size, !size.isEmpty { Text("大小：\(size)") }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if working == key {
                    ProgressView()
                } else {
                    Image(systemName: "arrow.down.circle").foregroundStyle(.tint)
                }
            }
        }
        .disabled(!enabled || working != nil)
    }

    private func confirmMessage(_ p: PendingArchive) -> String {
        var parts: [String] = []
        if let cost = p.cost, !cost.isEmpty { parts.append("将消耗 \(cost)。") }
        if let funds = archiver?.funds, !funds.isEmpty { parts.append("当前拥有：\(funds)。") }
        if let size = p.size, !size.isEmpty { parts.append("大小：\(size)。") }
        parts.append("获取下载链接后会在应用内下载并解压。")
        return parts.joined(separator: "\n")
    }

    private func load() async {
        loading = true
        defer { loading = false }
        let api = model.api
        let url = archiveUrl
        let gid = detail.gid, token = detail.token
        async let a = archiveCapture { try await api.getArchiver(url: url, gid: gid, token: token) }
        async let h = archiveCapture { try await api.getArchiveList(url: url, gid: gid, token: token) }
        let (ra, rh) = await (a, h)
        archiver = try? ra.get()
        hath = try? rh.get()
        if archiver == nil, hath == nil {
            if case let .failure(e) = ra { error = e }
        } else {
            error = nil
        }
    }

    /// 对应 DownloadArchiverListener：获取归档下载地址
    private func requestArchive(url: String?, dltype: String, dlcheck: String) async {
        working = dltype
        defer { working = nil }
        do {
            let result = try await model.api.downloadArchiver(url: url, referer: archiveUrl, dltype: dltype, dlcheck: dlcheck)
            guard let result, !result.trimmingCharacters(in: .whitespaces).isEmpty,
                  let scheme = URL(string: result)?.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                Haptics.error()
                failure = "获取下载地址失败。"
                return
            }
            downloadURL = result
            // 交给归档下载器：下载 zip → 解压到下载目录 → 登记为已完成下载
            model.startArchiveDownload(detail.info, url: result)
        } catch {
            if !GalleryDetailModel.isCancellation(error) {
                Haptics.error()
                failure = "归档下载失败：\(error.localizedDescription)"
            }
        }
    }

    /// 对应 DownloadArchiveListener
    private func sendToHatH(_ item: ArchiveItem, or: String) async {
        working = "hath-" + item.res
        defer { working = nil }
        do {
            try await model.api.downloadArchive(gid: detail.gid, token: detail.token, or: or, res: item.res)
            Haptics.success()
            model.toast.show("已发送到 H@H 客户端", systemImage: "server.rack")
        } catch EhError.noHAtH {
            Haptics.error()
            failure = "账号没有绑定 H@H 客户端。"
        } catch {
            if !GalleryDetailModel.isCancellation(error) {
                Haptics.error()
                failure = "发送失败：\(error.localizedDescription)"
            }
        }
    }
}

private func archiveCapture<T: Sendable>(_ body: @Sendable () async throws -> T) async -> Result<T, Error> {
    do { return .success(try await body()) } catch { return .failure(error) }
}

// MARK: - 画廊信息（对应 GalleryInfoScene）

struct GalleryInfoSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let info: GalleryInfo
    let detail: GalleryDetail?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    copyButton("复制标题", info.title)
                    copyButton("复制日文标题", info.titleJpn)
                    copyButton("复制链接", EhURL.galleryDetail(model.site, gid: info.gid, token: info.token))
                    copyButton("复制上传者", info.uploader)
                }
                Section {
                    row("GID", "\(info.gid)")
                    row("Token", info.token)
                    row("URL", EhURL.galleryDetail(model.site, gid: info.gid, token: info.token))
                    row("标题", info.title)
                    row("日文标题", info.titleJpn)
                    row("封面", info.thumb)
                }
                Section {
                    row("分类", info.category.displayName)
                    row("上传者", info.uploader)
                    row("发布时间", info.posted)
                    if let d = detail {
                        row("父画廊", d.parent)
                        row("可见", d.visible)
                        row("语言", d.language)
                        row("页数", info.pages > 0 ? "\(info.pages)" : nil)
                        row("大小", d.size)
                        row("收藏次数", "\(d.favoriteCount)")
                        row("已收藏", d.isFavorited ? (d.info.favoriteName ?? "是") : "否")
                        row("评分人数", "\(d.ratingCount)")
                        row("评分", info.rating >= 0 ? String(format: "%.2f", info.rating) : "暂无评分")
                        row("种子数", "\(d.torrentCount)")
                        row("种子地址", d.torrentUrl)
                        row("归档地址", d.archiveUrl)
                    }
                }
            }
            .navigationTitle("画廊信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
    }

    @ViewBuilder
    private func copyButton(_ title: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            Button { DetailClipboard.copy(value, model) } label: {
                Label(title, systemImage: "doc.on.doc")
            }
        }
    }

    /// 短值左右排列，长值（标题、链接）上下排列；文本可选择，长按可复制
    @ViewBuilder
    private func row(_ key: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            Group {
                if value.count > 24 {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(key).font(.caption).foregroundStyle(.secondary)
                        Text(value).font(.subheadline).multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    LabeledContent(key, value: value)
                }
            }
            .textSelection(.enabled)
            .contextMenu {
                Button { DetailClipboard.copy(value, model) } label: { Label("复制", systemImage: "doc.on.doc") }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAction(named: "复制") { DetailClipboard.copy(value, model) }
        }
    }
}
