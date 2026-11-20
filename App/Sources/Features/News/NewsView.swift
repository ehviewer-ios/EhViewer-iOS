import SwiftUI
import WebKit
import SafariServices
import EhCore

/// E-Hentai News（news.php），以 WebView 渲染页面 HTML；站内链接在应用内打开，其他网页链接用应用内 Safari 打开。
/// 对应 Android `NewsScene`
struct NewsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @Environment(\.navigate) private var navigate

    @State private var news: EhNewsDetail?
    @State private var error: Error?
    @State private var loading = false
    @State private var safariTarget: NewsSafariTarget?

    var body: some View {
        Group {
            if let html = news?.htmlData ?? news?.webData {
                NewsWebView(html: html, baseURL: URL(string: EhURL.news)) { url in
                    open(url)
                }
                .ignoresSafeArea(edges: .bottom)
            } else if let error {
                ErrorStateView(error: error) { Task { await load() } }
            } else if news != nil {
                EmptyStateView(title: "没有内容", systemImage: "newspaper")
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("News")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await load() }
                } label: {
                    if loading {
                        ProgressView()
                    } else {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(loading)
                .accessibilityLabel(Text("刷新"))
            }
        }
        .sheet(item: $safariTarget) { target in
            NewsSafariView(url: target.url).ignoresSafeArea()
        }
        .task {
            if news == nil { await load() }
        }
    }

    private func load() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            news = try await Task { try await model.api.getEhNews() }.value
            error = nil
        } catch {
            if news == nil { self.error = error } else { model.toast.error(error) }
        }
    }

    private func open(_ url: URL) {
        switch EhUrlRoute.parseEhUrl(url.absoluteString) {
        case let .galleryDetail(gid, token)?:
            navigate(.galleryToken(gid: gid, token: token))
        case let .galleryList(b)?:
            navigate(.list(b, title: nil))
        default:
            if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                safariTarget = NewsSafariTarget(url: url)
            } else {
                openURL(url)
            }
        }
    }
}

private struct NewsSafariTarget: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// 应用内 Safari（SFSafariViewController）
private struct NewsSafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

/// 只读 HTML 视图：拦截用户点击的链接
struct NewsWebView: UIViewRepresentable {
    let html: String
    let baseURL: URL?
    var onLink: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onLink: onLink) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = false
        web.isOpaque = false
        web.backgroundColor = .systemBackground
        context.coordinator.lastHTML = html
        web.loadHTMLString(Self.wrap(html), baseURL: baseURL)
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        context.coordinator.onLink = onLink
        if context.coordinator.lastHTML != html {
            context.coordinator.lastHTML = html
            web.loadHTMLString(Self.wrap(html), baseURL: baseURL)
        }
    }

    /// 基础样式：跟随系统深浅色，文字 / 背景 / 链接使用系统色，字体随动态字体缩放
    private static let baseStyle = """
    <style>
    :root { color-scheme: light dark; }
    html { -webkit-text-size-adjust: 100%; }
    body {
        font: -apple-system-body;
        background-color: -apple-system-background !important;
        color: -apple-system-label !important;
        margin: 0 12px;
        word-wrap: break-word;
    }
    div, td, th, p, span, h1, h2, h3, li { color: inherit !important; background-color: transparent !important; }
    a, a:visited { color: -apple-system-blue !important; }
    img { max-width: 100%; height: auto; }
    table { max-width: 100%; }
    </style>
    """

    /// 加上移动端 viewport 与 color-scheme，避免页面按桌面宽度缩小显示、深色模式下看不清
    private static func wrap(_ html: String) -> String {
        let meta = #"<meta name="viewport" content="width=device-width, initial-scale=1">"#
            + #"<meta name="color-scheme" content="light dark">"#
            + baseStyle
        if let r = html.range(of: "<head>", options: .caseInsensitive) {
            var s = html
            s.insert(contentsOf: meta, at: r.upperBound)
            return s
        }
        return meta + html
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var onLink: (URL) -> Void
        var lastHTML: String?

        init(onLink: @escaping (URL) -> Void) { self.onLink = onLink }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                decisionHandler(.cancel)
                onLink(url)
                return
            }
            decisionHandler(.allow)
        }
    }
}
