import SwiftUI
import EhCore
import EhNetwork

/// 我的标签（My Tags / 订阅标签）。列表来自 `getWatchedList`，支持添加（`addTag`）与删除（`deleteWatchedTag`）。
/// Android 的 `MyTagsActivity` 只是 WebView；这里做原生列表，并保留网页入口（颜色、权重等高级编辑）
struct MyTagsView: View {
    @Environment(AppModel.self) private var model
    @State private var tags: [UserTag] = []
    @State private var loading = false
    @State private var error: Error?
    @State private var loaded = false
    @State private var showAdd = false
    @State private var filter: TagFilter = .all

    enum TagFilter: String, CaseIterable, Hashable {
        case all, watched, hidden
        var title: String {
            switch self {
            case .all: return "全部"
            case .watched: return "订阅"
            case .hidden: return "隐藏"
            }
        }
    }

    private var url: String { EhURL.myTags(model.site) }

    var body: some View {
        content
            .navigationTitle("我的标签")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showAdd = true } label: { Label("添加标签", systemImage: "plus") }
                        .disabled(!model.isSignedIn)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("显示", selection: $filter) {
                            ForEach(TagFilter.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        NavigationLink {
                            SiteWebPage(title: "我的标签（网页）", url: URL(string: url)!)
                        } label: {
                            Label("网页版", systemImage: "globe")
                        }
                        NavigationLink(value: Route.watched) {
                            Label("订阅的画廊", systemImage: "rectangle.stack")
                        }
                    } label: {
                        Label("更多", systemImage: MoreMenuIcon.systemName)
                    }
                }
            }
            .sheet(isPresented: $showAdd) {
                AddUserTagSheet { param in await add(param) }
            }
            .task(id: model.site) { await load() }
    }

    @ViewBuilder private var content: some View {
        if !model.isSignedIn {
            EmptyStateView(title: "需要登录", systemImage: "person.crop.circle.badge.questionmark",
                           message: "登录后可管理订阅与隐藏的标签。")
        } else if let error, tags.isEmpty {
            ErrorStateView(error: error) { Task { await load() } }
        } else if !loaded {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if tags.isEmpty {
            EmptyStateView(title: "没有标签", systemImage: "tag",
                           message: "轻点右上角的“+”添加订阅或隐藏的标签。")
        } else {
            List {
                Section {
                    ForEach(visibleTags, id: \.userTagId) { tag in
                        row(tag)
                    }
                    .onDelete { idx in
                        let list = visibleTags
                        let targets = idx.map { list[$0] }
                        Task { for t in targets { await delete(t) } }
                    }
                } footer: {
                    Text((filter == .all ? "共 \(visibleTags.count) 个标签。" : "\(filter.title)的标签共 \(visibleTags.count) 个。") + "订阅的标签会出现在“订阅”列表；隐藏的标签对应的画廊不会出现在搜索结果中。")
                }
            }
            .refreshable { await load() }
        }
    }

    private var visibleTags: [UserTag] {
        switch filter {
        case .all: return tags
        case .watched: return tags.filter(\.watched)
        case .hidden: return tags.filter(\.hidden)
        }
    }

    private func row(_ tag: UserTag) -> some View {
        let showTranslation = model.setting(\.showTagTranslations)
        let name = tag.getName(model.tagTranslation, showTranslation: showTranslation) ?? tag.tagName ?? ""
        return HStack(spacing: 10) {
            Circle()
                .fill(Self.color(tag.color) ?? Color.secondary.opacity(0.3))
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                if showTranslation, let raw = tag.tagName, raw != name {
                    Text(raw).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if tag.watched {
                Image(systemName: "eye").foregroundStyle(.tint).accessibilityLabel("订阅")
            }
            if tag.hidden {
                Image(systemName: "eye.slash").foregroundStyle(.red).accessibilityLabel("隐藏")
            }
            if tag.tagWeight != 0 {
                Text("\(tag.tagWeight)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .accessibilityLabel("权重 \(tag.tagWeight)")
            }
        }
        .accessibilityElement(children: .combine)
        .contextMenu {
            if let raw = tag.tagName {
                NavigationLink(value: Route.list(.tag(raw), title: name)) {
                    Label("搜索此标签", systemImage: "magnifyingglass")
                }
                Button("复制", systemImage: "doc.on.doc") { UIPasteboard.general.string = raw }
            }
            Button("删除", systemImage: "trash", role: .destructive) { Task { await delete(tag) } }
        }
    }

    /// "#rrggbb" → Color；"#default" 等返回 nil
    static func color(_ s: String?) -> Color? {
        guard var hex = s?.trimmingCharacters(in: .whitespaces), hex.hasPrefix("#") else { return nil }
        hex.removeFirst()
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
        return Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    // MARK: 网络

    private func load() async {
        guard model.isSignedIn else { return }
        loading = true
        defer { loading = false; loaded = true }
        do {
            tags = try await model.api.getWatchedList(url: url)?.userTags ?? []
            error = nil
        } catch {
            self.error = error
            if !tags.isEmpty { model.toast.error(error) }
        }
    }

    private func add(_ param: TagPushParam) async -> Bool {
        do {
            if let list = try await model.api.addTag(url: url, param: param) {
                tags = list.userTags
            }
            model.toast.show("已添加", systemImage: "checkmark.circle")
            return true
        } catch {
            model.toast.error(error)
            return false
        }
    }

    private func delete(_ tag: UserTag) async {
        let backup = tags
        tags.removeAll { $0.userTagId == tag.userTagId }
        do {
            if let list = try await model.api.deleteWatchedTag(url: url, tag: tag) {
                tags = list.userTags
            }
        } catch {
            tags = backup
            model.toast.error(error)
        }
    }
}

/// 添加用户标签
private struct AddUserTagSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let onAdd: (TagPushParam) async -> Bool

    @State private var name = ""
    @State private var action: Action = .watch
    @State private var useColor = false
    @State private var color: Color = .orange
    @State private var submitting = false

    enum Action: Hashable { case watch, hide, none }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("标签，如 female:sole female", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !suggestions.isEmpty {
                        ForEach(suggestions, id: \.self) { s in
                            Button {
                                name = s.tag
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(s.tag).foregroundStyle(.primary)
                                    Text(s.label).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } footer: {
                    Text("格式为 命名空间:标签名。")
                }
                Section {
                    Picker("操作", selection: $action) {
                        Text("订阅").tag(Action.watch)
                        Text("隐藏").tag(Action.hide)
                        Text("仅标记").tag(Action.none)
                    }
                    .pickerStyle(.segmented)
                    Toggle("自定义颜色", isOn: $useColor)
                    if useColor {
                        ColorPicker("颜色", selection: $color, supportsOpacity: false)
                    }
                }
            }
            .navigationTitle("添加标签")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if submitting {
                        ProgressView()
                    } else {
                        Button("添加", action: submit).disabled(trimmed.isEmpty)
                    }
                }
            }
        }
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private struct Suggestion: Hashable {
        let tag: String
        let label: String
    }

    private var suggestions: [Suggestion] {
        let key = trimmed
        guard key.count >= 2, let t = model.tagTranslation, model.setting(\.showTagTranslations) else { return [] }
        return t.suggest(key).prefix(5).map { s in
            // 翻译库用短前缀（f:xxx），站点需要完整命名空间（female:xxx）
            var tag = s.english
            if let colon = tag.firstIndex(of: ":") {
                let prefix = String(tag[...colon])
                if let ns = TagTranslation.prefixToNamespace(prefix) {
                    tag = ns + ":" + tag[tag.index(after: colon)...]
                }
            }
            return Suggestion(tag: tag, label: s.chinese)
        }
    }

    private func submit() {
        var param = TagPushParam(tagNameNew: trimmed)
        switch action {
        case .watch: param.tagWatchNew = "on"
        case .hide: param.tagHiddenNew = "on"
        case .none: break
        }
        if useColor { param.tagColorNew = Self.hex(color) }
        submitting = true
        Task {
            let ok = await onAdd(param)
            submitting = false
            if ok { dismiss() }
        }
    }

    static func hex(_ c: Color) -> String {
        let ui = UIColor(c)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        func h(_ v: CGFloat) -> String { String(format: "%02X", Int((min(max(v, 0), 1) * 255).rounded())) }
        return "#" + h(r) + h(g) + h(b)
    }
}
