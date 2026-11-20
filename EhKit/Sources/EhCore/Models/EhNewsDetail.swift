import Foundation

/// 新闻页（news.php）。对应 Android `data/EhNewsDetail`。
/// Java 版懒解析；这里由 `EhNewsParser.parse` 一次性解析好，保持值类型可 Sendable
public struct EhNewsDetail: Codable, Sendable, Hashable {
    /// 原始页面 HTML
    public var webData: String?
    /// `#eventpane` 的内部 HTML（仅当其恰有 3 个子元素时，即"新的一天"奖励事件）
    public var eventPane: String?
    /// 整个 `<html>` 元素重新序列化的 HTML，用于 WebView 展示。对应 `getHtmlData()`
    public var htmlData: String?

    public init(webData: String? = nil, eventPane: String? = nil, htmlData: String? = nil) {
        self.webData = webData
        self.eventPane = eventPane
        self.htmlData = htmlData
    }
}
