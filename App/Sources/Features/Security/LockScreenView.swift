import SwiftUI

/// 应用锁屏。对应 Android `SecurityScene`
struct LockScreenView: View {
    let lock: AppLockModel
    @ScaledMetric(relativeTo: .largeTitle) private var iconSize: CGFloat = 52

    var body: some View {
        let biometry = AppLockModel.biometry
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: "lock.fill")
                    .font(.system(size: iconSize, weight: .semibold))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text("EhViewer 已锁定")
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                if let error = lock.lastError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                Button {
                    Task { await lock.authenticate() }
                } label: {
                    Label(biometry.isBiometric ? "使用 \(biometry.name) 解锁" : "使用设备密码解锁",
                          systemImage: biometry.systemImage)
                        .frame(minWidth: 200)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(lock.isAuthenticating)
            }
            .padding()
        }
        .accessibilityAddTraits(.isModal)
    }
}
