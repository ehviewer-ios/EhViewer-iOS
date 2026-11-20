import SwiftUI
import EhStorage
import EhSpider

/// 下载标签管理：新增 / 重命名 / 删除 / 拖动排序。对应 Android `DownloadLabelsScene`
struct DownloadLabelsView: View {
    @Environment(AppModel.self) private var model

    fileprivate enum EditorKind: Identifiable {
        case add
        case rename(String)
        var id: String {
            switch self {
            case .add: return "\u{1}add"
            case let .rename(l): return l
            }
        }
    }

    @State private var editor: EditorKind?
    @State private var pendingDelete: String?

    private var downloads: DownloadManager { model.downloads }

    var body: some View {
        List {
            Section {
                HStack {
                    Label("默认", systemImage: "tray")
                    Spacer()
                    Text("\(downloads.labelCount(nil))").foregroundStyle(.secondary).monospacedDigit()
                }
            } footer: {
                Text("删除标签后，其中的下载项会移到“默认”。")
            }

            Section("标签") {
                if downloads.labelList.isEmpty {
                    Text("还没有标签").foregroundStyle(.secondary)
                }
                ForEach(downloads.labelList.compactMap(\.label), id: \.self) { label in
                    Button {
                        beginRename(label)
                    } label: {
                        HStack {
                            Label(label, systemImage: "tag")
                            Spacer()
                            Text("\(downloads.labelCount(label))").foregroundStyle(.secondary).monospacedDigit()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text("重命名"))
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            pendingDelete = label
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                        Button {
                            beginRename(label)
                        } label: {
                            Label("重命名", systemImage: "pencil")
                        }
                        .tint(.orange)
                    }
                    .contextMenu {
                        Button {
                            beginRename(label)
                        } label: {
                            Label("重命名", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            pendingDelete = label
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
                .onMove { source, destination in
                    guard let from = source.first else { return }
                    let to = destination > from ? destination - 1 : destination
                    downloads.moveLabel(from: from, to: to)
                }
            }
        }
        .navigationTitle("下载标签")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !downloads.labelList.isEmpty { EditButton() }
                Button {
                    editor = .add
                } label: {
                    Label("新建标签", systemImage: "plus")
                }
            }
        }
        .sheet(item: $editor) { kind in
            LabelEditorSheet(kind: kind, validate: { validate($0, original: kind.original) }) { name in
                commit(kind, name: name)
            }
            .presentationDetents([.medium])
        }
        .confirmationDialog("删除标签“\(pendingDelete ?? "")”？", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
        ), titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let l = pendingDelete { delete(l) }
                pendingDelete = nil
            }
        } message: {
            Text("其中的 \(downloads.labelCount(pendingDelete)) 个下载项会移到“默认”。")
        }
    }

    private func beginRename(_ label: String) {
        editor = .rename(label)
    }

    /// 校验：非空、不能叫“默认”、不能重复。对应 `NewLabelDialogHelper` / `RenameLabelDialogHelper`。
    /// 返回 nil 表示可以保存
    private func validate(_ name: String, original: String?) -> String? {
        if name.isEmpty { return "" }
        if name == "默认" { return "不能使用“默认”作为标签名。" }
        if name != original, downloads.containLabel(name) { return "已有同名标签。" }
        return nil
    }

    private func commit(_ kind: EditorKind, name: String) {
        switch kind {
        case .add:
            downloads.addLabel(name)
        case let .rename(old):
            guard old != name else { return }
            downloads.renameLabel(from: old, to: name)
            let s = model.settings
            if s.defaultDownloadLabel == old { s.defaultDownloadLabel = name }
            if s.recentDownloadLabel == old { s.recentDownloadLabel = name }
            model.settingsDidChange()
        }
    }

    private func delete(_ label: String) {
        downloads.deleteLabel(label)
        let s = model.settings
        if s.defaultDownloadLabel == label {
            s.defaultDownloadLabel = nil
            s.hasDefaultDownloadLabel = false
        }
        if s.recentDownloadLabel == label { s.recentDownloadLabel = nil }
        model.settingsDidChange()
    }
}

private extension DownloadLabelsView.EditorKind {
    var original: String? {
        if case let .rename(l) = self { return l }
        return nil
    }
}

/// 新建 / 重命名标签：校验错误就地显示在 footer，按钮在不可保存时禁用
private struct LabelEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let kind: DownloadLabelsView.EditorKind
    /// 返回 nil 表示可保存；空串表示不可保存但无需说明
    var validate: (String) -> String?
    var onCommit: (String) -> Void

    @State private var text: String
    @FocusState private var focused: Bool

    init(kind: DownloadLabelsView.EditorKind, validate: @escaping (String) -> String?,
         onCommit: @escaping (String) -> Void) {
        self.kind = kind
        self.validate = validate
        self.onCommit = onCommit
        _text = State(initialValue: kind.original ?? "")
    }

    private var name: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var error: String? { validate(name) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("标签名", text: $text)
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit(save)
                } footer: {
                    if let error, !error.isEmpty {
                        Label(error, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(kind.original == nil ? "新建标签" : "重命名标签")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(kind.original == nil ? "添加" : "保存", action: save)
                        .disabled(error != nil)
                }
            }
            .onAppear { focused = true }
        }
    }

    private func save() {
        guard error == nil else { return }
        onCommit(name)
        dismiss()
    }
}
