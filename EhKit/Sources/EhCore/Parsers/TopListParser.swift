import Foundation
import SwiftSoup

/// 排行榜总览页（toplist.php）。对应 Android `parser/TopListParser`
public enum TopListParser {
    static let offensiveString =
        "<p>(And if you choose to ignore this warning, you lose all rights to complain about it in the future.)</p>"
    static let piningString = "<p>This gallery is pining for the fjords.</p>"
    static let patternError = Regex2("<div class=\"d\">\n<p>([^<]+)</p>")

    public static func parse(_ body: String) throws -> EhTopListDetail {
        if body.contains(offensiveString) {
            throw EhError.offensive
        }
        if body.contains(piningString) {
            throw EhError.pining
        }
        if let m = patternError.firstMatch(in: body), let msg = m[1] {
            throw EhError.server(msg)
        }

        do {
            let document = try SwiftSoup.parse(body)
            guard let ido = try document.getElementsByClass("ido").first() else {
                throw EhError.parseFailure("Can't find .ido", html: body)
            }
            let elements = ido.children()
            func section(_ i: Int, _ type: EhTopListDetail.ListType) throws -> TopListInfo {
                guard let e = elements.miscGet(i) else {
                    throw EhError.parseFailure("Missing top list section \(i)", html: body)
                }
                return try parseInfo(e, type, body)
            }
            var detail = EhTopListDetail()
            detail.title = try elements.miscGet(0)?.text()
            detail.galleryTopListInfo = try section(1, .gallery)
            detail.uploaderTopListInfo = try section(3, .uploader)
            detail.taggingTopListInfo = try section(5, .tagging)
            detail.hentaiHomeTopListInfo = try section(7, .hentaiHome)
            detail.ehTrackerTopListInfo = try section(9, .ehTracker)
            detail.cleanUpTopListInfo = try section(11, .cleanup)
            detail.ratingAndReviewingTopListInfo = try section(13, .ratingAndReviewing)
            return detail
        } catch let e as EhError {
            throw e
        } catch {
            throw EhError.parseFailure("Top list parser error: \(error)", html: body)
        }
    }

    private static func parseInfo(_ element: Element, _ type: EhTopListDetail.ListType, _ body: String) throws -> TopListInfo {
        let elements = element.children()
        // 每个 .tdo 结构：p(标题) + table > tbody
        func array(_ i: Int) throws -> TopListItemArray {
            guard let tbody = elements.miscGet(i)?.miscChild(1)?.miscChild(0) else {
                throw EhError.parseFailure("Missing top list table", html: body)
            }
            return try parseArray(tbody)
        }
        var info = TopListInfo(type: type)
        info.allTimeTopList = try array(1)
        info.pastYearTopList = try array(2)
        info.pastMonthTopList = try array(3)
        info.yesterdayTopList = try array(4)
        return info
    }

    private static func parseArray(_ ele: Element) throws -> TopListItemArray {
        var items: [TopListItem] = []
        // Java 为定长 10 的数组，超过 10 项会越界；这里截取前 10
        for tun in try ele.getElementsByClass("tun").array().prefix(10) {
            guard let a = tun.miscChild(0) else { continue }
            items.append(TopListItem(href: try a.attr("href"), value: try a.text()))
        }
        return TopListItemArray(itemArray: items)
    }
}
