import SwiftUI
import EhStorage

/// 阅读设置。对应 Android `ReadFragment` / `read_settings.xml`
struct ReadSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("版式") {
                SettingsPicker("阅读方向", selection: model.binding(\.readingDirection),
                               options: EhSettings.ReadingDirection.allCases) { $0.title }
                SettingsPicker("缩放模式", selection: model.binding(\.pageScaling),
                               options: EhSettings.PageScaling.allCases) { $0.title }
                SettingsPicker("起始位置", selection: model.binding(\.startPosition),
                               options: EhSettings.StartPosition.allCases) { $0.title }
                Toggle("显示页面间距", isOn: model.binding(\.showPageInterval))
            }

            Section {
                Stepper(value: model.binding(\.startTransferTime), in: 1...15) {
                    LabeledContent("自动翻页间隔") { Text("\(model.setting(\.startTransferTime)) 秒") }
                }
                Toggle("音量键翻页", isOn: model.binding(\.volumePage))
                Toggle("反转音量键", isOn: model.binding(\.reverseVolumePage))
                    .disabled(!model.setting(\.volumePage))
            } header: {
                Text("翻页")
            } footer: {
                Text("音量键翻页会占用音量键，翻页时系统音量会被还原。外接键盘可用方向键或空格键翻页。")
            }

            Section {
                SettingsPicker("屏幕方向", selection: model.binding(\.screenRotation,
                                                                get: { $0 == .sensor ? .default : $0 },
                                                                set: { $0 }),
                               options: EhSettings.ScreenRotation.iosOptions) { $0.title }
                Toggle("保持屏幕常亮", isOn: model.binding(\.keepScreenOn))
                Toggle("全屏阅读", isOn: model.binding(\.readingFullscreen))
            } header: {
                Text("屏幕")
            } footer: {
                Text("“屏幕方向”在阅读器内锁定方向；控制中心的竖排方向锁定优先。全屏阅读会隐藏状态栏。")
            }

            Section("信息栏") {
                Toggle("显示时钟", isOn: model.binding(\.showClock))
                Toggle("显示进度", isOn: model.binding(\.showProgress))
                Toggle("显示电量", isOn: model.binding(\.showBattery))
            }

            Section("亮度") {
                Toggle("自定义亮度", isOn: model.binding(\.customScreenLightness))
                if model.setting(\.customScreenLightness) {
                    Slider(value: model.binding(\.screenLightness, get: { Double($0) }, set: { Int($0.rounded()) }),
                           in: 0...100, step: 1) {
                        Text("亮度")
                    } minimumValueLabel: {
                        Image(systemName: "sun.min").accessibilityLabel("较暗")
                    } maximumValueLabel: {
                        Image(systemName: "sun.max").accessibilityLabel("较亮")
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("阅读")
        .navigationBarTitleDisplayMode(.inline)
    }
}
