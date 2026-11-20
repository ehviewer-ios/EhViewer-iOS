import Foundation

/// # WebView 登录（对应 Android `WebViewSignInScene` + `assets/requestOverride.js`）
///
/// ## Android 做了什么
/// 1. 进入页面先 `EhUtils.signOut`（清空 cookie store），并清空 WebView `CookieManager`；
/// 2. WebView 加载 `https://forums.e-hentai.org/index.php?act=Login`，用户在网页里正常登录；
/// 3. 每次 `onPageFinished` 读取 `CookieManager.getCookie("https://e-hentai.org/")`（即对 e-hentai.org 可见的所有
///    cookie，包括论坛下发的 `.e-hentai.org` 域 cookie），逐个通过
///    `EhCookieStore.newCookie(cookie, domain, forcePersistent=true, forceLongLive=true, forceNotHostOnly=true)`
///    复制到 `exhentai.org` 与 `e-hentai.org` 两个域；
/// 4. 同时拿到 `ipb_member_id` 与 `ipb_pass_hash` 即视为登录成功，关闭页面。
///
/// `LoginWebViewClientSNI`（未启用的备选实现）配合 `requestOverride.js`：JS 劫持 `XMLHttpRequest.open/send`
/// 记录请求体，`shouldInterceptRequest` 中把 WebView 的每个请求（含表单 POST）改由 OkHttp（带 DF / 内置 hosts）
/// 发出再把响应喂回 WebView，从而让登录页本身也能在被墙环境下加载。当前 Android 实际使用的是不拦截的
/// `LoginWebViewClient`。
///
/// ## iOS 侧做法
/// - 用 `WKWebView`（`WKWebsiteDataStore.nonPersistent()` 或先清空 `httpCookieStore`）加载 `EhURL.signIn`；
/// - 在 `webView(_:didFinish:)` 中 `httpCookieStore.getAllCookies`，调用
///   `EhCookieStore.importWebViewLoginCookies(httpCookies:)`，返回 true 即登录成功；
/// - WKWebView 无法像 Android `shouldInterceptRequest` 那样接管 https 请求（`WKURLSchemeHandler` 不能注册 http/https），
///   所以登录页本身不走 DF；网络受限时引导用户使用 Cookie 登录（`setLoginCookies(memberId:passHash:igneous:)`）
///   或账号密码 API 登录（下一阶段 EhEngine.signIn，基于 `EhHTTPClient.postForm`）。
/// - 需要在 WebView 中打开站点页面（如 uconfig、mytags）时，先用 `exportHTTPCookies(for:)` 写入
///   `WKHTTPCookieStore`；关闭页面时把 WebView 的 cookie 拼成 `a=1; b=2` 交给
///   `importSharedSiteCookies(cookieHeader:)`（对应 `UConfigActivity.onDestroy` 的表里站共享逻辑）。
/// - `EhHTTPClient.onSetCookies` 对应 Android 把每个响应的 Set-Cookie 同步给 `CookieManager` 的网络拦截器，
///   UI 层可在其中转写给 `WKHTTPCookieStore`。
public enum WebViewSignIn {
    /// 登录页
    public static let signInURL = URL(string: EhURL.signIn)!
    /// 读取 cookie 时的参考 URL（`EhUrl.HOST_E`）
    public static let cookieURL = URL(string: "https://e-hentai.org/")!
}
