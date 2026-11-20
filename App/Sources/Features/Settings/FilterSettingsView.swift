import SwiftUI
import EhStorage

/// 画廊过滤器。对应 Android `FilterActivity`：标题 / 上传者 / 标签 / 命名空间四类，增删启停
struct FilterSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var lists: [EhFilter.Mode: [Filter]] = [:]
    @State private var showAdd = false

    var body: some View {
        List {
            if lists.values.allSatisfy(\.isEmpty) {
                Section {
                    EmptyStateView(title: "没有过滤规则", systemImage: "line.3.horizontal.decrease.circle",
                                   message: "匹配规则的画廊不会出现在列表中。可在画廊详情的标签菜单中快速添加。")
                }
                .listRowBackground(Color.clear)
            }
            ForEach(EhFilter.Mode.allCases, id: \.self) { mode in
                if let items = lists[mode], !items.isEmpty {
                    Section(mode.title) {
                        ForEach(items) { f in
                            Toggle(isOn: Binding(get: { f.isEnabled }, set: { _ in toggle(f) })) {
                                Text(f.text ?? "")
                                    .foregroundStyle(f.isEnabled ? .primary : .secondary)
                            }
                        }
                        .onDelete { idx in
                            for i in idx { delete(items[i]) }
                        }
                    }
                }
            }
        }
        .navigationTitle("过滤器")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showAdd = true } label: { Label("添加过滤器", systemImage: "plus") }
            }
        }
        .sheet(isPresented: $showAdd) {
            AddFilterSheet { mode, text in add(mode: mode, text: text) }
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        let f = model.filter
        lists = [
            .title: f.titleFilterList,
            .uploader: f.uploaderFilterList,
            .tag: f.tagFilterList,
            .tagNamespace: f.tagNamespaceFilterList,
        ]
    }

    private func add(mode: EhFilter.Mode, text: String) {
        let exists = (lists[mode] ?? []).contains {
            mode == .uploader ? $0.text == text : $0.text == text.lowercased()
        }
        guard !exists else {
            model.toast.show("规则已存在", systemImage: "exclamationmark.circle")
            return
        }
        do {
            try model.filter.addFilter(Filter(mode: mode.rawValue, text: text))
            reload()
        } catch {
            model.toast.error(error)
        }
    }

    private func toggle(_ f: Filter) {
        do {
            try model.filter.triggerFilter(f)
            reload()
        } catch {
            model.toast.error(error)
        }
    }

    private func delete(_ f: Filter) {
        do {
            try model.filter.deleteFilter(f)
            reload()
        } catch {
            model.toast.error(error)
        }
    }
}

private struct AddFilterSheet: View {
    let onAdd: (EhFilter.Mode, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var mode: EhFilter.Mode = .title
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                Picker("类型", selection: $mode) {
                    ForEach(EhFilter.Mode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                TextField(mode.placeholder, text: $text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit(save)
            }
            .navigationTitle("添加过滤规则")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加", action: save).disabled(trimmed.isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func save() {
        guard !trimmed.isEmpty else { return }
        onAdd(mode, trimmed)
        dismiss()
    }
}

/// 评论黑名单。对应 Android `BlackListActivity`
struct BlackListSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var items: [BlackList] = []
    @State private var showAdd = false
    @State private var newName = ""
    @State private var newReason = ""

    var body: some View {
        List {
            if items.isEmpty {
                EmptyStateView(title: "黑名单为空", systemImage: "person.crop.circle.badge.checkmark",
                               message: "黑名单中用户的评论将被隐藏。可在评论的菜单中把用户加入黑名单。")
                    .listRowBackground(Color.clear)
            }
            ForEach(items) { b in
                VStack(alignment: .leading, spacing: 3) {
                    Text(b.badgayname ?? "").font(.body.weight(.medium))
                    if let reason = b.angrywith ?? b.reason, !reason.isEmpty {
                        Text(reason).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                    }
                    if let t = b.add_time {
                        Text(t).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            .onDelete { idx in
                for i in idx { remove(items[i]) }
            }
        }
        .navigationTitle("评论黑名单")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showAdd = true } label: { Label("加入黑名单", systemImage: "plus") }
            }
        }
        .alert("加入黑名单", isPresented: $showAdd) {
            TextField("用户名", text: $newName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("备注（可选）", text: $newReason)
            Button("取消", role: .cancel) { newName = ""; newReason = "" }
            Button("添加") { add() }
        } message: {
            Text("此用户的评论将被隐藏。")
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        items = ((try? model.database.allBlackList()) ?? []).reversed()
    }

    private func add() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = newReason.trimmingCharacters(in: .whitespacesAndNewlines)
        newName = ""; newReason = ""
        guard !name.isEmpty else { return }
        if model.filter.isBlacklisted(name) {
            model.toast.show("已在黑名单中", systemImage: "exclamationmark.circle")
            return
        }
        do {
            try model.filter.addToBlackList(BlackList.fromComment(user: name, comment: reason.isEmpty ? nil : reason))
            reload()
        } catch {
            model.toast.error(error)
        }
    }

    private func remove(_ b: BlackList) {
        do {
            try model.filter.removeFromBlackList(b)
            reload()
        } catch {
            model.toast.error(error)
        }
    }
}
