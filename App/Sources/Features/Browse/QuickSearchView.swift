import SwiftUI
import EhCore
import EhStorage

extension ListUrlBuilder {
    /// 对应 Android `ListUrlBuilder.set(QuickSearch)`
    init(quickSearch q: QuickSearch) {
        self.init()
        mode = Mode(rawValue: q.mode) ?? .normal
        category = q.category
        keyword = q.keyword
        advanceSearch = q.advanceSearch
        minRating = q.minRating
        pageFrom = q.pageFrom
        pageTo = q.pageTo
    }

    /// 对应 `toQuickSearch()`
    func toQuickSearch(name: String) -> QuickSearch {
        QuickSearch(name: name, mode: mode.rawValue, category: category, keyword: keyword,
                    advanceSearch: advanceSearch, minRating: minRating, pageFrom: pageFrom, pageTo: pageTo)
    }

    /// 对应 `equalsQuickSearch`
    func equals(quickSearch q: QuickSearch) -> Bool {
        q.mode == mode.rawValue && q.category == category && (q.keyword ?? "") == (keyword ?? "")
            && q.advanceSearch == advanceSearch && q.minRating == minRating
            && q.pageFrom == pageFrom && q.pageTo == pageTo
    }
}

/// 快速搜索列表：点击应用，左滑删除，编辑排序，可把当前条件保存为快速搜索。
/// 对应 Android `GalleryListScene` 右侧抽屉的快速搜索列表 + `QuickSearchScene`
struct QuickSearchView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model

    /// 当前列表条件（用于"添加当前搜索"）
    let current: ListUrlBuilder
    /// 当前条件的默认名称
    let suggestedName: String
    var onSelect: (ListUrlBuilder) -> Void

    @State private var list: [QuickSearch] = []
    @State private var showAdd = false
    @State private var newName = ""
    @State private var editing: QuickSearch?
    @State private var editName = ""
    @State private var editMode: EditMode = .inactive

    private var isEditing: Bool { editMode.isEditing }

    var body: some View {
        NavigationStack {
            Group {
                if list.isEmpty {
                    EmptyStateView(title: "没有快速搜索", systemImage: "bookmark",
                                   message: addBlockedReason ?? "搜索后点击右上角的“+”即可把当前搜索条件保存为快速搜索。")
                } else {
                    List {
                        Section {
                            ForEach(list, id: \.id) { q in
                                row(q)
                            }
                            .onDelete { offsets in
                                for i in offsets { delete(list[i]) }
                            }
                            .onMove(perform: move)
                        } footer: {
                            if let addBlockedReason, !isEditing { Text(addBlockedReason) }
                        }
                    }
                }
            }
            .navigationTitle("快速搜索")
            .navigationBarTitleDisplayMode(.inline)
            .environment(\.editMode, $editMode)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !list.isEmpty {
                        Button(isEditing ? "完成" : "编辑") {
                            withAnimation { editMode = isEditing ? .inactive : .active }
                        }
                        .fontWeight(isEditing ? .semibold : .regular)
                    }
                }
                ToolbarItemGroup(placement: .confirmationAction) {
                    if !isEditing {
                        Button {
                            newName = suggestedName
                            showAdd = true
                        } label: {
                            Label("添加当前搜索", systemImage: "plus")
                        }
                        .disabled(addBlockedReason != nil)
                        closeButton
                    }
                }
            }
            .alert("添加快速搜索", isPresented: $showAdd) {
                TextField("名称", text: $newName)
                Button("取消", role: .cancel) {}
                Button("添加") { add() }
                    .disabled(!isValidName(newName, excluding: nil))
            } message: {
                Text("名称不能为空，也不能与已有的快速搜索重名。")
            }
            .alert("重命名", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
                TextField("名称", text: $editName)
                Button("取消", role: .cancel) { editing = nil }
                Button("保存") { rename() }
                    .disabled(!isValidName(editName, excluding: editing))
            } message: {
                Text("名称不能为空，也不能与已有的快速搜索重名。")
            }
            .task { reload() }
        }
    }

    @ViewBuilder
    private var closeButton: some View {
        if #available(iOS 26, *) {
            Button(role: .close) { dismiss() }
        } else {
            Button("完成") { dismiss() }
        }
    }

    private func row(_ q: QuickSearch) -> some View {
        Button {
            onSelect(ListUrlBuilder(quickSearch: q))
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(q.name ?? q.keyword ?? "未命名").foregroundStyle(.primary)
                let detail = describe(q)
                if !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { delete(q) } label: { Label("删除", systemImage: "trash") }
            Button {
                beginRename(q)
            } label: { Label("重命名", systemImage: "pencil") }
                .tint(.orange)
        }
        .contextMenu {
            Button {
                beginRename(q)
            } label: { Label("重命名", systemImage: "pencil") }
            Button(role: .destructive) { delete(q) } label: { Label("删除", systemImage: "trash") }
        }
    }

    private func beginRename(_ q: QuickSearch) {
        editName = q.name ?? ""
        editing = q
    }

    private func reload() {
        list = (try? model.database.allQuickSearch()) ?? []
    }

    /// 当前条件不能保存为快速搜索的原因（nil 表示可以保存）
    private var addBlockedReason: String? {
        if current.mode == .imageSearch { return "以图搜图的结果不能保存为快速搜索。" }
        if let dup = list.first(where: { current.equals(quickSearch: $0) }) {
            return "当前搜索条件已保存为“\(dup.name ?? "")”。"
        }
        return nil
    }

    private func isValidName(_ raw: String, excluding: QuickSearch?) -> Bool {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
        return !list.contains { $0.name == name && $0.id != excluding?.id }
    }

    private func add() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidName(name, excluding: nil), addBlockedReason == nil else { return }
        do {
            try model.database.insertQuickSearch(current.toQuickSearch(name: name))
            reload()
        } catch {
            model.toast.error(error)
        }
    }

    private func rename() {
        guard var q = editing else { return }
        editing = nil
        let name = editName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidName(name, excluding: q) else { return }
        q.name = name
        do {
            try model.database.updateQuickSearch(q)
            reload()
        } catch {
            model.toast.error(error)
        }
    }

    private func delete(_ q: QuickSearch) {
        do {
            try model.database.deleteQuickSearch(q)
            reload()
        } catch {
            model.toast.error(error)
        }
    }

    private func move(from source: IndexSet, to destination: Int) {
        guard let from = source.first else { return }
        let to = destination > from ? destination - 1 : destination
        guard from != to else { return }
        list.move(fromOffsets: source, toOffset: destination)
        do {
            try model.database.moveQuickSearch(from: from, to: to)
        } catch {
            model.toast.error(error)
        }
        reload()
    }

    private func describe(_ q: QuickSearch) -> String {
        var parts: [String] = []
        switch ListUrlBuilder.Mode(rawValue: q.mode) ?? .normal {
        case .uploader: parts.append("上传者")
        case .tag: parts.append("标签")
        case .subscription: parts.append("订阅")
        default: break
        }
        if let k = q.keyword, !k.isEmpty, k != q.name { parts.append(k) }
        if q.category != EhUtils.NONE, q.category & EhUtils.ALL_CATEGORY != 0 {
            let n = EhCategory.ordered.filter { q.category & $0.rawValue != 0 }.count
            parts.append("\(n) 个分类")
        }
        if q.advanceSearch != -1 { parts.append("高级搜索") }
        return parts.joined(separator: " · ")
    }
}
