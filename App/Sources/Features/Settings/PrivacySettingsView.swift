import SwiftUI
import EhStorage

/// 隐私与安全。对应 Android `PrivacyFragment` / `privacy_settings.xml`：
/// 图案锁 → 系统认证（Face ID / Touch ID / 设备密码）；FLAG_SECURE → 后台隐私遮罩
struct PrivacySettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppLockModel.self) private var lock: AppLockModel?
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppLockModel.graceSecondsKey) private var graceSeconds = 0
    @State private var authenticating = false
    /// 设备是否设置了锁屏密码（从系统设置返回时刷新）
    @State private var canAuthenticate = AppLockModel.canAuthenticate

    var body: some View {
        let biometry = AppLockModel.biometry
        let lockOn = model.setting(\.enableFingerprint)
        Form {
            Section {
                Toggle(isOn: lockBinding) {
                    Label("应用锁", systemImage: biometry.systemImage)
                }
                // 未设置设备密码时不能开启；已开启的仍允许关闭
                .disabled(authenticating || (!canAuthenticate && !lockOn))
                if lockOn {
                    Picker(selection: $graceSeconds) {
                        ForEach(AppLockModel.graceOptions, id: \.self) { Text(AppLockModel.graceTitle($0)).tag($0) }
                    } label: {
                        Label("自动锁定", systemImage: "timer")
                    }
                    .pickerStyle(.navigationLink)
                }
            } footer: {
                lockFooter(biometry: biometry, lockOn: lockOn)
            }

            Section {
                Toggle(isOn: lockOn ? .constant(true) : model.binding(\.enabledSecurity)) {
                    Label("后台隐私遮罩", systemImage: "eye.slash")
                }
                .disabled(lockOn)
            } footer: {
                Text(lockOn
                     ? "切换到其他应用时遮住画面，多任务界面中不显示内容。应用锁开启时始终启用。"
                     : "切换到其他应用时遮住画面，多任务界面中不显示内容。")
            }
        }
        .navigationTitle("隐私与安全")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { canAuthenticate = AppLockModel.canAuthenticate }
        }
    }

    @ViewBuilder
    private func lockFooter(biometry: AppLockModel.Biometry, lockOn: Bool) -> some View {
        if !canAuthenticate {
            VStack(alignment: .leading, spacing: 6) {
                Text("此设备未设置锁屏密码，无法使用应用锁。请先在“设置”中设置密码。")
                Button("前往设置") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .font(.footnote)
            }
        } else {
            let unlock = biometry.isBiometric ? "使用 \(biometry.name) 或设备密码解锁" : "输入设备密码解锁"
            if lockOn {
                Text(graceSeconds <= 0
                     ? "启动或从后台返回时需要\(unlock)。"
                     : "启动时，或离开超过 \(AppLockModel.graceTitle(graceSeconds))后返回时，需要\(unlock)。")
            } else {
                Text("启动或从后台返回时需要\(unlock)。")
            }
        }
    }

    /// 开启与关闭都需要先通过一次认证
    private var lockBinding: Binding<Bool> {
        Binding(
            get: { model.setting(\.enableFingerprint) },
            set: { newValue in
                guard newValue != model.settings.enableFingerprint else { return }
                authenticating = true
                Task {
                    let reason = newValue ? "启用应用锁" : "关闭应用锁"
                    let result = await AppLockModel.evaluate(reason: reason)
                    authenticating = false
                    switch result {
                    case .success:
                        apply(newValue)
                    case .unavailable:
                        canAuthenticate = false
                        // 设备密码已被移除：允许直接关闭，无法开启
                        if !newValue { apply(false) }
                    case let .failure(message):
                        if let message { model.toast.show(message, systemImage: "exclamationmark.circle") }
                    }
                }
            }
        )
    }

    private func apply(_ enabled: Bool) {
        model.settings.enableFingerprint = enabled
        model.settingsDidChange()
        lock?.isEnabled = enabled
    }
}
