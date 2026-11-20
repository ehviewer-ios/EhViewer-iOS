import Foundation
import SwiftSoup

/// 个人主页（home.php）：图片额度、重置花费、GP 收入、管理权限。对应 Android `parser/EhHomeParser`
public enum EhHomeParser {
    /// 旧版文案
    static let patternImageLimit = Regex2(
        "<p>You are currently at <strong>(\\d+)</strong> towards a limit of <strong>(\\d+)</strong>.</p>.+?<p>Reset Cost: <strong>(\\d+)</strong> GP</p>",
        options: [.dotMatchesLineSeparators])
    /// 新版文案。Java 依赖 Jsoup `html()` 的格式化输出（段落间恰为 "\n"）；
    /// SwiftSoup 输出的空白可能不同，这里先把空白折叠为单个空格，再把段落间的 "\n" 放宽为 `\s*`
    static let patternImageLimitNew = Regex2(
        "<p>You are currently at <strong>(.+?)</strong> towards your account limit of <strong>(.+?)</strong>.</p>\\s*<p>You can reset your image quota by spending <strong>(.+?)</strong> GP.</p>",
        options: [.dotMatchesLineSeparators])
    static let whitespace = Regex2("\\s+")

    static let homeBox = "homebox"

    /// 解析失败时与 Java 一致：返回已解析的部分（其余字段为 0 / -1）
    public static func parse(_ body: String) -> HomeDetail {
        var homeDetail = HomeDetail()
        guard let document = try? SwiftSoup.parse(body),
              let homeBoxes = try? document.getElementsByClass(homeBox),
              !homeBoxes.isEmpty() else { return homeDetail }

        if let imageLimits = homeBoxes.miscGet(0) {
            parseImageLimits(imageLimits, &homeDetail)
        }
        guard let totalGpGained = homeBoxes.miscGet(2),
              parseTotalGpGained(totalGpGained, &homeDetail) else { return homeDetail }
        if let moderationPower = homeBoxes.miscGet(4) {
            parseModerationPower(moderationPower, &homeDetail)
        }
        return homeDetail
    }

    private static func number(_ s: String?) -> Int64 {
        guard let s else { return -1 }
        return Int64(s.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)) ?? -1
    }

    @discardableResult
    private static func parseModerationPower(_ moderationPower: Element, _ homeDetail: inout HomeDetail) -> Bool {
        // homebox > table > tbody > tr > td > div[1]
        guard let rows = moderationPower.miscChild(0)?.miscChild(0),
              let el = rows.miscChild(0)?.miscChild(0)?.miscChild(1),
              let text = try? el.text() else { return false }
        homeDetail.currentModerationPower = number(text)
        return true
    }

    private static func parseTotalGpGained(_ totalGpGained: Element, _ homeDetail: inout HomeDetail) -> Bool {
        // homebox > table > tbody > tr[0..3] > td[0]
        guard let rows = totalGpGained.miscChild(0)?.miscChild(0) else { return false }
        func value(_ i: Int) -> Int64? {
            guard let td = rows.miscChild(i)?.miscChild(0), let t = try? td.text() else { return nil }
            return number(t)
        }
        guard let v0 = value(0), let v1 = value(1), let v2 = value(2), let v3 = value(3) else { return false }
        homeDetail.fromGalleryVisits = v0
        homeDetail.fromTorrentCompletions = v1
        homeDetail.fromArchiveDownloads = v2
        homeDetail.fromHentaiAtHome = v3
        return true
    }

    private static func parseImageLimits(_ imageLimits: Element, _ homeDetail: inout HomeDetail) {
        guard let raw = try? imageLimits.html() else { return }
        let html = whitespace.re.stringByReplacingMatches(
            in: raw, range: NSRange(location: 0, length: (raw as NSString).length), withTemplate: " ")
        guard let m = patternImageLimitNew.firstMatch(in: html) ?? patternImageLimit.firstMatch(in: html) else {
            return
        }
        func group(_ i: Int) -> String {
            m[i]?.replacingOccurrences(of: ",", with: "") ?? "0"
        }
        homeDetail.used = number(group(1))
        homeDetail.total = number(group(2))
        homeDetail.resetCost = number(group(3))
    }
}
