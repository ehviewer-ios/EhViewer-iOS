import Foundation
import SwiftSoup

/// 页面中的事件面板（"新的一天"奖励、遭遇怪物等）。对应 Android `parser/EhEventParse`（保留原类名）
public enum EhEventParse {
    /// 返回 `#eventpane` 的内部 HTML；不存在返回 nil
    public static func parse(_ body: String) -> String? {
        guard let document = try? SwiftSoup.parse(body),
              let eventPane = try? document.getElementById("eventpane") else { return nil }
        return try? eventPane.html()
    }
}
