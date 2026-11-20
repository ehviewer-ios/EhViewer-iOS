import Foundation
import SwiftSoup

/// 画廊详情页（/g/{gid}/{token}/）解析：基本信息、tag、评论、预览图、新版本、种子/归档链接、apiUid/apiKey。
/// 对应 Android `client/parser/GalleryDetailParser`
public enum GalleryDetailParser {
    static let patternError = Regex2("<div class=\"d\">\n<p>([^<]+)</p>")
    static let patternDetail = Regex2(
        #"var gid = (\d+);.+?var token = "([a-f0-9]+)";.+?var apiuid = ([\-\d]+);.+?var apikey = "([a-f0-9]+)";"#,
        options: [.dotMatchesLineSeparators]
    )
    // 与 Java 相比把 "Torrent Download" / "Archive Download" 中的空格放宽为 \s+（页面被格式化换行时也能匹配）
    static let patternTorrent = Regex2(#"<a[^<>]*onclick="return popUp\('([^']+)'[^)]+\)">Torrent\s+Download\s+\((\d+)\)</a>"#)
    static let patternArchive = Regex2(#"<a[^<>]*onclick="return popUp\('([^']+)'[^)]+\)">Archive\s+Download</a>"#)
    static let patternCover = Regex2(#"width:(\d+)px; height:(\d+)px.+?url\((.+?)\)"#)
    static let patternTagGroup = Regex2(#"<tr><td[^<>]+>([\w\s]+):</td><td>(?:<div[^<>]+><a[^<>]+>[\w\s]+</a></div>)+</td></tr>"#)
    static let patternTag = Regex2(#"<div[^<>]+><a[^<>]+>([\w\s]+)</a></div>"#)
    static let patternComment = Regex2(
        #"<div class="c3">Posted on ([^<>]+) by: &nbsp; <a[^<>]+>([^<>]+)</a>.+?<div class="c6"[^>]*>(.+?)</div><div class="c[78]""#
    )
    // 以下两个正则在标签之间允许空白（Java 版要求标签紧邻）
    static let patternPages = Regex2(#"<tr>\s*<td[^<>]*>Length:</td>\s*<td[^<>]*>([\d,]+) pages</td>\s*</tr>"#)
    static let patternPreviewPages = Regex2(
        #"<td[^>]+>\s*<a[^>]+>([\d,]+)</a>\s*</td>\s*<td[^>]+>\s*(?:<a[^>]+>)?&gt;(?:</a>)?\s*</td>"#
    )
    /// 旧版 gdtm 雪碧图预览（允许标签间空白）
    static let patternNormalPreview = Regex2(
        #"<div class="gdtm"[^<>]*>\s*<div[^<>]*width:(\d+)[^<>]*height:(\d+)[^<>]*\((.+?)\)[^<>]*-(\d+)px[^<>]*>\s*<a[^<>]*href="(.+?)"[^<>]*>\s*<img alt="([\d,]+)""#
    )
    static let patternNormalPreviewNew = Regex2(
        #"<a href="(.+?)">[^<>]*<div[^<>]*title="Page (\d+):[^<>]*width:(\d+)[^<>]*height:(\d+)[^<>]*\((.+?)\)[^<>]*"></div>[^<>]*</a>"#
    )
    static let patternNormalPreviewNewWithLabel = Regex2(
        #"<a href="(.+?)">[^<>]*<div>[^<>]*<div[^<>]*title="Page (\d+):[^<>]*width:(\d+)[^<>]*height:(\d+)[^<>]*\((.+?)\)[^<>]*">"#
    )
    static let patternSmallPreview = Regex2(
        #"<a href="(.+?)">[^<>]*<div[^<>]*title="Page (\d+):[^<>]*width:(\d+)[^<>]*height:(\d+)[^<>]*\((.+?)\)[^<>]*-(\d+)px[^<>]*>"#
    )
    static let patternSmallPreviewWithLabel = Regex2(
        #"<a href="(.+?)">[^<>]*<div>[^<>]*<div[^<>]*title="Page (\d+):[^<>]*width:(\d+)[^<>]*height:(\d+)[^<>]*\((.+?)\)[^<>]*-(\d+)px[^<>]*>"#
    )
    static let patternLargePreview = Regex2(#"<div class="gdtl".+?<a href="(.+?)"><img alt="([\d,]+)".+?src="(.+?)""#)
    static let patternLargePreviewNew = Regex2(#"<a href="(.+?)">[^<>]*<div title="Page (\d+):[^<>]*\((.+?)\)[^<>]*0 0[^<>]*>"#)

    static let offensiveString =
        "<p>(And if you choose to ignore this warning, you lose all rights to complain about it in the future.)</p>"
    static let piningString = "<p>This gallery is pining for the fjords.</p>"
    static let unavailableString = "This gallery is unavailable"
    /// Java 端在 EhEngine 层处理；这里在解析器里额外识别，便于直接给出 banned 错误
    static let bannedString = "Your IP address has been temporarily banned"

    // MARK: - 评论时间 "dd MMMM yyyy, HH:mm"（UTC）

    private static let commentDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "dd MMMM yyyy, HH:mm"
        return f
    }()
    private static let dateLock = NSLock()

    /// "11 May 2022, 05:24" -> 毫秒时间戳
    static func parseCommentDate(_ s: String) -> Int64? {
        dateLock.lock(); defer { dateLock.unlock() }
        guard let d = commentDateFormatter.date(from: s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return Int64((d.timeIntervalSince1970 * 1000).rounded())
    }

    // MARK: - 入口

    /// - Parameters:
    ///   - thumbResolution: 对应 `Settings.getThumbResolution()`
    ///   - fixThumbUrl: 对应 `Settings.getFixThumbUrl()`，把大图预览地址改写到 ehgt.org
    ///   - isBlacklisted: 对应 `EhDB.inBlackList(user)`，命中的评论被过滤
    public static func parse(
        _ body: String,
        thumbResolution: Int = 0,
        fixThumbUrl: Bool = false,
        isBlacklisted: ((String?) -> Bool)? = nil
    ) throws -> GalleryDetail {
        if body.contains(offensiveString) { throw EhError.offensive }
        if body.contains(piningString) { throw EhError.pining }
        if body.contains(unavailableString) { throw EhError.server("此画廊已被下架\nThis gallery is unavailable") }
        if body.contains(bannedString) { throw EhError.banned(String(GallerySoup.trim(body).prefix(512))) }

        // 错误信息页
        if let m = patternError.firstMatch(in: body), let msg = m[1] {
            throw EhError.server(msg)
        }

        guard let document = GallerySoup.parse(body) else {
            throw EhError.parseFailure("Can't parse gallery detail", html: body)
        }
        var gd = GalleryDetail(info: GalleryInfo())
        try parseDetail(&gd, document, body, thumbResolution: thumbResolution)
        gd.tags = parseTagGroups(document)
        gd.comments = parseComments(document, isBlacklisted: isBlacklisted)
        gd.previewPages = try parsePreviewPages(document, body)
        gd.previewSet = parsePreviewSet(document, body, fixThumbUrl: fixThumbUrl)
        gd.spiderInfoPages = try parsePages(body)
        gd.spiderInfoPreviewPages = try parsePreviewPages(body)
        gd.spiderInfoPreviewSet = parsePreviewSet(body, fixThumbUrl: fixThumbUrl)
        return gd
    }

    // MARK: - 基本信息

    private static func parseDetail(_ gd: inout GalleryDetail, _ d: Document, _ body: String, thumbResolution: Int) throws {
        guard let m = patternDetail.firstMatch(in: body) else {
            throw EhError.parseFailure("Can't parse gallery detail", html: body)
        }
        gd.info.gid = GallerySoup.parseLong(m[1], -1)
        gd.info.token = m[2] ?? ""
        gd.apiUid = GallerySoup.parseLong(m[3], -1)
        gd.apiKey = m[4]
        if gd.info.gid == -1 {
            throw EhError.parseFailure("Can't parse gallery detail", html: body)
        }

        if let m = patternTorrent.firstMatch(in: body) {
            gd.torrentUrl = ParserUtils.unescapeXml(GallerySoup.trim(m[1]))
            gd.torrentCount = GallerySoup.parseInt(m[2], 0)
        } else {
            gd.torrentCount = 0
            gd.torrentUrl = ""
        }

        if let m = patternArchive.firstMatch(in: body) {
            gd.archiveUrl = ParserUtils.unescapeXml(GallerySoup.trim(m[1]))
        } else {
            gd.archiveUrl = ""
        }

        guard let gm = d.glFirstByClass("gm") else {
            throw EhError.parseFailure("Can't parse gallery detail", html: body)
        }

        // 封面
        if let style = gm.glById("gd1")?.glChild(0)?.glAttr("style") {
            gd.info.thumb = parseCoverStyle(GallerySoup.trim(style), thumbResolution: thumbResolution)
        } else {
            gd.info.thumb = ""
        }

        // 标题
        gd.info.title = gm.glById("gn").map { GallerySoup.trim($0.glText) } ?? ""
        gd.info.titleJpn = gm.glById("gj").map { GallerySoup.trim($0.glText) } ?? ""

        // 分类
        if let gdc = gm.glById("gdc"), let ce = gdc.glFirstByClass("cn") ?? gdc.glFirstByClass("cs") {
            gd.info.category = EhCategory.from(string: ce.glText)
        } else {
            gd.info.category = .unknown
        }

        // 上传者
        gd.info.uploader = gm.glById("gdn").map { GallerySoup.trim($0.glText) } ?? ""

        // 发布时间、父画廊、可见性、语言、大小、页数、收藏数
        gd.info.posted = ""
        gd.parent = ""
        gd.visible = ""
        gd.size = ""
        gd.info.pages = 0
        gd.favoriteCount = 0
        if let rows = gm.glById("gdd")?.glChild(0)?.glChild(0)?.children() {
            for row in rows {
                parseDetailInfo(&gd, row)
            }
        }

        // 评分人数
        if let rc = gm.glById("rating_count") {
            gd.ratingCount = GallerySoup.parseInt(GallerySoup.trim(rc.glText), 0)
        } else {
            gd.ratingCount = 0
        }

        // 评分
        if let label = gm.glById("rating_label") {
            let ratingStr = GallerySoup.trim(label.glText)
            if ratingStr == "Not Yet Rated" {
                gd.info.rating = -1
            } else if let sp = ratingStr.firstIndex(of: " ") {
                gd.info.rating = GallerySoup.parseFloat(String(ratingStr[ratingStr.index(after: sp)...]), 0)
            } else {
                gd.info.rating = 0
            }
        } else {
            gd.info.rating = -1
        }

        // 是否已收藏
        let gdf = gm.glById("gdf")
        let favText = gdf.map { GallerySoup.trim($0.glText) }
        gd.isFavorited = favText != nil && favText != "Add to Favorites"
        if let favText {
            gd.info.favoriteName = favText == "Add to Favorites" ? nil : favText
        }

        gd.newVersions = parseNewVersions(d)
    }

    /// 新版本列表（#gnd 中的链接 + 其后的 ", added yyyy-MM-dd HH:mm" 文本）
    static func parseNewVersions(_ d: Document) -> [GalleryNewVersion] {
        guard let gnd = d.glById("gnd") else { return [] }
        let textNodes = gnd.textNodes()
        var list: [GalleryNewVersion] = []
        for urlE in gnd.children() {
            let url = (try? urlE.absUrl("href")) ?? ""
            guard !url.isEmpty else { continue }
            // 与 Java 一致：文本节点数量不足时整体放弃
            guard list.count < textNodes.count else { return [] }
            let name = urlE.glText
            let time = textNodes[list.count].text()
            list.append(GalleryNewVersion(versionUrl: url, versionName: time.isEmpty ? name : name + time))
        }
        return list
    }

    /// `width:250px; height:356px; background:transparent url(https://...jpg_250.jpg) 0 0 no-repeat` -> 封面 URL
    static func parseCoverStyle(_ str: String, thumbResolution: Int = 0) -> String {
        guard let m = patternCover.firstMatch(in: str) else { return "" }
        return EhUtils.handleThumbUrlResolution(m[3], resolution: thumbResolution) ?? ""
    }

    private static func parseDetailInfo(_ gd: inout GalleryDetail, _ e: Element) {
        let es = e.children()
        guard es.count >= 2 else { return }
        let key = GallerySoup.trim(es.get(0).glText)
        let value = GallerySoup.trim(es.get(1).ownText())
        if key.hasPrefix("Posted") {
            gd.info.posted = value
        } else if key.hasPrefix("Parent") {
            if let a = es.get(1).children().first() {
                gd.parent = a.glAttr("href")
            }
        } else if key.hasPrefix("Visible") {
            gd.visible = value
        } else if key.hasPrefix("Language") {
            gd.language = value
        } else if key.hasPrefix("File Size") {
            gd.size = value
        } else if key.hasPrefix("Length") {
            if let sp = value.firstIndex(of: " ") {
                gd.info.pages = GallerySoup.parseInt(String(value[..<sp]), 1)
            } else {
                gd.info.pages = 1
            }
        } else if key.hasPrefix("Favorited") {
            switch value {
            case "Never": gd.favoriteCount = 0
            case "Once": gd.favoriteCount = 1
            default:
                if let sp = value.firstIndex(of: " ") {
                    gd.favoriteCount = GallerySoup.parseInt(String(value[..<sp]), 0)
                } else {
                    gd.favoriteCount = 0
                }
            }
        }
    }

    // MARK: - Tag

    private static func parseTagGroup(_ element: Element) -> GalleryTagGroup? {
        guard let nsE = element.glChild(0), let tagsE = element.glChild(1) else { return nil }
        var nameSpace = nsE.glText
        // 去掉末尾的 ':'
        guard !nameSpace.isEmpty else { return nil }
        nameSpace.removeLast()
        var group = GalleryTagGroup(groupName: nameSpace)
        for t in tagsE.children() {
            var tag = t.glText
            // parody 等 tag 有时会跟 '|' 和英文翻译，去掉
            if let i = tag.firstIndex(of: "|") {
                tag = GallerySoup.trim(String(tag[..<i]))
            }
            group.tags.append(tag)
        }
        return group.tags.isEmpty ? nil : group
    }

    /// 从详情页 #taglist 解析 tag 分组
    public static func parseTagGroups(_ document: Document) -> [GalleryTagGroup] {
        guard let trs = document.glById("taglist")?.glChild(0)?.glChild(0)?.children() else { return [] }
        return parseTagGroups(trs.array())
    }

    /// 从 tag 表格行解析（列表页 Extended 模式也复用）
    public static func parseTagGroups(_ trs: [Element]) -> [GalleryTagGroup] {
        trs.compactMap(parseTagGroup)
    }

    /// 正则版 tag 解析（Java 中为 private，未被调用，保留以便对照）
    static func parseTagGroups(body: String) -> [GalleryTagGroup] {
        patternTagGroup.allMatches(in: body).map { m in
            var group = GalleryTagGroup(groupName: ParserUtils.trim(m[1]))
            for t in patternTag.allMatches(in: m[0] ?? "") {
                group.tags.append(ParserUtils.trim(t[1]))
            }
            return group
        }
    }

    // MARK: - 评论

    public static func parseComment(_ element: Element) -> GalleryComment? {
        var comment = GalleryComment()
        // id 来自前一个兄弟元素 <a name="c123">
        guard let a = try? element.previousElementSibling() else { return nil }
        let name = GallerySoup.trim(a.glAttr("name"))
        guard !name.isEmpty else { return nil }
        if let id = Int64(name.dropFirst()) {
            comment.id = id
        }

        // 是否可编辑、可投票
        let c4 = element.glFirstByClass("c4")
        if let c4 {
            for e in c4.children() {
                switch e.glText {
                case "Vote+":
                    comment.voteUpAble = true
                    comment.voteUpEd = !GallerySoup.trim(e.glAttr("style")).isEmpty
                case "Vote-":
                    comment.voteDownAble = true
                    comment.voteDownEd = !GallerySoup.trim(e.glAttr("style")).isEmpty
                case "Edit":
                    comment.editable = true
                default: break
                }
            }
        }
        // 投票明细
        if let c7 = element.glFirstByClass("c7") {
            comment.voteState = GallerySoup.trim(c7.glText)
        }
        // 分数
        if let c5 = element.glFirstByClass("c5"), let first = c5.children().first() {
            comment.score = GallerySoup.parseInt(GallerySoup.trim(first.glText), 0)
        }
        // 时间
        guard let c3 = element.glFirstByClass("c3") else { return nil }
        // "Posted on 11 May 2022, 05:24 by: &nbsp;"。Java 用 SimpleDateFormat 解析前缀、容忍尾部残留；
        // DateFormatter 要求整串匹配，所以这里截到 " by:" 为止
        var temp = c3.ownText()
        let prefix = "Posted on "
        guard temp.count >= prefix.count else { return nil }
        temp = String(temp.dropFirst(prefix.count))
        if let r = temp.range(of: " by:") {
            temp = String(temp[..<r.lowerBound])
        }
        guard let time = parseCommentDate(temp) else { return nil }
        comment.time = time
        // 用户
        if c3.children().isEmpty() {
            guard let c4 else { return nil }
            comment.user = c4.glText
        } else {
            comment.user = c3.glChild(0)?.glText
        }
        // 正文（保留 HTML）
        guard let c6 = element.glFirstByClass("c6") else { return nil }
        comment.comment = c6.glHtml
        // 最后编辑时间：Java 误用了发表时间，这里解析 c8 内 <strong> 的时间，失败时退回与 Java 一致的发表时间
        if let c8 = element.glFirstByClass("c8"), let e = c8.children().first() {
            comment.lastEdited = parseCommentDate(e.glText) ?? time
        }
        return comment
    }

    /// 从 #cdiv 解析评论；`hasMore` 表示存在 "click to show all"
    public static func parseComments(_ document: Document, isBlacklisted: ((String?) -> Bool)? = nil) -> GalleryCommentList {
        guard let cdiv = document.glById("cdiv") else { return GalleryCommentList() }
        var list: [GalleryComment] = []
        for c1 in cdiv.glAllByClass("c1") ?? [] {
            if let comment = parseComment(c1), !(isBlacklisted?(comment.user) ?? false) {
                list.append(comment)
            }
        }
        var hasMore = false
        if let chd = cdiv.glById("chd"), let all = try? chd.getAllElements() {
            hasMore = all.contains { $0.glText == "click to show all" }
        }
        return GalleryCommentList(comments: list, hasMore: hasMore)
    }

    /// 正则版评论解析（只有时间、用户、正文）
    public static func parseComments(body: String) -> [GalleryComment] {
        patternComment.allMatches(in: body).map { m in
            var c = GalleryComment()
            c.time = parseCommentDate(ParserUtils.trim(m[1])) ?? 0
            c.user = ParserUtils.trim(m[2])
            c.comment = m[3] ?? ""
            return c
        }
    }

    // MARK: - 页数

    /// 预览分页总数（DOM 版，来自 .ptt）
    public static func parsePreviewPages(_ document: Document, _ body: String) throws -> Int {
        guard let es = document.glFirstByClass("ptt")?.glChild(0)?.glChild(0)?.children(), es.count >= 2,
              let n = Int(es.get(es.count - 2).glText) else {
            throw EhError.parseFailure("Can't parse preview pages", html: body)
        }
        return n
    }

    /// 预览分页总数（正则版）
    public static func parsePreviewPages(_ body: String) throws -> Int {
        var previewPages = -1
        if let m = patternPreviewPages.firstMatch(in: body) {
            previewPages = ParserUtils.parseInt(m[1], -1)
        }
        if previewPages <= 0 {
            throw EhError.parseFailure("Parse preview page count error", html: body)
        }
        return previewPages
    }

    /// 图片总页数（正则版）
    public static func parsePages(_ body: String) throws -> Int {
        var pages = -1
        if let m = patternPages.firstMatch(in: body) {
            pages = ParserUtils.parseInt(m[1], -1)
        }
        if pages < 0 {
            throw EhError.parseFailure("Parse pages error", html: body)
        }
        return pages
    }

    // MARK: - 预览图

    /// 优先在 .gt200 / .gt100 容器中匹配，先尝试雪碧图（Normal），再尝试大图（Large）；都失败返回空的 Normal 集合
    public static func parsePreviewSet(_ d: Document, _ body: String, fixThumbUrl: Bool = false) -> PreviewSet {
        var previewClass = (try? d.getElementsByClass("gt200").html()) ?? ""
        if previewClass.isEmpty {
            previewClass = (try? d.getElementsByClass("gt100").html()) ?? ""
        }
        let source = previewClass.isEmpty ? body : previewClass
        var set = parseNormalPreviewSet(source)
        if set.isEmpty {
            set = parseLargePreviewSet(source, fixThumbUrl: fixThumbUrl)
        }
        if set.isEmpty {
            return PreviewSet(isLarge: false)
        }
        return set
    }

    public static func parsePreviewSet(_ body: String, fixThumbUrl: Bool = false) -> PreviewSet {
        guard let d = GallerySoup.parse(body) else { return PreviewSet(isLarge: false) }
        return parsePreviewSet(d, body, fixThumbUrl: fixThumbUrl)
    }

    private static func parseLargePreviewSet(_ body: String, fixThumbUrl: Bool) -> PreviewSet {
        var set = PreviewSet(isLarge: true)
        findLarge(patternLargePreviewNew, body, &set, fixThumbUrl: fixThumbUrl)
        if set.isEmpty {
            findLarge(patternLargePreview, body, &set, fixThumbUrl: fixThumbUrl)
        }
        return set
    }

    private static func findLarge(_ regex: Regex2, _ body: String, _ set: inout PreviewSet, fixThumbUrl: Bool) {
        for m in regex.allMatches(in: body) {
            let index = ParserUtils.parseInt(m[2], 0) - 1
            if index < 0 { continue }
            var imageUrl = ParserUtils.trim(m[3])
            let pageUrl = ParserUtils.trim(m[1])
            if fixThumbUrl {
                imageUrl = EhURL.fixedPreviewThumbUrl(imageUrl)
            }
            set.addLargeItem(position: index, imageUrl: imageUrl, pageUrl: pageUrl)
        }
    }

    private static func parseNormalPreviewSet(_ body: String) -> PreviewSet {
        var set = PreviewSet(isLarge: false)
        for regex in [patternSmallPreview, patternNormalPreviewNew, patternSmallPreviewWithLabel, patternNormalPreviewNewWithLabel] {
            parseNewPreview(regex, body, &set)
            if !set.isEmpty { return set }
        }

        for m in patternNormalPreview.allMatches(in: body) {
            let position = ParserUtils.parseInt(m[6], 0) - 1
            if position < 0 { continue }
            let imageUrl = ParserUtils.trim(m[3])
            let xOffset = ParserUtils.parseInt(m[4], 0)
            let width = ParserUtils.parseInt(m[1], 0)
            if width <= 0 { continue }
            let height = ParserUtils.parseInt(m[2], 0)
            if height <= 0 { continue }
            let pageUrl = ParserUtils.trim(m[5])
            set.addNormalItem(position: position, imageUrl: imageUrl, xOffset: xOffset, yOffset: 0,
                              width: width, height: height, pageUrl: pageUrl)
        }
        return set
    }

    private static func parseNewPreview(_ regex: Regex2, _ body: String, _ set: inout PreviewSet) {
        for m in regex.allMatches(in: body) {
            let position = ParserUtils.parseInt(m[2], 0) - 1
            if position < 0 { continue }
            let imageUrl = ParserUtils.trim(m[5])
            // 无偏移分组（groupCount < 6）时 x 偏移为 0
            let xOffset = m.count > 6 ? ParserUtils.parseInt(m[6], 0) : 0
            let width = ParserUtils.parseInt(m[3], 0)
            if width <= 0 { continue }
            let height = ParserUtils.parseInt(m[4], 0)
            if height <= 0 { continue }
            let pageUrl = ParserUtils.trim(m[1])
            set.addNormalItem(position: position, imageUrl: imageUrl, xOffset: xOffset, yOffset: 0,
                              width: width, height: height, pageUrl: pageUrl)
        }
    }
}
