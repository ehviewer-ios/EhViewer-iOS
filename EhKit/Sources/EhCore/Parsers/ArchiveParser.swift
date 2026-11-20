import Foundation
import SwiftSoup

/// 归档下载（archiver.php）。对应 Android `parser/ArchiveParser`，
/// 以及 `EhEngine.downloadArchive / downloadArchiver` 中内联的解析逻辑
public enum ArchiveParser {
    public struct Result: Codable, Sendable, Hashable {
        /// 表单参数 or（H@H 下载 / 归档下载需要）
        public var paramOr: String
        public var archiveList: [ArchiveItem]
        public init(paramOr: String = "", archiveList: [ArchiveItem] = []) {
            self.paramOr = paramOr
            self.archiveList = archiveList
        }
    }

    /// Java 原式中属性间为单个空格；这里放宽为 `\\s+`，以兼容格式化过的页面
    static let patternForm = Regex2("<form\\s+id=\"hathdl_form\"\\s+action=\"[^\"]*?or=([^=\"]*?)\"\\s+method=\"post\">")
    static let patternArchive = Regex2("<a href=\"[^\"]*\" onclick=\"return do_hathdl\\('([0-9]+|org)'\\)\">([^<]+)</a>")
    static let patternArchiverDownloadUrl = Regex2("href=\"(.*)\">Click Here To Start Downloading")
    /// `EhEngine.PATTERN_NEED_HATH_CLIENT`
    static let patternNeedHathClient = Regex2("(You must have a H@H client assigned to your account to use this feature\\.)")
    /// `EhEngine.downloadArchiver` 中的跳转脚本
    static let patternDocumentLocation = Regex2("document.location = \"(.*)\"")

    /// H@H 下载选项与 or 参数。对应 `parse(String)`
    public static func parse(_ body: String) -> Result {
        var result = Result()
        if let m = patternForm.firstMatch(in: body), let or = m[1] {
            result.paramOr = or
        }
        for m in patternArchive.allMatches(in: body) {
            result.archiveList.append(ArchiveItem(res: ParserUtils.trim(m[1]), name: ParserUtils.trim(m[2])))
        }
        return result
    }

    /// 归档下载对话框（原图/重采样的花费、大小、表单地址）。对应 `parseArchiver(String)`。
    /// Java 用 `document.childNode(2).childNode(3).childNode(1)` 定位 `div#db`，这里直接取 `#db`
    /// （找不到时退回 body 的第一个子元素）。表站与里站布局不同，需传入站点。
    /// 结构不符时与 Java 一致：静默返回已解析的部分。
    public static func parseArchiver(_ body: String, site: EhSite) -> ArchiverData {
        var data = ArchiverData()
        guard let document = try? SwiftSoup.parse(body),
              let bodyElement = (try? document.getElementById("db")) ?? document.body()?.miscChild(0)
        else { return data }

        let fundsIndex = site == .e ? 2 : 0
        let containerIndex = site == .e ? 3 : 1
        do {
            guard let funds = bodyElement.miscChild(fundsIndex) else { return data }
            data.funds = try funds.text()

            guard let original = bodyElement.miscChild(containerIndex)?.miscChild(0) else { return data }
            guard let oc = original.miscChild(0)?.miscChild(0) else { return data }
            data.originalCost = try oc.text()
            guard let os = original.miscChild(2)?.miscChild(0) else { return data }
            data.originalSize = try os.text()
            guard let of = original.miscChild(1) else { return data }
            data.originalUrl = try of.attr("action")

            guard let resample = bodyElement.miscChild(containerIndex)?.miscChild(1) else { return data }
            guard let rc = resample.miscChild(0)?.miscChild(0) else { return data }
            data.resampleCost = try rc.text()
            guard let rs = resample.miscChild(2)?.miscChild(0) else { return data }
            data.resampleSize = try rs.text()
            guard let rf = resample.miscChild(1) else { return data }
            data.resampleUrl = try rf.attr("action")
        } catch {
            // 与 Java 的 catch (Exception ignore) 一致
        }
        return data
    }

    /// 归档准备完成页中的下载路径（相对路径）。对应 `parseArchiverDownloadUrl(String)`
    public static func parseArchiverDownloadUrl(_ body: String) -> String? {
        patternArchiverDownloadUrl.firstMatch(in: body)?[1] ?? nil
    }

    /// POST 归档表单（dltype/dlcheck）后的响应中提取跳转地址。对应 `EhEngine.downloadArchiver` 内联逻辑；
    /// 返回 nil 时 Java 直接返回 null（无下载地址）
    public static func parseArchiverContinueUrl(_ body: String) -> String? {
        patternDocumentLocation.firstMatch(in: body)?[1] ?? nil
    }

    /// 对应 `EhEngine.downloadArchiver` 末尾的 `"https://" + host + downloadPath`。
    /// - Parameters:
    ///   - host: 跳转页最终响应 URL 的 host
    ///   - body: 跳转页响应
    public static func archiverDownloadUrl(host: String, body: String) -> String? {
        // Java 中 downloadPath 为 null 时会拼出 ".../null"，这里返回 nil
        guard let path = parseArchiverDownloadUrl(body) else { return nil }
        return "https://" + host + path
    }

    /// H@H 下载请求的响应检查。对应 `EhEngine.downloadArchive` 末尾的 PATTERN_NEED_HATH_CLIENT 检查
    public static func checkDownloadArchive(_ body: String) throws {
        if patternNeedHathClient.matches(body) {
            throw EhError.noHAtH
        }
    }
}
