import SwiftUI
import EhCore
import EhNetwork
import EhStorage

/// 标签区：按命名空间分组，点击 tag 弹出菜单。对应 Android `bindTags` + `GalleryListSceneDialog.showTagLongPressDialog`
struct DetailTagSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let groups: [GalleryTagGroup]
    let navigate: (Route) -> Void

    @State private var pendingFilter: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DetailSectionHeader(title: "标签")
            if groups.isEmpty {
                Text("没有标签").font(.subheadline).foregroundStyle(.secondary)
            } else {
                Grid(alignment: .topLeading, horizontalSpacing: 10, verticalSpacing: 10) {
                    ForEach(groups, id: \.groupName) { group in
                        GridRow {
                            Text(model.displayNamespace(group.groupName))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .gridColumnAlignment(.trailing)
                            DetailFlowLayout(spacing: 6, lineSpacing: 6) {
                                ForEach(group.tags, id: \.self) { tag in
                                    tagChip(group: group.groupName, tag: tag)
                                }
                            }
                        }
                    }
                }
            }
        }
        .confirmationDialog(
            "屏蔽标签“\(pendingFilter ?? "")”？",
            isPresented: Binding(get: { pendingFilter != nil }, set: { if !$0 { pendingFilter = nil } }),
            titleVisibility: .visible
        ) {
            Button("加入过滤器", role: .destructive) {
                if let tag = pendingFilter { addFilter(tag) }
            }
        } message: {
            Text("包含此标签的画廊将不会出现在列表中")
        }
    }

    private func tagChip(group: String, tag: String) -> some View {
        let full = "\(group):\(tag)"
        let shown = model.displayTag(tag, namespace: group)
        return Menu {
            Section(shown == tag ? full : "\(shown)\n\(full)") {
                Button { navigate(.list(.tag(full), title: shown)) } label: {
                    Label("搜索此标签", systemImage: "magnifyingglass")
                }
                Button { DetailClipboard.copy(full, model) } label: { Label("复制", systemImage: "doc.on.doc") }
                if shown != tag {
                    Button { DetailClipboard.copy(shown, model) } label: { Label("复制翻译", systemImage: "character.book.closed") }
                }
                Button {
                    if let url = URL(string: EhURL.tagDefinition(tag)) { openURL(url) }
                } label: {
                    Label("查看定义（EhWiki）", systemImage: "book")
                }
            }
            Section {
                Button { watch(full, hide: false) } label: { Label("关注此标签", systemImage: "eye") }
                Button { watch(full, hide: true) } label: { Label("隐藏此标签（My Tags）", systemImage: "eye.slash") }
                Button(role: .destructive) { pendingFilter = full } label: {
                    Label("加入过滤器", systemImage: "line.3.horizontal.decrease.circle")
                }
            }
        } label: {
            Text(shown)
                .font(.footnote)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(Color(.tertiarySystemFill), in: Capsule())
                // 触控区向外扩到约 44pt 高（不改变排版间距）
                .contentShape(.interaction, DetailExpandedHitShape(dx: 3, dy: 9))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(model.displayNamespace(group))：\(shown)")
        .accessibilityHint("显示操作")
    }

    private func addFilter(_ tag: String) {
        do {
            try model.filter.addFilter(Filter(mode: EhFilter.Mode.tag.rawValue, text: tag))
            model.toast.show("已添加过滤器", systemImage: "line.3.horizontal.decrease.circle")
        } catch {
            model.toast.error(error)
        }
    }

    /// 加入 My Tags（关注 / 隐藏）
    private func watch(_ tag: String, hide: Bool) {
        guard model.isSignedIn else {
            model.toast.show("请先登录", systemImage: "person.crop.circle.badge.exclamationmark")
            return
        }
        let api = model.api
        let url = EhURL.myTags(model.site)
        let toast = model.toast
        Task {
            do {
                let param = TagPushParam(tagNameNew: tag, tagWatchNew: hide ? nil : "on", tagHiddenNew: hide ? "on" : nil)
                if try await api.addTag(url: url, param: param) == nil {
                    toast.show("请先登录", systemImage: "person.crop.circle.badge.exclamationmark")
                } else {
                    toast.show(hide ? "已隐藏 \(tag)" : "已关注 \(tag)", systemImage: hide ? "eye.slash" : "eye")
                }
            } catch {
                toast.error(error)
            }
        }
    }
}

/// 比视图本身更大的点按区域
struct DetailExpandedHitShape: Shape {
    var dx: CGFloat
    var dy: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(rect.insetBy(dx: -dx, dy: -dy))
    }
}
