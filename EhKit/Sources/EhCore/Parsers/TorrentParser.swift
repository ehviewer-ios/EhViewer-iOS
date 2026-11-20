import Foundation

/// 种子列表（gallerytorrents.php）。对应 Android `parser/TorrentParser`
public enum TorrentParser {
    static let patternTorrentBlock = Regex2("<form\\b[^>]*>.*?</form>", options: [.dotMatchesLineSeparators])
    static let patternPosted = Regex2(
        "<span[^>]*>\\s*Posted:\\s*</span>\\s*<span>([^<]+)</span>", options: [.dotMatchesLineSeparators])
    /// Java 原式为 `<a href=`、`</a></td>`；这里放宽为 `<a\\s+href=`、`</a>\\s*</td>` 以兼容格式化过的页面
    static let patternTorrent = Regex2(
        "<td colspan=\"5\">\\s*&nbsp;\\s*<a\\s+href=\"([^\"]+)\"[^<]*>([^<]+)</a>\\s*</td>", options: [.dotMatchesLineSeparators])

    public static func parse(_ body: String) -> [TorrentInfo] {
        var list: [TorrentInfo] = []
        for blockMatch in patternTorrentBlock.allMatches(in: body) {
            guard let block = blockMatch[0],
                  let m = patternTorrent.firstMatch(in: block) else { continue }
            // 去掉 ?p= 使种子可分发
            var url = ParserUtils.trim(m[1])
            if let r = url.range(of: "?p=") {
                url = String(url[..<r.lowerBound])
            }
            let name = ParserUtils.trim(m[2])
            var posted = ""
            if let pm = patternPosted.firstMatch(in: block) {
                posted = ParserUtils.trim(pm[1])
            }
            list.append(TorrentInfo(url: url, name: name, posted: posted))
        }
        return list
    }
}
