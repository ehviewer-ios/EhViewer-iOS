import Foundation
import SwiftSoup

/// 新闻页（news.php）。对应 Android `EhEngine.getEhNews` + `EhNewsDetail.getEventPane / getHtmlData`
public enum EhNewsParser {
    public static func parse(_ body: String) -> EhNewsDetail {
        var detail = EhNewsDetail(webData: body)
        guard let document = try? SwiftSoup.parse(body) else { return detail }
        // 仅当 #eventpane 恰有 3 个子元素时取其内部 HTML
        if let pane = try? document.getElementById("eventpane"), pane.children().size() == 3 {
            detail.eventPane = try? pane.html()
        }
        // document.child(0) 即 <html>
        if let html = document.miscChild(0) {
            detail.htmlData = try? html.outerHtml()
        }
        return detail
    }
}
