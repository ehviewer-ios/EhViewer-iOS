import SwiftUI
import EhCore
import EhNetwork

/// 登录 sheet：以账号密码为主，“其他登录方式”进入 Cookie / 网页登录。
/// 对应 Android `SignInScene`、`CookieSignInScene`、`WebViewSignInScene`（+ `GetProfileScene`）
struct SignInSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// 输入内容放在 sheet 层级，切换登录方式时不丢失
    @State private var draft = SignInDraft()
    @State private var path: [Method] = []

    enum Method: Hashable {
        case cookie, web
        /// 账号密码登录被 Cloudflare 拦截后，转到网页自动填表登录
        case webWithCredentials
    }

    var body: some View {
        NavigationStack(path: $path) {
            PasswordSignInForm(draft: draft, onSuccess: finish,
                               onNeedWebSignIn: { path.append(.webWithCredentials) })
                .navigationTitle("登录")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                }
                .navigationDestination(for: Method.self) { method in
                    switch method {
                    case .cookie:
                        CookieSignInForm(draft: draft, onSuccess: finish)
                            .navigationTitle("Cookie 登录")
                            .navigationBarTitleDisplayMode(.inline)
                    case .web:
                        WebSignInView(onSuccess: finish)
                            .navigationTitle("网页登录")
                            .navigationBarTitleDisplayMode(.inline)
                    case .webWithCredentials:
                        WebSignInView(credentials: (draft.username, draft.password), onSuccess: finish)
                            .navigationTitle("登录")
                            .navigationBarTitleDisplayMode(.inline)
                    }
                }
        }
        // 网页登录时下滑手势容易与网页滚动冲突
        .interactiveDismissDisabled(path.last == .web || path.last == .webWithCredentials)
    }

    /// 登录成功：同步状态、拉取资料、关闭
    private func finish(displayName: String?) {
        Task {
            await SignInFlow.didSignIn(model: model, displayName: displayName)
            dismiss()
        }
    }
}

/// 登录表单的输入（切换登录方式时保留）
@MainActor @Observable
final class SignInDraft {
    var username = ""
    var password = ""
    var memberId = ""
    var passHash = ""
    var igneous = ""
}

/// 登录后的公共流程
@MainActor
enum SignInFlow {
    static func didSignIn(model: AppModel, displayName: String?) async {
        model.cookieStore.copyLoginCookiesToEx()
        model.settings.needSignIn = false
        model.refreshSignInState()
        if let displayName, !displayName.isEmpty {
            model.displayName = displayName
            model.settings.displayName = displayName
        }
        await model.fetchProfile()
        Haptics.success()
        model.toast.show("登录成功" + (model.displayName.map { "：\($0)" } ?? ""), systemImage: "person.crop.circle.badge.checkmark")
    }

    /// 就地显示错误，同时让 VoiceOver 播报
    static func announce(_ message: String) {
        Haptics.error()
        AccessibilityNotification.Announcement(message).post()
    }
}

// MARK: - 账号密码

private struct PasswordSignInForm: View {
    @Environment(AppModel.self) private var model
    @Bindable var draft: SignInDraft
    let onSuccess: (String?) -> Void
    let onNeedWebSignIn: () -> Void

    @State private var loading = false
    @State private var error: String?
    @FocusState private var focus: Field?

    enum Field { case username, password }

    var body: some View {
        Form {
            Section {
                TextField("用户名", text: $draft.username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .username)
                    .submitLabel(.next)
                    .onSubmit { focus = .password }
                SecureField("密码", text: $draft.password)
                    .textContentType(.password)
                    .focused($focus, equals: .password)
                    .submitLabel(.go)
                    .onSubmit(signIn)
            } footer: {
                if let error {
                    Label(error, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.red)
                }
            }

            Section {
                Button(action: signIn) {
                    HStack {
                        Spacer()
                        if loading { ProgressView() } else { Text("登录").bold() }
                        Spacer()
                    }
                }
                .disabled(loading || draft.username.isEmpty || draft.password.isEmpty)
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("使用 E-Hentai 论坛账号登录。")
                    Link("注册账号", destination: URL(string: EhURL.register)!)
                }
            }

            Section {
                NavigationLink(value: SignInSheet.Method.cookie) {
                    Label("使用 Cookie 登录", systemImage: "key")
                }
                NavigationLink(value: SignInSheet.Method.web) {
                    Label("使用网页登录", systemImage: "globe")
                }
            } header: {
                Text("其他登录方式")
            } footer: {
                Text("论坛开启人机验证时会自动转到网页完成登录。网络受限时可改用 Cookie 登录。")
            }
        }
        .defaultFocus($focus, .username)
        .task {
            // sheet 出现动画结束后再聚焦，确保键盘弹出
            guard draft.username.isEmpty, focus == nil else { return }
            try? await Task.sleep(for: .milliseconds(400))
            if focus == nil { focus = .username }
        }
    }

    private func signIn() {
        guard !loading, !draft.username.isEmpty, !draft.password.isEmpty else { return }
        focus = nil
        loading = true
        error = nil
        Task {
            defer { loading = false }
            do {
                let name = try await model.api.signIn(username: draft.username, password: draft.password)
                if model.cookieStore.hasSignedIn {
                    onSuccess(name)
                } else {
                    fail("登录失败：未能获取登录信息，请改用其他登录方式。")
                }
            } catch EhError.cloudflareChallenge {
                // 论坛开启了 Cloudflare 人机验证：改在网页中自动填表登录
                onNeedWebSignIn()
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    private func fail(_ message: String) {
        error = message
        SignInFlow.announce(message)
    }
}

// MARK: - Cookie

private struct CookieSignInForm: View {
    @Environment(AppModel.self) private var model
    @Bindable var draft: SignInDraft
    let onSuccess: (String?) -> Void

    @State private var confirmWrong = false
    @State private var loading = false
    @State private var error: String?
    /// 验证请求失败（非 Cookie 无效）时允许跳过验证
    @State private var canSkipVerification = false
    @FocusState private var focus: Field?

    enum Field: Hashable { case memberId, passHash, igneous }

    private var canSubmit: Bool {
        !loading && !draft.memberId.trimmed.isEmpty && !draft.passHash.trimmed.isEmpty
    }

    var body: some View {
        Form {
            Section {
                LabeledContent(EhCookieStore.keyMemberId) {
                    TextField(EhCookieStore.keyMemberId, text: $draft.memberId, prompt: Text("必填"))
                        .keyboardType(.numberPad)
                        .focused($focus, equals: .memberId)
                        .font(.body.monospaced())
                }
                LabeledContent(EhCookieStore.keyPassHash) {
                    TextField(EhCookieStore.keyPassHash, text: $draft.passHash, prompt: Text("必填"))
                        .keyboardType(.asciiCapable)
                        .focused($focus, equals: .passHash)
                        .font(.body.monospaced())
                        .submitLabel(.next)
                        .onSubmit { focus = .igneous }
                        .privacySensitive()
                }
                LabeledContent(EhCookieStore.keyIgneous) {
                    TextField(EhCookieStore.keyIgneous, text: $draft.igneous, prompt: Text("可选"))
                        .keyboardType(.asciiCapable)
                        .focused($focus, equals: .igneous)
                        .font(.body.monospaced())
                        .submitLabel(.go)
                        .onSubmit(submit)
                        .privacySensitive()
                }
            } footer: {
                Text("从已登录的浏览器或另一台设备复制 Cookie。igneous 仅用于访问 ExHentai。")
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()

            Section {
                HStack {
                    Text("从剪贴板读取")
                    Spacer()
                    PasteButton(payloadType: String.self) { strings in
                        let text = strings.first
                        Task { @MainActor in apply(clipboard: text) }
                    }
                    .labelStyle(.titleAndIcon)
                    .buttonBorderShape(.capsule)
                }
            } footer: {
                Text("剪贴板格式为每行一个“名称: 值”，如\nipb_member_id: 1234567\nipb_pass_hash: 0123abcd…")
            }

            Section {
                Button(action: submit) {
                    HStack {
                        Spacer()
                        if loading { ProgressView() } else { Text("登录").bold() }
                        Spacer()
                    }
                }
                .disabled(!canSubmit)
                if canSkipVerification {
                    Button("跳过验证并登录", action: storeWithoutVerification)
                        .disabled(loading)
                }
            } footer: {
                if let error {
                    Label(error, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.red)
                } else {
                    Text("登录前会先用这些 Cookie 读取账号资料，以确认 Cookie 有效。")
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                if focus == .memberId {
                    Button("下一项") { focus = .passHash }
                }
                Spacer()
                Button("完成") { focus = nil }
            }
        }
        .confirmationDialog("Cookie 格式可能有误", isPresented: $confirmWrong, titleVisibility: .visible) {
            Button("仍然登录") { verifyAndStore() }
        } message: {
            Text("ipb_member_id 应为纯数字，ipb_pass_hash 应为 32 位小写字母与数字。")
        }
    }

    private func apply(clipboard text: String?) {
        guard let text, let f = CookieSignIn.parseClipboard(text),
              f.memberId != nil || f.passHash != nil || f.igneous != nil else {
            model.toast.show("剪贴板中没有 Cookie", systemImage: "doc.on.clipboard")
            return
        }
        if let v = f.memberId { draft.memberId = v }
        if let v = f.passHash { draft.passHash = v }
        if let v = f.igneous { draft.igneous = v }
        error = nil
        canSkipVerification = false
        Haptics.success()
    }

    private func submit() {
        guard canSubmit else { return }
        if CookieSignIn.looksValid(memberId: draft.memberId.trimmed, passHash: draft.passHash.trimmed) {
            verifyAndStore()
        } else {
            confirmWrong = true
        }
    }

    private func store() {
        CookieSignIn.store(memberId: draft.memberId, passHash: draft.passHash,
                           igneous: draft.igneous.trimmed.isEmpty ? nil : draft.igneous, in: model.cookieStore)
    }

    /// 写入 Cookie 后读取一次个人资料，成功才算登录；失败时撤销写入并就地显示错误
    private func verifyAndStore() {
        focus = nil
        loading = true
        error = nil
        canSkipVerification = false
        store()
        Task {
            do {
                // 论坛被 Cloudflare 拦截，改用主站 home.php 校验登录状态；显示名之后由 fetchProfile 获取
                guard try await model.api.checkSignedIn() else { throw EhError.notSignedIn }
                onSuccess(nil)
            } catch {
                model.cookieStore.signOut()
                loading = false
                let invalid: Bool
                if let e = error as? EhError {
                    switch e {
                    case .parse, .notSignedIn: invalid = true
                    default: invalid = false
                    }
                } else {
                    invalid = false
                }
                let message = invalid
                    ? "Cookie 无效或已过期，请检查后重试。"
                    : "无法验证 Cookie：\(error.localizedDescription)"
                canSkipVerification = !invalid
                self.error = message
                SignInFlow.announce(message)
            }
        }
    }

    /// 网络原因无法验证时，允许直接保存 Cookie（与 Android 行为一致）
    private func storeWithoutVerification() {
        loading = true
        store()
        onSuccess(nil)
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
