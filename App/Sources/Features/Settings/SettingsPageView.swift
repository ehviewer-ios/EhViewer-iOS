import SwiftUI
import EhCore

/// 设置分组页入口（由 `Route.settings(page)` 进入）
struct SettingsPageView: View {
    let page: SettingsPage

    init(page: SettingsPage) {
        self.page = page
    }

    var body: some View {
        switch page {
        case .eh: GeneralSettingsView()
        case .read: ReadSettingsView()
        case .download: DownloadSettingsView()
        case .network: NetworkSettingsView()
        case .privacy: PrivacySettingsView()
        case .filter: FilterSettingsView()
        case .blackList: BlackListSettingsView()
        case .advanced: AdvancedSettingsView()
        case .about: AboutView()
        }
    }
}

extension SettingsPage {
    var title: String {
        switch self {
        case .eh: return "通用"
        case .read: return "阅读"
        case .download: return "下载"
        case .network: return "网络"
        case .privacy: return "隐私与安全"
        case .filter: return "过滤器"
        case .blackList: return "评论黑名单"
        case .advanced: return "高级"
        case .about: return "关于"
        }
    }

    var systemImage: String {
        switch self {
        case .eh: return "gearshape"
        case .read: return "book"
        case .download: return "arrow.down.circle"
        case .network: return "network"
        case .privacy: return "hand.raised"
        case .filter: return "line.3.horizontal.decrease.circle"
        case .blackList: return "person.crop.circle.badge.xmark"
        case .advanced: return "wrench.and.screwdriver"
        case .about: return "info.circle"
        }
    }

    var tint: Color {
        switch self {
        case .eh: return .gray
        case .read: return .orange
        case .download: return .green
        case .network: return .blue
        case .privacy: return .indigo
        case .filter: return .teal
        case .blackList: return .gray
        case .advanced: return .gray
        case .about: return .secondary
        }
    }
}

/// 设置入口行（带彩色图标）
struct SettingsIconLabel: View {
    let title: String
    let systemImage: String
    var tint: Color = .accentColor
    /// 图标底板随动态字体缩放
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 28

    init(title: String, systemImage: String, tint: Color = .accentColor) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: side, height: side)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: side / 4, style: .continuous))
                .accessibilityHidden(true)
        }
    }
}
