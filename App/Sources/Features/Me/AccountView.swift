import SwiftUI
import UniformTypeIdentifiers
import EhCore
import EhNetwork

/// 账号页（“我的”顶部账号卡片进入）：头像昵称、身份 Cookie、刷新资料、站点设置、“我的”页显示项、退出登录
struct AccountView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmSignOut = false
    @State private var refreshing = false

    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    AccountAvatar(size: 80)
                    Text(model.displayName ?? "已登录")
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                    Text(model.site.title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
            }

            Section {
                NavigationLink("身份 Cookie") { IdentityCookieView() }
                Button {
                    refreshProfile()
                } label: {
                    HStack {
                        Text("刷新资料")
                        Spacer()
                        if refreshing { ProgressView() }
                    }
                }
                .disabled(refreshing)
                NavigationLink("站点设置") { UConfigView() }
            } footer: {
                Text("站点设置会打开网页版的个人设置，可修改图片尺寸、缩略图样式等站点偏好。")
            }

            Section {
                Toggle("显示图片额度", isOn: model.binding(\.showEhLimits))
                Toggle("显示站点活动", isOn: model.binding(\.showEhEvents))
            } footer: {
                Text("图片额度显示在“我的”页。站点活动指每日登录奖励等站点提示。")
            }

            Section {
                Button("退出登录", role: .destructive) { confirmSignOut = true }
                    .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("账号")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("退出登录？", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("退出登录", role: .destructive) {
                model.signOut()
                model.toast.show("已退出登录", systemImage: "person.crop.circle.badge.minus")
            }
        } message: {
            Text("将清除本机保存的所有站点 Cookie。")
        }
        .onChange(of: model.isSignedIn) { _, signedIn in
            if !signedIn { dismiss() }
        }
    }

    private func refreshProfile() {
        refreshing = true
        Task {
            defer { refreshing = false }
            do {
                let profile = try await model.api.getProfile()
                model.displayName = profile.displayName
                model.avatarURL = profile.avatar
                model.settings.displayName = profile.displayName
                model.settings.avatar = profile.avatar
                model.toast.show("资料已更新", systemImage: "checkmark.circle")
            } catch {
                model.toast.error(error)
            }
        }
    }
}

/// 账号头像（未登录或无头像时显示占位图）
struct AccountAvatar: View {
    @Environment(AppModel.self) private var model
    let size: CGFloat
    @ScaledMetric private var scale: CGFloat = 1

    var body: some View {
        let side = size * min(scale, 1.5)
        Group {
            if model.isSignedIn, let url = model.avatarURL, !url.isEmpty {
                ThumbnailImage(url: Self.absolute(url), referer: EhURL.forums)
                    .frame(width: side, height: side)
                    .clipShape(Circle())
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .foregroundStyle(.secondary, .quaternary)
                    .frame(width: side, height: side)
            }
        }
        .accessibilityHidden(true)
    }

    /// 论坛头像可能是相对地址
    static func absolute(_ s: String) -> String {
        if s.hasPrefix("http") { return s }
        if s.hasPrefix("//") { return "https:" + s }
        return EhURL.forums + (s.hasPrefix("/") ? String(s.dropFirst()) : s)
    }
}

// MARK: - 身份 Cookie

/// 查看 / 复制身份 Cookie。对应 Android `IdentityCookiePreference`
struct IdentityCookieView: View {
    @Environment(AppModel.self) private var model
    @State private var reveal = false

    /// 复制到剪贴板的内容仅本机可用，并在 2 分钟后过期
    static let pasteboardLifetime: TimeInterval = 120

    var body: some View {
        let c = model.cookieStore.identityCookies()
        Form {
            Section {
                row(EhCookieStore.keyMemberId, c.memberId, secret: false)
                row(EhCookieStore.keyPassHash, c.passHash, secret: true)
                row(EhCookieStore.keyIgneous, c.igneous, secret: true)
            } footer: {
                Text("这些 Cookie 等同于账号密码，请勿泄露给他人。复制的内容可直接粘贴到另一台设备的“Cookie 登录”。长按单项可单独复制。")
            }
            Section {
                Toggle("显示完整内容", isOn: $reveal)
                Button("复制全部") { copy(Self.clipboardText(c)) }
            } footer: {
                Text("复制的内容不会同步到其他设备，2 分钟后自动从剪贴板清除。")
            }
        }
        .navigationTitle("身份 Cookie")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ name: String, _ value: String?, secret: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name).font(.subheadline.weight(.medium))
            Text(display(value, secret: secret))
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .privacySensitive()
        }
        .accessibilityElement(children: .combine)
        .contextMenu {
            if let value, !value.isEmpty {
                Button("复制", systemImage: "doc.on.doc") { copy(value) }
            }
        }
    }

    private func copy(_ text: String) {
        UIPasteboard.general.setItems(
            [[UTType.plainText.identifier: text]],
            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(Self.pasteboardLifetime)]
        )
        Haptics.success()
        model.toast.show("已复制", systemImage: "doc.on.doc")
    }

    private func display(_ value: String?, secret: Bool) -> String {
        guard let value, !value.isEmpty else { return "（无）" }
        if !secret || reveal { return value }
        let prefix = value.prefix(4)
        return prefix + String(repeating: "•", count: max(0, min(value.count - 4, 24)))
    }

    /// 与 `CookieSignIn.parseClipboard` 互通的格式
    static func clipboardText(_ c: (memberId: String?, passHash: String?, igneous: String?)) -> String {
        var lines: [String] = []
        lines.append("\(EhCookieStore.keyMemberId): \(c.memberId ?? "")")
        lines.append("\(EhCookieStore.keyPassHash): \(c.passHash ?? "")")
        if let ig = c.igneous, !ig.isEmpty { lines.append("\(EhCookieStore.keyIgneous): \(ig)") }
        return lines.joined(separator: "\n")
    }
}
