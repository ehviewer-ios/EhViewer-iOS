import SwiftUI

/// 轻提示。显示在顶层覆盖窗口（见 OverlayWindow.swift），因此在 sheet / 阅读器中也可见，且不拦截触摸。
/// 使用原则：只用于“结果在界面上看不到”的操作（复制、错误、后台完成等）；
/// 界面本身已有状态变化（按钮/角标）时不要再弹提示，改用触感反馈。
@MainActor @Observable
final class ToastCenter {
    struct Toast: Identifiable, Equatable {
        let id = UUID()
        var message: String
        var systemImage: String?
        var isError: Bool
    }

    private(set) var current: Toast?
    private var dismissTask: Task<Void, Never>?

    func show(_ message: String, systemImage: String? = nil, duration: Duration = .seconds(2)) {
        present(Toast(message: message, systemImage: systemImage, isError: false), duration: duration)
    }

    func error(_ error: Error) {
        present(Toast(message: error.localizedDescription, systemImage: "exclamationmark.circle", isError: true),
                duration: .seconds(3))
    }

    func dismiss() {
        dismissTask?.cancel()
        current = nil
    }

    private func present(_ toast: Toast, duration: Duration) {
        guard !toast.message.isEmpty else { return }
        current = toast
        AccessibilityNotification.Announcement(toast.message).post()
        if toast.isError { Haptics.error() }
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.current = nil
        }
    }
}

/// 覆盖窗口中的提示视图
struct ToastView: View {
    let center: ToastCenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack {
            if let toast = center.current {
                HStack(spacing: 8) {
                    if let s = toast.systemImage {
                        Image(systemName: s).foregroundStyle(toast.isError ? .red : .primary)
                    }
                    Text(toast.message).font(.subheadline).lineLimit(3)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                .id(toast.id)
                .accessibilityHidden(true) // 已通过 Announcement 播报
            }
            Spacer()
        }
        .allowsHitTesting(false)
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.3), value: center.current)
    }
}

extension View {
    /// 兼容旧调用：提示已统一显示在覆盖窗口中，此修饰符不再做任何事
    func toastOverlay(_ center: ToastCenter) -> some View { self }
}

/// 触感反馈（UIKit 场景或非视图代码中使用；SwiftUI 视图优先用 `.sensoryFeedback`）
@MainActor
enum Haptics {
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    static func selection() { UISelectionFeedbackGenerator().selectionChanged() }
    static func light() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
}
