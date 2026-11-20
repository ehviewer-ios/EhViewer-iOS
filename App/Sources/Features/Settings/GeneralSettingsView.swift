import SwiftUI
import EhCore
import EhStorage

/// 通用设置（`SettingsPage.eh`）。对应 Android `EhFragment` / `eh_settings.xml` 中与浏览相关的部分；
/// 账号相关项在“账号”页（`AccountView`），外观相关项在“外观”页（`AppearanceSettingsView`），
/// 站点切换只在“我的”页顶部。
struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var updatingTranslation = false

    var body: some View {
        Form {
            browseSection
            tagSection
            otherSection
        }
        .navigationTitle("通用")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: 浏览

    @ViewBuilder private var browseSection: some View {
        Section {
            SettingsPicker("启动页", selection: model.binding(\.launchPage),
                           options: EhSettings.LaunchPage.allCases) { $0.title }
            NavigationLink {
                DefaultCategoriesView()
            } label: {
                LabeledContent("默认分类") { Text(categoriesSummary) }
            }
            NavigationLink {
                ExcludedNamespacesView()
            } label: {
                LabeledContent("排除的标签命名空间") { Text(namespacesSummary) }
            }
            NavigationLink {
                ExcludedLanguagesView()
            } label: {
                LabeledContent("排除的语言") { Text(languagesSummary) }
            }
        } header: {
            Text("浏览")
        } footer: {
            Text("默认分类用于快速搜索与高级搜索。排除的命名空间与语言在登录后生效。")
        }
    }

    // MARK: 标签翻译

    @ViewBuilder private var tagSection: some View {
        Section {
            Toggle("显示标签翻译", isOn: model.binding(\.showTagTranslations))
            Button {
                updateTranslation()
            } label: {
                HStack {
                    Text("立即更新翻译库")
                    Spacer()
                    if updatingTranslation { ProgressView() }
                }
            }
            .disabled(updatingTranslation)
            Link(destination: URL(string: "https://github.com/EhTagTranslation/Database")!) {
                LabeledContent("翻译来源") { Text("EhTagTranslation") }
            }
        } header: {
            Text("标签翻译")
        } footer: {
            if let t = model.tagTranslation {
                Text("已加载翻译库：\(t.name)")
            } else {
                Text("尚未加载翻译库。")
            }
        }
    }

    // MARK: 其他

    @ViewBuilder private var otherSection: some View {
        Section {
            Toggle("移动网络流量提醒", isOn: model.binding(\.cellularNetworkWarning))
            SettingsPicker("历史记录上限", selection: model.binding(\.historyInfoSize),
                           options: historyOptions, style: .navigationLink) { Self.historyTitle($0) }
        } header: {
            Text("其他")
        } footer: {
            Text("开启流量提醒后，使用蜂窝网络下载或阅读时会给出提示。")
        }
    }

    /// 标准选项 + 当前值（导入的 Android 设置可能不在标准选项里，避免 Picker 显示空白）。
    /// “不限”（-1）会被 `EhSettings.historyInfoSize` 规范为最小值，故不提供
    private var historyOptions: [Int] {
        var options = EhSettings.historyInfoSizeOptions.filter { $0 >= EhSettings.defaultHistoryInfoSize }
        let current = model.setting(\.historyInfoSize)
        if !options.contains(current) { options.append(current) }
        return options.sorted { a, b in a < 0 ? false : (b < 0 ? true : a < b) }
    }

    static func historyTitle(_ n: Int) -> String {
        n < 0 ? "不限" : "\(n) 条"
    }

    // MARK: 摘要

    private var categoriesSummary: String {
        let mask = model.setting(\.defaultCategories)
        let n = EhCategory.ordered.filter { mask & $0.rawValue != 0 }.count
        if n == EhCategory.ordered.count { return "全部" }
        return n == 0 ? "无" : "\(n) 项"
    }

    private var namespacesSummary: String {
        let mask = model.setting(\.excludedTagNamespaces)
        let n = ExcludedNamespacesView.items.filter { mask & $0.mask != 0 }.count
        return n == 0 ? "无" : "\(n) 项"
    }

    private var languagesSummary: String {
        let n = ExcludedLanguagesView.parse(model.setting(\.excludedLanguages)).count
        return n == 0 ? "无" : "\(n) 项"
    }

    private func updateTranslation() {
        updatingTranslation = true
        Task {
            await model.loadTagTranslation()
            updatingTranslation = false
            if model.tagTranslation != nil {
                model.toast.show("翻译库已更新", systemImage: "checkmark.circle")
            } else {
                model.toast.show("翻译库更新失败", systemImage: "exclamationmark.circle")
            }
        }
    }
}
