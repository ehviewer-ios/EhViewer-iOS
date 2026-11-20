import Foundation
import WebKit
import EhCore
import EhNetwork

/// 用隐藏的 WKWebView 读取论坛个人资料（显示名）。对应 Android `GetProfileScene`：
/// 论坛开启 Cloudflare 人机验证后，普通 HTTP 请求会被拦截，只能在 WebView 中加载（可复用网页登录时
/// 通过验证得到的 cf_clearance）。最多等待 `timeout` 秒，期间每秒检查一次页面中是否出现 `#userlinks`。
@MainActor
final class WebProfileFetcher: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private static var running: [WebProfileFetcher] = []

    static func fetch(cookies: [HTTPCookie], timeout: Int = 20) async -> ProfileParser.Result? {
        let f = WebProfileFetcher()
        running.append(f)
        defer { running.removeAll { $0 === f } }
        return await f.run(cookies: cookies, timeout: timeout)
    }

    private func run(cookies: [HTTPCookie], timeout: Int) async -> ProfileParser.Result? {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        webView = wv
        for c in cookies { await config.websiteDataStore.httpCookieStore.setCookie(c) }
        wv.load(URLRequest(url: URL(string: EhURL.forums)!))
        defer {
            wv.stopLoading()
            webView = nil
        }
        for _ in 0..<timeout {
            try? await Task.sleep(for: .seconds(1))
            let html = (try? await wv.evaluateJavaScript(
                "document.getElementById('userlinks') ? document.documentElement.outerHTML : ''") as? String) ?? ""
            if !html.isEmpty, let r = try? ProfileParser.parseNew(html), r.displayName?.isEmpty == false {
                return r
            }
        }
        return nil
    }
}

/// 网页数据存储中的站点 Cookie 管理（退出登录时清除）
enum WebSiteData {
    static func clearEhCookies() async {
        let store = WKWebsiteDataStore.default().httpCookieStore
        for c in await store.allCookies() where c.domain.contains("e-hentai.org") || c.domain.contains("exhentai.org") {
            await store.deleteCookie(c)
        }
    }
}
