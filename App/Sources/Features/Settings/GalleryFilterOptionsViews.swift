import SwiftUI
import EhCore
import EhStorage

/// 默认分类（搜索时默认勾选的分类）。对应 Android `default_categories`
struct DefaultCategoriesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let mask = model.binding(\.defaultCategories)
        List {
            Section {
                ForEach(EhCategory.ordered, id: \.rawValue) { cat in
                    let on = mask.wrappedValue & cat.rawValue != 0
                    Button {
                        mask.wrappedValue ^= cat.rawValue
                    } label: {
                        HStack {
                            CategoryBadge(category: cat)
                            Spacer()
                            if on {
                                Image(systemName: "checkmark")
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.tint)
                                    .accessibilityHidden(true)
                            }
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            } footer: {
                Text("快速搜索与高级搜索默认勾选这些分类。")
            }
        }
        .navigationTitle("默认分类")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("全选") { mask.wrappedValue = EhCategory.all.rawValue }
                    Button("全不选") { mask.wrappedValue = 0 }
                } label: {
                    Label("选择", systemImage: "checklist")
                }
            }
        }
    }
}

/// 排除的标签命名空间。对应 Android `excluded_tag_namespaces`（uconfig xns 位掩码）
struct ExcludedNamespacesView: View {
    @Environment(AppModel.self) private var model

    struct Item: Hashable {
        let mask: Int
        let name: String
        let title: String
    }

    static let items: [Item] = [
        Item(mask: EhConfig.namespacesReclass, name: "reclass", title: "重新分类"),
        Item(mask: EhConfig.namespacesLanguage, name: "language", title: "语言"),
        Item(mask: EhConfig.namespacesParody, name: "parody", title: "原作"),
        Item(mask: EhConfig.namespacesCharacter, name: "character", title: "角色"),
        Item(mask: EhConfig.namespacesGroup, name: "group", title: "团队"),
        Item(mask: EhConfig.namespacesArtist, name: "artist", title: "艺术家"),
        Item(mask: EhConfig.namespacesMale, name: "male", title: "男性"),
        Item(mask: EhConfig.namespacesFemale, name: "female", title: "女性"),
    ]

    var body: some View {
        let mask = model.binding(\.excludedTagNamespaces)
        List {
            Section {
                ForEach(Self.items, id: \.self) { item in
                    Toggle(isOn: Binding(
                        get: { mask.wrappedValue & item.mask != 0 },
                        set: { mask.wrappedValue = $0 ? (mask.wrappedValue | item.mask) : (mask.wrappedValue & ~item.mask) }
                    )) {
                        VStack(alignment: .leading) {
                            Text(item.title)
                            Text(item.name).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                Text("搜索时排除这些命名空间下的标签匹配。")
            }
        }
        .navigationTitle("排除的命名空间")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 排除的语言。对应 Android `ExcludedLanguagesActivity`（uconfig xl，形如 "1x1024x2048"）。
/// 每种语言一行，进入二级页用三个开关选择要排除的 原文 / 翻译 / 改编。
struct ExcludedLanguagesView: View {
    @Environment(AppModel.self) private var model

    struct Language: Hashable {
        let title: String
        /// original / translated / rewrite
        let codes: [String]
    }

    static let languages: [Language] = [
        Language(title: "日语", codes: [EhConfig.japaneseOriginal, EhConfig.japaneseTranslated, EhConfig.japaneseRewrite]),
        Language(title: "英语", codes: [EhConfig.englishOriginal, EhConfig.englishTranslated, EhConfig.englishRewrite]),
        Language(title: "中文", codes: [EhConfig.chineseOriginal, EhConfig.chineseTranslated, EhConfig.chineseRewrite]),
        Language(title: "荷兰语", codes: [EhConfig.dutchOriginal, EhConfig.dutchTranslated, EhConfig.dutchRewrite]),
        Language(title: "法语", codes: [EhConfig.frenchOriginal, EhConfig.frenchTranslated, EhConfig.frenchRewrite]),
        Language(title: "德语", codes: [EhConfig.germanOriginal, EhConfig.germanTranslated, EhConfig.germanRewrite]),
        Language(title: "匈牙利语", codes: [EhConfig.hungarianOriginal, EhConfig.hungarianTranslated, EhConfig.hungarianRewrite]),
        Language(title: "意大利语", codes: [EhConfig.italianOriginal, EhConfig.italianTranslated, EhConfig.italianRewrite]),
        Language(title: "韩语", codes: [EhConfig.koreanOriginal, EhConfig.koreanTranslated, EhConfig.koreanRewrite]),
        Language(title: "波兰语", codes: [EhConfig.polishOriginal, EhConfig.polishTranslated, EhConfig.polishRewrite]),
        Language(title: "葡萄牙语", codes: [EhConfig.portugueseOriginal, EhConfig.portugueseTranslated, EhConfig.portugueseRewrite]),
        Language(title: "俄语", codes: [EhConfig.russianOriginal, EhConfig.russianTranslated, EhConfig.russianRewrite]),
        Language(title: "西班牙语", codes: [EhConfig.spanishOriginal, EhConfig.spanishTranslated, EhConfig.spanishRewrite]),
        Language(title: "泰语", codes: [EhConfig.thaiOriginal, EhConfig.thaiTranslated, EhConfig.thaiRewrite]),
        Language(title: "越南语", codes: [EhConfig.vietnameseOriginal, EhConfig.vietnameseTranslated, EhConfig.vietnameseRewrite]),
        Language(title: "不适用", codes: [EhConfig.naOriginal, EhConfig.naTranslated, EhConfig.naRewrite]),
        Language(title: "其他", codes: [EhConfig.otherOriginal, EhConfig.otherTranslated, EhConfig.otherRewrite]),
    ]

    /// 与 `Language.codes` 顺序对应
    static let columns = ["原文", "翻译", "改编"]

    /// 所有代码，按 Android `LANGUAGES` 顺序
    static var allCodes: [String] { languages.flatMap(\.codes) }

    /// 解析设置值（对应 `onInit`：按 "x" 分割，只认数字）
    static func parse(_ s: String?) -> Set<String> {
        guard let s, !s.isEmpty else { return [] }
        let valid = Set(allCodes)
        return Set(s.split(separator: "x").map(String.init).filter { valid.contains($0) })
    }

    /// 序列化（对应 `onClick(mOk)`：按 LANGUAGES 顺序用 "x" 连接）
    static func serialize(_ set: Set<String>) -> String {
        allCodes.filter { set.contains($0) }.joined(separator: "x")
    }

    /// 某语言已排除项的摘要
    static func summary(_ lang: Language, in selection: Set<String>) -> String {
        let on = lang.codes.indices.filter { selection.contains(lang.codes[$0]) }.map { columns[$0] }
        if on.isEmpty { return "不排除" }
        if on.count == columns.count { return "全部" }
        return on.joined(separator: "、")
    }

    var body: some View {
        let selection = Self.parse(model.setting(\.excludedLanguages))
        List {
            Section {
                ForEach(Self.languages, id: \.self) { lang in
                    NavigationLink {
                        ExcludedLanguageDetailView(language: lang)
                    } label: {
                        LabeledContent(lang.title) { Text(Self.summary(lang, in: selection)) }
                    }
                }
            } footer: {
                Text("排除的语言不会出现在搜索结果中。需要登录，并随站点设置生效。")
            }
        }
        .navigationTitle("排除的语言")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("全部排除") { Self.save(Set(Self.allCodes), model: model) }
                    Button("全部不排除") { Self.save([], model: model) }
                } label: {
                    Label("选择", systemImage: "checklist")
                }
            }
        }
    }

    static func save(_ selection: Set<String>, model: AppModel) {
        model.settings.excludedLanguages = serialize(selection)
        model.settingsDidChange()
    }
}

/// 单个语言：原文 / 翻译 / 改编 三个开关
private struct ExcludedLanguageDetailView: View {
    @Environment(AppModel.self) private var model
    let language: ExcludedLanguagesView.Language

    var body: some View {
        Form {
            Section {
                ForEach(language.codes.indices, id: \.self) { i in
                    Toggle(ExcludedLanguagesView.columns[i], isOn: binding(language.codes[i]))
                }
            } header: {
                Text("排除")
            } footer: {
                Text("打开的类型不会出现在搜索结果中。")
            }
        }
        .navigationTitle(language.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func binding(_ code: String) -> Binding<Bool> {
        Binding(
            get: { ExcludedLanguagesView.parse(model.setting(\.excludedLanguages)).contains(code) },
            set: { on in
                var set = ExcludedLanguagesView.parse(model.settings.excludedLanguages)
                if on { set.insert(code) } else { set.remove(code) }
                ExcludedLanguagesView.save(set, model: model)
            }
        )
    }
}
