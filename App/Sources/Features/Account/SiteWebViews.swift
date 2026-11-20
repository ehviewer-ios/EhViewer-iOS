import SwiftUI
import WebKit
import EhCore
import EhNetwork

// MARK: - 网页登录

/// 网页登录。对应 Android `WebViewSignInScene`：加载论坛登录页，每次页面加载完成读取 cookie，
/// 拿到 ipb_member_id 与 ipb_pass_hash 即视为成功（见 `EhNetwork/Cookie/WebViewSignIn.swift`）
struct WebSignInView: View {
    @Environment(AppModel.self) private var model
    /// 账号密码登录被 Cloudflare 拦截时转到这里：页面加载后自动填入并提交（只提交一次）
    var credentials: (username: String, password: String)?
    let onSuccess: (String?) -> Void
    @State private var submitted = false
    @State private var progress: Double = 0
    @State private var done = false
    @State private var webView: WKWebView?
    @State private var canGoBack = false

    var body: some View {
        VStack(spacing: 0) {
            Label(credentials == nil
                  ? "网页登录直接连接站点。如出现人机验证，请按页面提示完成。网络受限时请改用 Cookie 登录。"
                  : "论坛开启了人机验证，正在通过网页登录。如出现验证，请按页面提示完成，账号密码会自动填入。",
                  systemImage: "info.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
            if progress < 1 {
                ProgressView(value: progress).progressViewStyle(.linear)
            }
            // 使用持久数据存储：通过人机验证得到的 cf_clearance 可供之后读取个人资料复用
            EhWebView(url: WebViewSignIn.signInURL, persistent: true, progress: $progress,
                      onCreate: { webView = $0 }) { webView in
                canGoBack = webView.canGoBack
                webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                    Task { @MainActor in
                        guard !done else { return }
                        if model.cookieStore.importWebViewLoginCookies(httpCookies: cookies) {
                            done = true
                            onSuccess(nil)
                        } else {
                            autofill(webView)
                        }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                Button {
                    webView?.goBack()
                } label: {
                    Label("后退", systemImage: "chevron.backward")
                }
                .disabled(!canGoBack)
                Spacer()
                Button {
                    webView?.reload()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
            }
        }
    }
}

extension WebSignInView {
    /// 登录表单出现后自动填入账号密码并提交（Cloudflare 验证页上没有表单，验证通过后才会执行）
    fileprivate func autofill(_ webView: WKWebView) {
        guard let credentials, !submitted else { return }
        func js(_ s: String) -> String {
            let data = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8)
            return String(decoding: data, as: UTF8.self) + "[0]"
        }
        let script = """
        (function(){
          var u = document.querySelector('input[name="UserName"]');
          var p = document.querySelector('input[name="PassWord"]');
          if (!u || !p || !u.form) return 'noform';
          u.value = \(js(credentials.username));
          p.value = \(js(credentials.password));
          var c = u.form.querySelector('input[name="CookieDate"]');
          if (c) c.checked = true;
          u.form.submit();
          return 'submitted';
        })()
        """
        webView.evaluateJavaScript(script) { result, _ in
            if (result as? String) == "submitted" { submitted = true }
        }
    }
}

/// “更多”菜单图标：iOS 26 起导航栏按钮自带圆形背景，使用不带圆圈的 ellipsis
enum MoreMenuIcon {
    static var systemName: String {
        if #available(iOS 26, *) { return "ellipsis" }
        return "ellipsis.circle"
    }
}

// MARK: - 站点页面（uconfig / mytags）

/// 带登录 Cookie 的站点网页。关闭时把站点 cookie（uconfig 等）同步回 `cookieStore`。
/// 对应 Android `UConfigActivity` / `MyTagsActivity`
struct SiteWebPage: View {
    @Environment(AppModel.self) private var model
    let title: String
    let url: URL
    @State private var progress: Double = 0
    @State private var webView: WKWebView?

    var body: some View {
        VStack(spacing: 0) {
            if progress < 1 {
                ProgressView(value: progress).progressViewStyle(.linear)
            }
            EhWebView(url: url, persistent: false, cookies: model.cookieStore.exportHTTPCookies(),
                      progress: $progress, onCreate: { webView = $0 }, onFinish: { _ in })
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("刷新", systemImage: "arrow.clockwise") { webView?.reload() }
                    Link(destination: url) { Label("在 Safari 中打开", systemImage: "safari") }
                } label: {
                    Label("更多", systemImage: MoreMenuIcon.systemName)
                }
            }
        }
        .onDisappear(perform: syncCookies)
    }

    /// 对应 `UConfigActivity.onDestroy`：表里站共享页面上的 cookie
    private func syncCookies() {
        guard let store = webView?.configuration.websiteDataStore.httpCookieStore else { return }
        let host = url.host ?? ""
        let cookieStore = model.cookieStore
        store.getAllCookies { cookies in
            let header = cookies
                .filter { c in
                    let d = c.domain.hasPrefix(".") ? String(c.domain.dropFirst()) : c.domain
                    return host == d || host.hasSuffix("." + d)
                }
                .filter { ![EhCookieStore.keyMemberId, EhCookieStore.keyPassHash, EhCookieStore.keyIgneous].contains($0.name) }
                .map { "\($0.name)=\($0.value)" }
                .joined(separator: "; ")
            if !header.isEmpty { cookieStore.importSharedSiteCookies(cookieHeader: header) }
        }
    }
}

/// 站点设置（uconfig.php）
struct UConfigView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SiteWebPage(title: "站点设置", url: URL(string: EhURL.uconfig(model.site))!)
    }
}

// MARK: - WKWebView 封装

struct EhWebView: UIViewRepresentable {
    let url: URL
    /// false 时使用非持久数据存储（不与其他页面共享 cookie）
    var persistent = false
    /// 加载前写入的 cookie
    var cookies: [HTTPCookie] = []
    @Binding var progress: Double
    var onCreate: (WKWebView) -> Void = { _ in }
    var onFinish: (WKWebView) -> Void

    init(url: URL, persistent: Bool = false, cookies: [HTTPCookie] = [], progress: Binding<Double>,
         onCreate: @escaping (WKWebView) -> Void = { _ in }, onFinish: @escaping (WKWebView) -> Void) {
        self.url = url
        self.persistent = persistent
        self.cookies = cookies
        _progress = progress
        self.onCreate = onCreate
        self.onFinish = onFinish
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = persistent ? .default() : .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        // 使用 WKWebView 默认（Safari）UA：与 WebKit 内核特征一致，Cloudflare 人机验证才能通过
        context.coordinator.observe(webView)
        let store = config.websiteDataStore.httpCookieStore
        let cookies = cookies
        let url = url
        Task { @MainActor in
            for c in cookies { await store.setCookie(c) }
            webView.load(URLRequest(url: url))
        }
        onCreate(webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        coordinator.observation = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: EhWebView
        var observation: NSKeyValueObservation?

        init(_ parent: EhWebView) { self.parent = parent }

        func observe(_ webView: WKWebView) {
            observation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] wv, _ in
                let p = wv.estimatedProgress
                DispatchQueue.main.async { self?.parent.progress = p }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.progress = 1
            parent.onFinish(webView)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.progress = 1
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.progress = 1
        }
    }
}
