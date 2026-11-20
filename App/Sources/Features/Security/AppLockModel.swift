import Foundation
import UIKit
import LocalAuthentication
import EhStorage

/// 应用锁状态（Face ID / Touch ID / 设备密码）。对应 Android `SecurityScene` + `SetSecurityActivity`
/// （Android 的图案锁不移植，统一用系统认证）。
///
/// 是否启用由 `EhSettings.enableFingerprint` 决定（由顶层覆盖窗口 `OverlayRoot` 同步到 `isEnabled`）。
/// 进入后台时调用 `lock()`；若设置了“自动锁定”宽限时间，则记录进入后台的时间，回到前台时超过宽限才锁定。
@MainActor @Observable
final class AppLockModel {
    /// 是否启用应用锁。关闭时自动视为已解锁
    var isEnabled: Bool {
        didSet { if !isEnabled { isUnlocked = true } }
    }
    /// 是否已解锁
    private(set) var isUnlocked: Bool
    private(set) var isAuthenticating = false
    /// 最近一次认证失败的原因
    private(set) var lastError: String?

    /// 进入后台的时间（仅在有宽限时间且当前已解锁时记录）
    @ObservationIgnored private var backgroundDate: Date?
    @ObservationIgnored private var backgroundUptime: TimeInterval?
    @ObservationIgnored private var foregroundObserver: NSObjectProtocol?

    /// “自动锁定”宽限时间（秒）的 UserDefaults key。0 为立即锁定
    static let graceSecondsKey = "app_lock_grace_seconds"
    /// 可选的宽限时间：立即 / 1 分钟 / 5 分钟 / 15 分钟
    static let graceOptions = [0, 60, 300, 900]

    static func graceTitle(_ seconds: Int) -> String {
        seconds <= 0 ? "立即" : "\(seconds / 60) 分钟"
    }

    /// 当前宽限时间（秒）
    var graceSeconds: Int { max(0, UserDefaults.standard.integer(forKey: Self.graceSecondsKey)) }

    init(isEnabled: Bool) {
        self.isEnabled = isEnabled
        isUnlocked = !isEnabled
        // 回到前台时（早于场景 didActivate）检查宽限时间，覆盖窗口在 active 时据 isLocked 发起认证
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkGracePeriod() }
        }
    }

    convenience init(settings: EhSettings) {
        self.init(isEnabled: settings.enableFingerprint)
    }

    /// 需要显示锁屏
    var isLocked: Bool { isEnabled && !isUnlocked }

    /// 进入后台时调用。宽限时间为 0 时立即锁定，否则记录进入后台的时间
    func lock() {
        guard isEnabled else { return }
        let grace = graceSeconds
        if grace <= 0 || !isUnlocked {
            isUnlocked = false
            backgroundDate = nil
            backgroundUptime = nil
        } else if backgroundDate == nil {
            backgroundDate = Date()
            backgroundUptime = ProcessInfo.processInfo.systemUptime
        }
    }

    /// 回到前台：离开时间超过宽限时间则锁定（墙上时钟被调回时也锁定）
    private func checkGracePeriod() {
        guard let date = backgroundDate else { return }
        let uptime = backgroundUptime
        backgroundDate = nil
        backgroundUptime = nil
        guard isEnabled else { return }
        let grace = TimeInterval(graceSeconds)
        let elapsed = Date().timeIntervalSince(date)
        let elapsedUptime = uptime.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0
        if elapsed < 0 || elapsed >= grace || elapsedUptime >= grace {
            isUnlocked = false
        }
    }

    /// 发起认证。成功后解锁
    @discardableResult
    func authenticate(reason: String = "解锁 EhViewer") async -> Bool {
        guard !isAuthenticating else { return false }
        isAuthenticating = true
        defer { isAuthenticating = false }
        let ok = await Self.evaluate(reason: reason)
        switch ok {
        case .success:
            isUnlocked = true
            lastError = nil
            return true
        case .unavailable:
            // 设备未设置密码：无法锁定，直接放行（与系统行为一致）
            isUnlocked = true
            lastError = nil
            return true
        case let .failure(message):
            lastError = message
            return false
        }
    }

    enum EvaluateResult: Equatable {
        case success
        case unavailable
        case failure(String?)
    }

    /// 执行一次 `.deviceOwnerAuthentication`（生物识别，失败可回落设备密码）
    static func evaluate(reason: String) async -> EvaluateResult {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return .unavailable
        }
        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            return ok ? .success : .failure(nil)
        } catch let e as LAError where e.code == .userCancel || e.code == .systemCancel || e.code == .appCancel {
            return .failure(nil)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    /// 设备是否可用系统认证（未设置密码时为 false）
    static var canAuthenticate: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    struct Biometry {
        let name: String
        let systemImage: String
        /// false 表示设备不支持生物识别，只能用设备密码
        let isBiometric: Bool
    }

    /// 生物识别类型名称与图标（硬件类型不会变化，只计算一次）
    static let biometry: Biometry = {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return Biometry(name: "Face ID", systemImage: "faceid", isBiometric: true)
        case .touchID: return Biometry(name: "Touch ID", systemImage: "touchid", isBiometric: true)
        case .opticID: return Biometry(name: "Optic ID", systemImage: "opticid", isBiometric: true)
        default: return Biometry(name: "设备密码", systemImage: "lock", isBiometric: false)
        }
    }()
}
