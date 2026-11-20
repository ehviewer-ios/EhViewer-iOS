import SwiftUI
import EhCore

/// 分类筛选 + 高级搜索。对应 Android `CategoryTable` + `AdvanceSearchTable`（SearchLayout 的"高级"页）
struct AdvancedSearchSheet: View {
    typealias Table = ListUrlBuilder.AdvanceSearchTable

    @Environment(\.dismiss) private var dismiss

    /// 应用后的新条件
    var onApply: (ListUrlBuilder) -> Void

    @State private var draft: ListUrlBuilder
    @State private var categories: Set<Int>
    @State private var advanced: Bool
    @State private var flags: Int
    @State private var minRating: Int
    @State private var pageFrom: String
    @State private var pageTo: String
    @ScaledMetric(relativeTo: .body) private var pageFieldWidth: CGFloat = 72
    @ScaledMetric(relativeTo: .footnote) private var categoryMinWidth: CGFloat = 96

    /// 打开时的条件，用于判断是否有未应用的改动
    private let initial: ListUrlBuilder

    init(builder: ListUrlBuilder, onApply: @escaping (ListUrlBuilder) -> Void) {
        self.onApply = onApply
        _draft = State(initialValue: builder)
        let all = EhCategory.ordered.map(\.rawValue)
        let cats: Set<Int>
        if builder.category == EhUtils.NONE || builder.category & EhUtils.ALL_CATEGORY == 0 {
            cats = Set(all)
        } else {
            cats = Set(all.filter { builder.category & $0 != 0 })
        }
        let adv = builder.advanceSearch != -1
        let fl = builder.advanceSearch == -1 ? ListUrlBuilder.DEFAULT_ADVANCE : builder.advanceSearch
        let from = builder.pageFrom > 0 ? String(builder.pageFrom) : ""
        let to = builder.pageTo > 0 ? String(builder.pageTo) : ""
        _categories = State(initialValue: cats)
        _advanced = State(initialValue: adv)
        _flags = State(initialValue: fl)
        _minRating = State(initialValue: builder.minRating)
        _pageFrom = State(initialValue: from)
        _pageTo = State(initialValue: to)
        initial = Self.build(builder, categories: cats, advanced: adv, flags: fl, minRating: builder.minRating,
                             pageFrom: from, pageTo: to)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: categoryMinWidth), spacing: 8)], spacing: 8) {
                        ForEach(EhCategory.ordered, id: \.rawValue) { cat in
                            categoryToggle(cat)
                        }
                    }
                    .padding(.vertical, 4)
                    let all = Set(EhCategory.ordered.map(\.rawValue))
                    let allSelected = categories == all
                    Button(allSelected ? "取消全选" : "全选") {
                        categories = allSelected ? [] : all
                    }
                } header: {
                    Text("分类")
                } footer: {
                    if categories.isEmpty { Text("未选择任何分类时视为全部分类") }
                }

                Section {
                    Toggle("启用高级搜索", isOn: $advanced)
                }

                if advanced {
                    Section("搜索范围") {
                        flagToggle("搜索画廊名称", Table.SNAME)
                        flagToggle("搜索标签", Table.STAGS)
                        flagToggle("搜索画廊描述", Table.SDESC)
                        flagToggle("搜索种子文件名", Table.STORR)
                        flagToggle("搜索低权重标签", Table.SDT1)
                        flagToggle("搜索被否决的标签", Table.SDT2)
                    }
                    Section("结果") {
                        flagToggle("只显示有种子的画廊", Table.STO)
                        flagToggle("显示已删除的画廊", Table.SH)
                        Picker("最低评分", selection: $minRating) {
                            Text("不限").tag(-1)
                            ForEach(2...5, id: \.self) { r in
                                Text("\(r) 星").tag(r)
                            }
                        }
                        HStack {
                            Text("页数")
                            Spacer()
                            TextField("最少", text: $pageFrom)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.center)
                                .frame(width: pageFieldWidth)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel(Text("最少页数"))
                            Text("至")
                            TextField("最多", text: $pageTo)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.center)
                                .frame(width: pageFieldWidth)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel(Text("最多页数"))
                        }
                    }
                    Section("禁用默认过滤") {
                        flagToggle("语言", Table.SFL)
                        flagToggle("上传者", Table.SFU)
                        flagToggle("标签", Table.SFT)
                    }
                }

                Section {
                    Button("恢复默认") {
                        categories = Set(EhCategory.ordered.map(\.rawValue))
                        advanced = false
                        flags = ListUrlBuilder.DEFAULT_ADVANCE
                        minRating = -1
                        pageFrom = ""
                        pageTo = ""
                    }
                    .disabled(isDefault)
                }
            }
            .interactiveDismissDisabled(hasChanges)
            .navigationTitle("筛选")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("应用") {
                        onApply(result)
                        dismiss()
                    }
                }
            }
        }
    }

    /// 与打开时相比是否有改动（有改动时禁止下滑关闭，避免误丢）
    private var hasChanges: Bool { result != initial }

    /// 是否已是默认条件
    private var isDefault: Bool {
        categories.count == EhCategory.ordered.count && !advanced && flags == ListUrlBuilder.DEFAULT_ADVANCE
            && minRating <= 0 && pageFrom.isEmpty && pageTo.isEmpty
    }

    private var result: ListUrlBuilder {
        Self.build(draft, categories: categories, advanced: advanced, flags: flags, minRating: minRating,
                   pageFrom: pageFrom, pageTo: pageTo)
    }

    private static func build(_ draft: ListUrlBuilder, categories: Set<Int>, advanced: Bool, flags: Int,
                              minRating: Int, pageFrom: String, pageTo: String) -> ListUrlBuilder {
        var b = draft
        let all = EhCategory.ordered.map(\.rawValue)
        if categories.isEmpty || categories.count == all.count {
            b.category = EhUtils.NONE
        } else {
            b.category = categories.reduce(0, |)
        }
        if advanced {
            b.advanceSearch = flags
            b.minRating = minRating
            b.pageFrom = Int(pageFrom.trimmingCharacters(in: .whitespaces)) ?? -1
            b.pageTo = Int(pageTo.trimmingCharacters(in: .whitespaces)) ?? -1
        } else {
            b.advanceSearch = -1
            b.minRating = -1
            b.pageFrom = -1
            b.pageTo = -1
        }
        b.pageIndex = 0
        return b
    }

    private func categoryToggle(_ cat: EhCategory) -> some View {
        let on = categories.contains(cat.rawValue)
        return Button {
            if on { categories.remove(cat.rawValue) } else { categories.insert(cat.rawValue) }
        } label: {
            HStack(spacing: 4) {
                // 选中态不只靠颜色区分
                Image(systemName: on ? "checkmark" : "circle")
                    .font(.caption2.weight(.bold))
                    .opacity(on ? 1 : 0.5)
                    .accessibilityHidden(true)
                Text(cat.displayName)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(on ? cat.foregroundColor : Color.secondary)
            .background(on ? cat.color : Color.secondary.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func flagToggle(_ title: String, _ bit: Int) -> some View {
        Toggle(title, isOn: Binding(
            get: { flags & bit != 0 },
            set: { flags = $0 ? (flags | bit) : (flags & ~bit) }
        ))
    }
}
