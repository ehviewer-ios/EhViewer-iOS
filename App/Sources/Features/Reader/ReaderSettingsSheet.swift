import SwiftUI
import EhStorage

/// 阅读设置面板。对应 Android `GalleryMenuHelper`（dialog_gallery_menu），改动立即生效并写入设置
struct ReaderSettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("阅读方向", selection: model.binding(\.readingDirection)) {
                        ForEach(EhSettings.ReadingDirection.allCases, id: \.self) { Text($0.readerLabel).tag($0) }
                    }
                    Picker("缩放方式", selection: model.binding(\.pageScaling)) {
                        ForEach(EhSettings.PageScaling.allCases, id: \.self) { Text($0.readerLabel).tag($0) }
                    }
                    .disabled(model.setting(\.readingDirection) == .topToBottom)
                    Picker("起始位置", selection: model.binding(\.startPosition)) {
                        ForEach(EhSettings.StartPosition.allCases, id: \.self) { Text($0.readerLabel).tag($0) }
                    }
                    .disabled(model.setting(\.readingDirection) == .topToBottom)
                    // iPad 多任务下无法锁定方向，不提供此项
                    if UIDevice.current.userInterfaceIdiom == .phone {
                        Picker("屏幕方向", selection: model.binding(\.screenRotation)) {
                            ForEach(EhSettings.ScreenRotation.allCases, id: \.self) { Text($0.readerLabel).tag($0) }
                        }
                    }
                    Stepper(value: autoIntervalBinding, in: 1...15) {
                        LabeledContent("自动翻页间隔", value: "\(max(model.setting(\.startTransferTime), 1)) 秒")
                    }
                    Toggle("显示页间距", isOn: model.binding(\.showPageInterval))
                } header: {
                    Text("阅读")
                } footer: {
                    Text(tapZoneDescription)
                }

                Section("显示") {
                    Toggle("全屏阅读", isOn: model.binding(\.readingFullscreen))
                    Toggle("保持屏幕常亮", isOn: model.binding(\.keepScreenOn))
                    Toggle("显示时间", isOn: model.binding(\.showClock))
                    Toggle("显示进度", isOn: model.binding(\.showProgress))
                    Toggle("显示电量", isOn: model.binding(\.showBattery))
                }

                Section {
                    Toggle("音量键翻页", isOn: model.binding(\.volumePage))
                    if model.setting(\.volumePage) {
                        Toggle("反转音量键", isOn: model.binding(\.reverseVolumePage))
                    }
                } header: {
                    Text("按键")
                } footer: {
                    Text("""
                    iOS 不提供音量键事件，此功能通过监听系统音量实现，会带来以下副作用：\
                    阅读时按音量键不再调节音量，也不显示音量提示；\
                    音量处于最低或最高时，进入阅读器会把音量微调一格（离开时恢复）；\
                    可能会与其他正在播放的音频相互影响。
                    """)
                }

                Section {
                    Toggle("自定义亮度", isOn: model.binding(\.customScreenLightness))
                    HStack {
                        Image(systemName: "sun.min").accessibilityHidden(true)
                        Slider(value: lightnessBinding, in: 0...200, step: 1) {
                            Text("亮度")
                        }
                        .accessibilityValue(lightnessDescription)
                        Image(systemName: "sun.max").accessibilityHidden(true)
                    }
                    .foregroundStyle(.secondary)
                    .disabled(!model.setting(\.customScreenLightness))
                } header: {
                    Text("亮度")
                } footer: {
                    Text("滑块中点为系统亮度：向左叠加暗色遮罩（不改变系统亮度），向右提高屏幕亮度。")
                }
            }
            .navigationTitle("阅读设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private var tapZoneDescription: String {
        if model.setting(\.readingDirection) == .topToBottom {
            return "条漫模式：轻点屏幕上部向上滚动一屏，轻点下部向下滚动一屏，轻点中间显示或隐藏工具栏。"
        }
        return "轻点屏幕左右两侧翻页，轻点中间显示或隐藏工具栏；双击中间区域缩放。页面放大时轻点只切换工具栏。"
    }

    private var lightnessDescription: String {
        let v = min(max(model.setting(\.screenLightness), 0), 200)
        if v == 100 { return "系统亮度" }
        if v < 100 { return "调暗 \(100 - v)%" }
        return "调亮 \(v - 100)%"
    }

    private var autoIntervalBinding: Binding<Int> {
        let b = model.binding(\.startTransferTime)
        return Binding(get: { max(b.wrappedValue, 1) }, set: { b.wrappedValue = $0 })
    }

    private var lightnessBinding: Binding<Double> {
        let b = model.binding(\.screenLightness)
        return Binding(get: { Double(min(max(b.wrappedValue, 0), 200)) },
                       set: { b.wrappedValue = Int($0.rounded()) })
    }
}

// MARK: - 文案

extension EhSettings.ReadingDirection {
    var readerLabel: String {
        switch self {
        case .leftToRight: return "从左到右"
        case .rightToLeft: return "从右到左"
        case .topToBottom: return "从上到下（条漫）"
        }
    }

    var readerSymbol: String {
        switch self {
        case .leftToRight: return "arrow.right.square"
        case .rightToLeft: return "arrow.left.square"
        case .topToBottom: return "arrow.down.square"
        }
    }
}

extension EhSettings.PageScaling {
    var readerLabel: String {
        switch self {
        case .origin: return "原始大小"
        case .fitWidth: return "适应宽度"
        case .fitHeight: return "适应高度"
        case .fit: return "适应屏幕"
        case .fixed: return "固定比例"
        }
    }
}

extension EhSettings.StartPosition {
    var readerLabel: String {
        switch self {
        case .topLeft: return "左上"
        case .topRight: return "右上"
        case .bottomLeft: return "左下"
        case .bottomRight: return "右下"
        case .center: return "居中"
        }
    }
}

extension EhSettings.ScreenRotation {
    var readerLabel: String {
        switch self {
        case .default: return "跟随系统"
        case .portrait: return "竖屏"
        case .landscape: return "横屏"
        case .sensor: return "自动旋转"
        }
    }
}
