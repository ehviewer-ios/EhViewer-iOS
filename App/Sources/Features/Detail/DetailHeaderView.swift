import SwiftUI
import EhCore
import EhStorage

/// 头部：封面、标题、上传者、分类、评分。对应 Android `GalleryHeader` + 详情页头部
struct DetailHeaderView: View {
    @Environment(AppModel.self) private var model
    let info: GalleryInfo
    let detail: GalleryDetail?
    let navigate: (Route) -> Void
    let onCoverTap: () -> Void
    let onFilterUploader: (String) -> Void

    private var coverAspect: CGFloat {
        if info.thumbWidth > 0, info.thumbHeight > 0 {
            return min(max(CGFloat(info.thumbWidth) / CGFloat(info.thumbHeight), 0.5), 1.5)
        }
        return 0.7
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Button(action: onCoverTap) {
                ThumbnailImage(url: info.thumb, referer: model.site.referer)
                    .aspectRatio(coverAspect, contentMode: .fit)
                    .frame(width: 124)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.quaternary, lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("查看封面")

            VStack(alignment: .leading, spacing: 8) {
                titleBlock
                uploaderButton
                HStack(spacing: 8) {
                    Button {
                        guard info.category != .unknown else { return }
                        navigate(.list(ListUrlBuilder(mode: .normal, category: info.category.rawValue), title: info.category.displayName))
                    } label: {
                        CategoryBadge(category: info.category)
                    }
                    .buttonStyle(.plain)
                    if let lang = detail?.language ?? info.simpleLanguage, !lang.isEmpty {
                        Text(lang)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                }
                if model.setting(\.showGalleryRating) {
                    ratingRow
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var titleBlock: some View {
        let preferJpn = model.setting(\.showJpnTitle)
        let main = info.suitableTitle(preferJapanese: preferJpn)
        let other = preferJpn ? info.title : info.titleJpn
        VStack(alignment: .leading, spacing: 4) {
            Text(main)
                .font(.headline)
                .lineLimit(6)
                .textSelection(.enabled)
            if let other, !other.isEmpty, other != main {
                Text(other)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
        }
        // 标题可直接选择文本；“复制标题”等在画廊信息 sheet 中
    }

    @ViewBuilder
    private var uploaderButton: some View {
        if let uploader = info.uploader, !uploader.isEmpty {
            Button {
                navigate(.list(.uploader(uploader), title: uploader))
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "person.circle")
                    Text(uploader).lineLimit(1)
                    if info.disowned { Text("(已弃权)").foregroundStyle(.secondary) }
                }
                .font(.subheadline)
            }
            .buttonStyle(.borderless)
            .contextMenu {
                Button { navigate(.list(.uploader(uploader), title: uploader)) } label: {
                    Label("搜索该上传者", systemImage: "magnifyingglass")
                }
                Button { DetailClipboard.copy(uploader, model) } label: { Label("复制", systemImage: "doc.on.doc") }
                Button(role: .destructive) { onFilterUploader(uploader) } label: {
                    Label("屏蔽该上传者", systemImage: "eye.slash")
                }
            }
        }
    }

    private var ratingRow: some View {
        let rating = info.rating
        return HStack(spacing: 6) {
            RatingView(rating: max(rating, 0), size: 13, color: info.rated ? .blue : .orange)
            if rating >= 0 {
                Text(String(format: "%.2f", rating)).font(.subheadline.monospacedDigit().weight(.medium))
            }
            if let count = detail?.ratingCount, count > 0 {
                Text("(\(count))").font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// 信息条：页数、大小、发布、收藏数、可见性、父画廊（横向滚动，类似 App Store 信息条）
struct DetailInfoStrip: View {
    let info: GalleryInfo
    let detail: GalleryDetail?
    let navigate: (Route) -> Void
    let onShowInfo: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                cell("页数", value: info.pages > 0 ? "\(info.pages)" : "—", icon: "doc.on.doc")
                divider
                cell("大小", value: nonEmpty(detail?.size) ?? "—", icon: "externaldrive")
                divider
                cell("发布", value: nonEmpty(info.posted) ?? "—", icon: "calendar")
                if let d = detail {
                    divider
                    cell("收藏", value: "\(d.favoriteCount)", icon: "heart")
                    if let v = nonEmpty(d.visible) {
                        divider
                        cell("可见", value: visibleText(v), icon: v.hasPrefix("Yes") ? "eye" : "eye.slash")
                    }
                    if let parent = nonEmpty(d.parent) {
                        divider
                        Button {
                            if case let .galleryDetail(gid, token)? = EhUrlRoute.parseEhUrl(parent) {
                                navigate(.galleryToken(gid: gid, token: token))
                            }
                        } label: {
                            cell("父画廊", value: parentText(parent), icon: "arrow.turn.left.up", tint: .accentColor)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("打开父画廊")
                    }
                }
                divider
                Button(action: onShowInfo) {
                    cell("详情", value: "更多", icon: "info.circle", tint: .accentColor)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("画廊信息")
            }
            .padding(.vertical, 6)
        }
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var divider: some View {
        Divider().frame(height: 30)
    }

    private func cell(_ title: String, value: String, icon: String, tint: Color = .primary) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Image(systemName: icon).font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(value).font(.footnote.weight(.semibold)).foregroundStyle(tint).lineLimit(1)
        }
        .frame(minWidth: 72, minHeight: 44)
        .padding(.horizontal, 8)
        .accessibilityElement(children: .combine)
    }

    private func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    private func visibleText(_ v: String) -> String {
        if v == "Yes" { return "是" }
        if v.hasPrefix("No") {
            let reason = v.replacingOccurrences(of: "No", with: "").trimmingCharacters(in: CharacterSet(charactersIn: " ()"))
            return reason.isEmpty ? "否" : "否（\(reason)）"
        }
        return v
    }

    private func parentText(_ url: String) -> String {
        if case let .galleryDetail(gid, _)? = EhUrlRoute.parseEhUrl(url) { return "\(gid)" }
        return "打开"
    }
}

/// 主操作区：阅读、下载 + 收藏 / 评分 / 种子 / 归档 / 相似
struct DetailActionBar: View {
    @Environment(AppModel.self) private var model
    let vm: GalleryDetailModel
    let info: GalleryInfo
    let onRead: (Int?) -> Void
    let onFavorite: () -> Void
    let onQuickFavorite: (Int) -> Void
    let onRemoveFavorite: () -> Void
    let onRate: () -> Void
    let onTorrent: () -> Void
    let onArchive: () -> Void
    let onSimilar: () -> Void
    @State private var confirmDeleteDownload = false
    @ScaledMetric(relativeTo: .title3) private var iconHeight: CGFloat = 24

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Button { onRead(nil) } label: {
                    VStack(spacing: 2) {
                        Label(readTitle, systemImage: "book.fill").font(.body.weight(.semibold))
                        if let p = vm.readProgress, info.pages > 0 {
                            Text("第 \(p + 1) / \(info.pages) 页").font(.caption2).opacity(0.85)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .contextMenu {
                    Button { onRead(0) } label: { Label("从头阅读", systemImage: "arrow.counterclockwise") }
                    if let p = vm.readProgress {
                        Button { onRead(p) } label: { Label("继续阅读第 \(p + 1) 页", systemImage: "book") }
                    }
                }

                downloadControl
                    .buttonStyle(.bordered)
                    .controlSize(.large)
            }

            HStack(spacing: 0) {
                favoriteButton
                actionButton(ratingTitle, icon: info.rated ? "star.fill" : "star", enabled: vm.detail != nil, action: onRate)
                actionButton(torrentTitle, icon: "arrow.down.doc",
                             enabled: (vm.detail?.torrentCount ?? 0) > 0, action: onTorrent)
                actionButton("归档", icon: "archivebox", enabled: !(vm.detail?.archiveUrl ?? "").isEmpty, action: onArchive)
                actionButton("相似", icon: "square.stack.3d.up", enabled: true, action: onSimilar)
            }
        }
    }

    // MARK: 下载（按状态切换操作）

    @ViewBuilder
    private var downloadControl: some View {
        let state = model.downloadState(gid: info.gid)
        switch state {
        case nil, DownloadInfo.stateInvalid?:
            Button { model.startDownload(info) } label: {
                downloadLabel("下载", icon: "arrow.down.circle")
            }
        case DownloadInfo.stateWait?, DownloadInfo.stateDownload?:
            Menu {
                Button { model.downloads.stopDownload(info.gid) } label: {
                    Label("暂停下载", systemImage: "pause.circle")
                }
                deleteDownloadButton
            } label: {
                downloadLabel(downloadingTitle(state), icon: "arrow.down.circle.dotted")
            }
            .confirmationDialog("删除下载", isPresented: $confirmDeleteDownload) { deleteDownloadActions }
        case DownloadInfo.stateFinish?:
            Menu {
                Button { model.startDownload(info) } label: {
                    Label("重新下载", systemImage: "arrow.clockwise")
                }
                deleteDownloadButton
            } label: {
                downloadLabel("已下载", icon: "checkmark.circle")
            }
            .confirmationDialog("删除下载", isPresented: $confirmDeleteDownload) { deleteDownloadActions }
        default:
            // 已暂停 / 失败
            let failed = state == DownloadInfo.stateFailed
            Menu {
                Button { model.startDownload(info) } label: {
                    Label(failed ? "重试下载" : "继续下载", systemImage: "arrow.down.circle")
                }
                deleteDownloadButton
            } label: {
                downloadLabel(failed ? "下载失败" : "已暂停", icon: failed ? "exclamationmark.circle" : "pause.circle")
            }
            .confirmationDialog("删除下载", isPresented: $confirmDeleteDownload) { deleteDownloadActions }
        }
    }

    private func downloadingTitle(_ state: Int?) -> String {
        if state == DownloadInfo.stateWait { return "等待下载" }
        if let d = model.downloads.downloadInfo(info.gid), d.total > 0 {
            return "下载中 \(d.finished)/\(d.total)"
        }
        return "下载中"
    }

    private func downloadLabel(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.body.weight(.semibold))
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: 34)
    }

    @ViewBuilder private var deleteDownloadButton: some View {
        Button { model.showDownloads() } label: {
            Label("在下载中查看", systemImage: "arrow.down.circle")
        }
        Section {
            Button(role: .destructive) { confirmDeleteDownload = true } label: {
                Label("删除下载", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private var deleteDownloadActions: some View {
        Button("删除下载及文件", role: .destructive) {
            model.deleteDownload(gid: info.gid, deleteFiles: true)
            Haptics.success()
        }
        Button("仅从下载列表移除") {
            model.deleteDownload(gid: info.gid, deleteFiles: false)
            Haptics.success()
        }
        Button("取消", role: .cancel) {}
    }

    private var readTitle: String {
        vm.readProgress != nil ? "继续阅读" : "阅读"
    }

    private var ratingTitle: String {
        info.rated ? "已评分" : "评分"
    }

    private var torrentTitle: String {
        let n = vm.detail?.torrentCount ?? 0
        return n > 0 ? "种子 (\(n))" : "种子"
    }

    private var favoriteButton: some View {
        let name = vm.favoriteDisplayName(model)
        let defaultSlot = model.setting(\.defaultFavSlot)
        return Button(action: onFavorite) {
            actionLabel(name ?? "收藏", icon: vm.isFavorited ? "heart.fill" : "heart",
                        tint: vm.isFavorited ? .pink : .accentColor)
        }
        .buttonStyle(.plain)
        .disabled(vm.isModifyingFavorite || vm.info == nil)
        .contextMenu {
            if (-1...9).contains(defaultSlot) {
                Button { onQuickFavorite(defaultSlot) } label: {
                    Label("快速收藏到「\(slotName(defaultSlot))」", systemImage: "bolt.heart")
                }
            }
            Button(action: onFavorite) { Label("选择收藏夹…", systemImage: "folder") }
            if vm.isFavorited {
                Button(role: .destructive, action: onRemoveFavorite) { Label("移除收藏", systemImage: "heart.slash") }
            }
        }
    }

    private func slotName(_ slot: Int) -> String {
        slot == -1 ? "本地收藏" : model.setting(\.favCat)[slot]
    }

    private func actionButton(_ title: String, icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            actionLabel(title, icon: icon, tint: .accentColor)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }

    private func actionLabel(_ title: String, icon: String, tint: Color) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(minHeight: iconHeight)
                .accessibilityHidden(true)
            Text(title)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .contentShape(Rectangle())
    }
}
