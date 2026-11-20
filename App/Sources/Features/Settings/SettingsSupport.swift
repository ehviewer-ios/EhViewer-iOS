import SwiftUI
import EhCore
import EhStorage

// MARK: - 主题

/// iOS 上的主题选项：跟随系统 / 浅色 / 深色。
/// 映射到 Android 的 `theme`（0 浅色 / 1 深色 / 2 纯黑）+ `theme_auto_switch`（跟随系统）。
enum AppTheme: String, CaseIterable, Hashable {
    case system, light, dark

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// 从设置读取。两个 key 都未设置（全新安装）时按 iOS 习惯跟随系统
    static func from(_ s: EhSettings) -> AppTheme {
        if !s.contains(EhSettings.Key.theme) && !s.contains(EhSettings.Key.themeAutoSwitch) { return .system }
        if s.themeAutoSwitch { return .system }
        return s.theme == .light ? .light : .dark
    }

    func apply(to s: EhSettings) {
        switch self {
        case .system:
            s.themeAutoSwitch = true
        case .light:
            s.themeAutoSwitch = false
            s.theme = .light
        case .dark:
            s.themeAutoSwitch = false
            if s.theme == .light { s.theme = .dark }
        }
    }
}

extension AppModel {
    /// 根视图应使用的配色（nil 为跟随系统）。RootView 需 `.preferredColorScheme(model.preferredColorScheme)`
    var preferredColorScheme: ColorScheme? {
        _ = setting(\.themeAutoSwitch)
        return AppTheme.from(settings).colorScheme
    }

    /// 站点切换：切到里站时把登录 cookie 复制到 exhentai.org
    var siteBinding: Binding<EhSite> {
        Binding(
            get: { self.site },
            set: { site in
                if site == .ex && self.isSignedIn { self.cookieStore.copyLoginCookiesToEx() }
                self.site = site
            }
        )
    }

    var themeBinding: Binding<AppTheme> {
        Binding(
            get: { _ = self.setting(\.theme); return AppTheme.from(self.settings) },
            set: { $0.apply(to: self.settings); self.settingsDidChange() }
        )
    }

    /// 映射某个设置到另一种类型的 Binding
    func binding<T, U>(_ keyPath: ReferenceWritableKeyPath<EhSettings, T>, network: Bool = false,
                       get: @escaping (T) -> U, set: @escaping (U) -> T) -> Binding<U> {
        let b = binding(keyPath, network: network)
        return Binding(get: { get(b.wrappedValue) }, set: { b.wrappedValue = set($0) })
    }
}

// MARK: - 枚举文案

extension EhSettings.LaunchPage {
    var title: String {
        switch self {
        case .homepage: return "首页"
        case .subscription: return "订阅"
        case .whatsHot: return "热门"
        }
    }
}

extension EhSettings.ListMode {
    var title: String { self == .detail ? "详情" : "缩略图" }
}

extension EhSettings.DetailSize {
    var title: String { self == .long ? "长" : "短" }
}

extension EhSettings.ThumbSize {
    var title: String {
        switch self {
        case .large: return "大"
        case .middle: return "中"
        case .small: return "小"
        }
    }
}

extension EhSettings.ThumbResolution {
    var title: String {
        switch self {
        case .auto: return "自动"
        case .x250: return "250x"
        case .x300: return "300x"
        }
    }
}

extension EhSettings.ScreenRotation {
    /// iOS 只提供 自动 / 竖屏 / 横屏（Android 的“跟随传感器”并入自动）
    static var iosOptions: [EhSettings.ScreenRotation] { [.default, .portrait, .landscape] }

    var title: String {
        switch self {
        case .default, .sensor: return "自动"
        case .portrait: return "竖屏"
        case .landscape: return "横屏"
        }
    }
}

extension EhSettings.ReadingDirection {
    var title: String {
        switch self {
        case .leftToRight: return "从左到右"
        case .rightToLeft: return "从右到左"
        case .topToBottom: return "从上到下（条漫）"
        }
    }
}

extension EhSettings.PageScaling {
    var title: String {
        switch self {
        case .origin: return "原始尺寸"
        case .fitWidth: return "适应宽度"
        case .fitHeight: return "适应高度"
        case .fit: return "适应屏幕"
        case .fixed: return "固定比例"
        }
    }
}

extension EhSettings.StartPosition {
    var title: String {
        switch self {
        case .topLeft: return "左上"
        case .topRight: return "右上"
        case .bottomLeft: return "左下"
        case .bottomRight: return "右下"
        case .center: return "居中"
        }
    }
}

extension EhSettings.ImageResolution {
    /// 980x 已被站点下线，不再提供
    static var options: [EhSettings.ImageResolution] { [.auto, .x780, .x1280, .x1600, .x2400] }

    var title: String { self == .auto ? "自动" : rawValue + "x" }
}

extension EhSettings.ProxyType {
    var title: String {
        switch self {
        case .direct: return "直连"
        case .system: return "系统代理"
        case .http: return "HTTP"
        case .socks: return "SOCKS"
        }
    }
}

extension EhSite {
    var title: String { self == .e ? "E-Hentai" : "ExHentai" }
}

extension EhFilter.Mode {
    var title: String {
        switch self {
        case .title: return "标题"
        case .uploader: return "上传者"
        case .tag: return "标签"
        case .tagNamespace: return "标签命名空间"
        }
    }

    var placeholder: String {
        switch self {
        case .title: return "标题中包含的文字"
        case .uploader: return "上传者名称"
        case .tag: return "如 female:sole female 或 sole female"
        case .tagNamespace: return "如 parody"
        }
    }
}

// MARK: - 通用视图

/// 设置页里的“说明”脚注
struct SettingsFooter: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text) }
}

/// SettingsPicker 的呈现样式
enum SettingsPickerStyle {
    /// 系统默认（Form 中为菜单）
    case automatic
    /// 进入二级页选择（选项较多时使用，与“设置”App 一致）
    case navigationLink
    case menu
    case inline
    case segmented
}

/// 通用选项 Picker
struct SettingsPicker<T: Hashable>: View {
    let title: String
    @Binding var selection: T
    let options: [T]
    let style: SettingsPickerStyle
    let label: (T) -> String

    init(_ title: String, selection: Binding<T>, options: [T], style: SettingsPickerStyle = .automatic,
         label: @escaping (T) -> String) {
        self.title = title
        _selection = selection
        self.options = options
        self.style = style
        self.label = label
    }

    var body: some View {
        let picker = Picker(title, selection: $selection) {
            ForEach(options, id: \.self) { Text(label($0)).tag($0) }
        }
        switch style {
        case .automatic: picker
        case .navigationLink: picker.pickerStyle(.navigationLink)
        case .menu: picker.pickerStyle(.menu)
        case .inline: picker.pickerStyle(.inline)
        case .segmented: picker.pickerStyle(.segmented)
        }
    }
}

enum SettingsFormat {
    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    /// 目录总大小（递归）
    static func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey],
                                    options: [], errorHandler: nil) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in e {
            guard let v = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]),
                  v.isRegularFile == true else { continue }
            total += Int64(v.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}
