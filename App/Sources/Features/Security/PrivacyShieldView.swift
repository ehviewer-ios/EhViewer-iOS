import SwiftUI

/// 后台隐私遮罩：场景不活跃时由顶层覆盖窗口（`OverlayWindow`）显示，使多任务切换器中看不到内容。
/// 对应 Android `enable_secure`（FLAG_SECURE）。iOS 无法禁止截屏，只做切换器遮罩。
/// 使用不透明背景（材质模糊在快照中仍可能透出轮廓）。
struct PrivacyShieldView: View {
    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            Image(systemName: "lock.fill")
                .font(.largeTitle)
                .imageScale(.large)
                .foregroundStyle(.secondary)
        }
        .accessibilityHidden(true)
    }
}
