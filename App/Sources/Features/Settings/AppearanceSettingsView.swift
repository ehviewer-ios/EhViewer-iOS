import SwiftUI
import EhStorage

/// 外观：主题、列表样式、缩略图、详情页显示项。由“我的” › 外观 进入（拆分自 Android `EhFragment`）
struct AppearanceSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                Picker("主题", selection: model.themeBinding) {
                    ForEach(AppTheme.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }

            Section {
                SettingsPicker("列表模式", selection: model.binding(\.listMode),
                               options: EhSettings.ListMode.allCases) { $0.title }
                SettingsPicker("详情宽度", selection: model.binding(\.detailSize),
                               options: EhSettings.DetailSize.allCases) { $0.title }
                SettingsPicker("缩略图尺寸", selection: model.binding(\.thumbSize),
                               options: EhSettings.ThumbSize.allCases) { $0.title }
                Toggle("显示阅读进度", isOn: model.binding(\.showReadProgress))
                Toggle("显示页数", isOn: model.binding(\.showGalleryPages))
                Toggle("显示日文标题", isOn: model.binding(\.showJpnTitle))
            } header: {
                Text("画廊列表")
            } footer: {
                Text("“详情宽度”用于详情模式的列表行，“缩略图尺寸”用于缩略图模式的网格。显示页数需要额外的网络请求，列表加载会稍慢。")
            }

            Section {
                SettingsPicker("缩略图分辨率", selection: model.binding(\.thumbResolution),
                               options: EhSettings.ThumbResolution.allCases) { $0.title }
                Toggle("使用备用缩略图地址", isOn: model.binding(\.fixThumbUrl))
            } header: {
                Text("缩略图")
            } footer: {
                Text("备用缩略图地址在部分网络下加载更快。")
            }

            Section("画廊详情") {
                Toggle("显示评论", isOn: model.binding(\.showGalleryComment))
                Toggle("显示评分", isOn: model.binding(\.showGalleryRating))
            }
        }
        .navigationTitle("外观")
        .navigationBarTitleDisplayMode(.inline)
    }
}
