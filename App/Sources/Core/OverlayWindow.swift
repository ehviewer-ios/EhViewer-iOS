import SwiftUI
import UIKit

/// 顶层覆盖窗口：应用锁、后台隐私遮罩与轻提示都放在这里。
/// 它位于所有 sheet / fullScreenCover 之上（windowLevel = alert + 1），因此：
/// - 阅读器等全屏页面也会被锁屏与隐私遮罩覆盖（多任务切换器快照不泄露内容）；
/// - 在 sheet 中触发的轻提示也能看到。
/// 没有锁屏/遮罩时窗口不接收触摸（isUserInteractionEnabled = false），触摸直接落到下层主窗口。
@MainActor
final class OverlayWindowController {
    private static var windows: [ObjectIdentifier: UIWindow] = [:]

    static func install(in scene: UIWindowScene, model: AppModel) {
        let key = ObjectIdentifier(scene)
        guard windows[key] == nil else { return }
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.backgroundColor = .clear
        window.isUserInteractionEnabled = false
        let activity = SceneActivity(scene: scene)
        let root = OverlayRoot(model: model, lock: model.lock, toast: model.toast, activity: activity) { [weak window] interactive in
            window?.isUserInteractionEnabled = interactive
        }
        let host = UIHostingController(rootView: root)
        host.view.backgroundColor = .clear
        window.rootViewController = host
        window.isHidden = false
        windows[key] = window
    }
}

/// 在主窗口视图层级中取得 UIWindowScene 并安装覆盖窗口
struct OverlayWindowInstaller: UIViewRepresentable {
    let model: AppModel

    func makeUIView(context: Context) -> InstallerView {
        let v = InstallerView()
        v.model = model
        return v
    }

    func updateUIView(_ uiView: InstallerView, context: Context) {}

    final class InstallerView: UIView {
        var model: AppModel?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let scene = window?.windowScene, let model else { return }
            OverlayWindowController.install(in: scene, model: model)
        }
    }
}

/// 场景活跃状态（覆盖窗口不在 SwiftUI App 场景树中，scenePhase 环境值不可靠，改用通知）
@MainActor @Observable
final class SceneActivity {
    enum Phase { case active, inactive, background }
    private(set) var phase: Phase
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(scene: UIScene) {
        phase = scene.activationState == .foregroundActive ? .active
            : (scene.activationState == .background ? .background : .inactive)
        let nc = NotificationCenter.default
        func on(_ name: Notification.Name, _ handler: @escaping @MainActor (SceneActivity) -> Void) {
            observers.append(nc.addObserver(forName: name, object: scene, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { handler(self) } }
            })
        }
        on(UIScene.didActivateNotification) { $0.phase = .active }
        on(UIScene.willDeactivateNotification) { $0.phase = .inactive }
        on(UIScene.didEnterBackgroundNotification) { $0.phase = .background }
        on(UIScene.willEnterForegroundNotification) { $0.phase = .inactive }
    }
}

private struct OverlayRoot: View {
    let model: AppModel
    let lock: AppLockModel
    let toast: ToastCenter
    let activity: SceneActivity
    let setInteractive: (Bool) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var returningFromBackground = false

    private var lockEnabled: Bool { model.setting(\.enableFingerprint) }
    private var shieldEnabled: Bool { model.setting(\.enabledSecurity) || lockEnabled }
    private var shieldVisible: Bool { shieldEnabled && activity.phase != .active }
    private var interactive: Bool { lock.isLocked || shieldVisible }

    var body: some View {
        ZStack {
            if shieldVisible && !lock.isLocked {
                PrivacyShieldView().transition(.opacity)
            }
            if lock.isLocked {
                LockScreenView(lock: lock).transition(.opacity)
            }
            ToastView(center: toast)
        }
        .preferredColorScheme(model.preferredColorScheme)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: lock.isLocked)
        .onChange(of: interactive, initial: true) { _, v in setInteractive(v) }
        .onAppear { lock.isEnabled = lockEnabled }
        .onChange(of: lockEnabled) { _, v in lock.isEnabled = v }
        .onChange(of: activity.phase) { _, phase in
            switch phase {
            case .background:
                lock.lock()
                returningFromBackground = true
            case .active:
                // 只在从后台回来时认证（认证弹窗本身会让场景在 inactive/active 间切换，避免循环弹出）
                if returningFromBackground {
                    returningFromBackground = false
                    if lock.isLocked { Task { await lock.authenticate() } }
                }
            case .inactive:
                break
            }
        }
        .task {
            if lock.isLocked { await lock.authenticate() }
        }
    }
}
