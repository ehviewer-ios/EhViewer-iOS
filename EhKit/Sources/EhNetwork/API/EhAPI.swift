import Foundation

/// 业务 API。对应 Android `client/EhEngine`（+ `EhClient` 的方法分派，Swift 中直接用 async 函数替代）。
///
/// 每个方法的 URL、方法、表单字段 / JSON body（含键顺序）、Referer / Origin 与 Java 一致。
/// 错误识别见 `EhEngineErrors.map`（对应 `doThrowException`）。取消由 Swift 结构化并发负责（对应 `Task.stop`）。
///
/// 设置通过 `environment` 闭包在每次调用时读取；过滤器、本地收藏、黑名单、事件面板等通过 `hooks` 注入。
public final class EhAPI: Sendable {
    public let client: EhHTTPClient
    public let hooks: EhAPIHooks
    private let environmentProvider: @Sendable () -> EhAPIEnvironment

    static let mediaTypeJSON = "application/json; charset=utf-8"
    /// OkHttp `FormBody` 的 Content-Type
    static let mediaTypeForm = "application/x-www-form-urlencoded"
    /// `RequestBody.create(MEDIA_TYPE_URLENCODED, String)`：OkHttp 会自动补上 charset
    static let mediaTypeURLEncodedString = "application/x-www-form-urlencoded; charset=utf-8"
    /// gdata 每次最多 25 条
    public static let maxGdataRequestSize = 25

    public init(client: EhHTTPClient, hooks: EhAPIHooks = EhAPIHooks(),
                environment: @escaping @Sendable () -> EhAPIEnvironment) {
        self.client = client
        self.hooks = hooks
        environmentProvider = environment
    }

    public convenience init(client: EhHTTPClient, environment: EhAPIEnvironment = EhAPIEnvironment(),
                            hooks: EhAPIHooks = EhAPIHooks()) {
        self.init(client: client, hooks: hooks, environment: { environment })
    }

    public var environment: EhAPIEnvironment { environmentProvider() }

    // MARK: - 登录 / 个人资料

    /// 账号密码登录，返回显示名。对应 `signIn`
    public func signIn(username: String, password: String) async throws -> String {
        let req = try formRequest(EhURL.apiSignIn, fields: [
            ("UserName", username),
            ("PassWord", password),
            ("submit", "Log me in"),
            ("CookieDate", "1"),
            ("temporary_https", "off"),
        ], referer: "https://forums.e-hentai.org/index.php?act=Login&CODE=00", origin: "https://forums.e-hentai.org")
        return try await perform(req) { _, body in try SignInParser.parse(body) }
    }

    /// 校验当前 Cookie 是否已登录：主站 home.php 已登录返回 200，未登录 302 跳转到 bounce_login。
    /// 论坛（forums.e-hentai.org）开启 Cloudflare 人机验证后无法用于校验，改用主站
    public func checkSignedIn() async throws -> Bool {
        var req = try request(EhURL.homeE, referer: "https://e-hentai.org/")
        req.followRedirects = false
        let (resp, body) = try await send(req)
        if (300..<400).contains(resp.status) { return false }
        if resp.status == 200 { return !body.contains("bounce_login") }
        throw mapError(EhError.http(status: resp.status), resp, body)
    }

    /// 论坛首页 → 个人资料页 → 显示名与头像。对应 `getProfile`
    public func getProfile() async throws -> ProfileParser.Result {
        let req = try request(EhURL.forums, referer: nil)
        let profileUrl = try await perform(req) { _, body in try ForumsParser.parse(body) }
        let req2 = try request(profileUrl, referer: EhURL.forums)
        return try await perform(req2) { _, body in try ProfileParser.parse(body) }
    }

    /// 对应 `GetProfileScene`：Android 用 WebView 加载论坛首页后取 `outerHTML` 交给 `ProfileParser.parseNew`
    /// （从 `#userlinks` 取显示名）。这里直接 GET 论坛首页（带登录 cookie）并解析
    public func getProfileFromForums() async throws -> ProfileParser.Result {
        let req = try request(EhURL.forums, referer: nil)
        return try await perform(req) { _, body in try ProfileParser.parseNew(body) }
    }

    // MARK: - 画廊列表

    /// 画廊列表（首页 / 搜索 / 订阅 / 热门等）。对应 `getGalleryList(task, client, url, mode)`（mode 在 Java 中未使用）
    public func getGalleryList(url: String) async throws -> GalleryListParser.Result {
        let env = environment
        let req = try request(url, referer: env.site.referer)
        let (resp, body) = try await send(req)
        var result: GalleryListParser.Result
        do {
            result = try GalleryListParser.parse(body, thumbResolution: env.thumbResolution,
                                                 isLocalFavorite: hooks.isLocalFavorite)
        } catch {
            // Java 的意图：里站首页返回空白页 = igneous 错误。但 Java 中空页面会先在解析阶段抛错，
            // 下面的 customErrorString 永远走不到；这里在解析失败时直接给出该提示
            if resp.status == 200, url == "https://exhentai.org/", body.isEmpty {
                throw EhError.server(EhEngineErrors.igneousWrongMessage)
            }
            throw mapError(error, resp, body)
        }
        result.galleryInfoList = try await fillGalleryList(result.galleryInfoList, url: url, filter: true, env: env)
        if resp.status == 200, url == "https://exhentai.org/", body.isEmpty {
            result.customErrorString = EhEngineErrors.igneousWrongMessage
        }
        return result
    }

    /// 以图搜图（multipart 上传）。对应 `imageSearch(task, client, File, uss, osc, se)`：
    /// 文件名不含 "." 时补 ".jpg"（Java 会复制出一个带后缀的临时文件，这里只改上传的文件名）。
    /// Java 使用图片 client（不跟随重定向、20s 超时），302 时手动 GET Location
    public func imageSearch(imageData: Data, fileName: String, uss: Bool, osc: Bool, se: Bool) async throws -> GalleryListParser.Result {
        let env = environment
        let name = fileName.contains(".") ? fileName : fileName + ".jpg"
        var parts: [OkHttpMultipart.Part] = [
            .init(disposition: "form-data; name=\"sfile\"; filename=\"\(name)\"; size=\"40\"", data: imageData),
        ]
        if uss { parts.append(.init(disposition: "form-data; name=\"fs_similar\"", data: Data("on".utf8))) }
        if osc { parts.append(.init(disposition: "form-data; name=\"fs_covers\"", data: Data("on".utf8))) }
        if se { parts.append(.init(disposition: "form-data; name=\"fs_exp\"", data: Data("on".utf8))) }
        parts.append(.init(disposition: "form-data; name=\"f_sfile\"", data: Data("File Search".utf8)))

        let url = EhURL.imageSearch(env.site)
        let referer = env.site.referer + "/"
        let boundary = UUID().uuidString.lowercased()
        var req = try request(url, method: .post, referer: referer, origin: env.site.origin,
                              contentType: OkHttpMultipart.contentType(boundary: boundary),
                              body: OkHttpMultipart.encode(parts, boundary: boundary))
        req.followRedirects = false
        req.timeout = client.config.imageTimeout

        var (resp, body) = try await send(req)
        if resp.status == 302 {
            guard let loc = resp.headers["Location"],
                  let next = URL(string: loc, relativeTo: resp.url)?.absoluteURL else {
                throw EhError.other("Image search: missing Location")
            }
            var r2 = client.makeRequest(next, referer: referer)
            r2.followRedirects = false
            r2.timeout = client.config.imageTimeout
            (resp, body) = try await send(r2)
        }
        var result: GalleryListParser.Result
        do {
            result = try GalleryListParser.parse(body, thumbResolution: env.thumbResolution,
                                                 isLocalFavorite: hooks.isLocalFavorite)
        } catch {
            throw mapError(error, resp, body)
        }
        result.galleryInfoList = try await fillGalleryList(result.galleryInfoList, url: url, filter: true, env: env)
        return result
    }

    /// 便捷：从文件读取图片再搜索（文件名取自路径）
    public func imageSearch(imageFile: URL, uss: Bool, osc: Bool, se: Bool) async throws -> GalleryListParser.Result {
        let data: Data
        do { data = try Data(contentsOf: imageFile) } catch { throw EhError.other("读取图片失败：\(error.localizedDescription)") }
        return try await imageSearch(imageData: data, fileName: imageFile.lastPathComponent, uss: uss, osc: osc, se: se)
    }

    /// 对应 `fillGalleryList`：过滤标题 / 上传者 → 需要时 gdata 补全 → 过滤上传者 / tag / 命名空间 → 修正缩略图地址
    func fillGalleryList(_ input: [GalleryInfo], url: String, filter: Bool, env: EhAPIEnvironment) async throws -> [GalleryInfo] {
        var list = input
        let f = filter ? hooks.galleryFilter : nil
        if let f {
            list.removeAll { !f.filterTitle($0) || !f.filterUploader($0) }
        }

        var hasTags = false, hasPages = false, hasRated = false
        for gi in list {
            if gi.simpleTags != nil { hasTags = true }
            if gi.pages != 0 { hasPages = true }
            if gi.rated { hasRated = true }
        }
        let needApi = (filter && (f?.needTags ?? false) && !hasTags) || (env.showGalleryPages && !hasPages) || hasRated
        if needApi {
            list = try await fillGalleryListByApi(list, referer: url)
        }

        if let f {
            // Thumbnail 模式需要在补全后再过滤一次上传者
            list.removeAll { !f.filterUploader($0) || !f.filterTag($0) || !f.filterTagNamespace($0) }
        }
        for i in list.indices {
            if let t = list[i].thumb { list[i].thumb = EhURL.fixedPreviewThumbUrl(t) }
        }
        return list
    }

    /// gdata 补全（每批 25 条，任一批失败即抛错）。对应 `fillGalleryListByApi`。列表中的画廊至少要有合法的 gid 与 token
    public func fillGalleryListByApi(_ galleryInfoList: [GalleryInfo], referer: String) async throws -> [GalleryInfo] {
        var list = galleryInfoList
        var start = 0
        while start < list.count {
            let end = min(start + Self.maxGdataRequestSize, list.count)
            var batch = Array(list[start..<end])
            try await doFillGalleryListByApi(&batch, referer: referer)
            list.replaceSubrange(start..<end, with: batch)
            start = end
        }
        return list
    }

    /// 同上，但某一批失败只跳过该批（已补全的保留）。对应 `fillGalleryListByApiBestEffort`（恢复下载用）
    public func fillGalleryListByApiBestEffort(_ galleryInfoList: [GalleryInfo], referer: String) async -> [GalleryInfo] {
        var list = galleryInfoList
        var start = 0
        while start < list.count {
            let end = min(start + Self.maxGdataRequestSize, list.count)
            var batch = Array(list[start..<end])
            do {
                try await doFillGalleryListByApi(&batch, referer: referer)
                list.replaceSubrange(start..<end, with: batch)
            } catch {
                if error is CancellationError || (error as? EhError) == .cancelled { break }
            }
            start = end
        }
        return list
    }

    private func doFillGalleryListByApi(_ batch: inout [GalleryInfo], referer: String) async throws {
        let env = environment
        let json = AndroidJSON.obj(
            ("method", "gdata"),
            ("gidlist", .array(batch.map { .array([.int($0.gid), .string($0.token)]) })),
            ("namespace", 1)
        )
        let req = try apiRequest(json, referer: referer, env: env)
        let (resp, body) = try await send(req)
        do {
            try GalleryApiParser.parse(body, galleryInfoList: &batch, thumbResolution: env.thumbResolution)
        } catch {
            throw mapError(error, resp, body)
        }
    }

    // MARK: - 画廊详情

    /// 对应 `getGalleryDetail`。页面中有事件面板时回调 `hooks.onEventPane`
    public func getGalleryDetail(url: String) async throws -> GalleryDetail {
        let env = environment
        let req = try request(url, referer: env.site.referer)
        return try await perform(req) { _, body in
            if let html = EhEventParse.parse(body) { self.hooks.onEventPane?(html) }
            return try GalleryDetailParser.parse(body, thumbResolution: env.thumbResolution, fixThumbUrl: env.fixThumbUrl,
                                                 isBlacklisted: self.hooks.isBlacklisted)
        }
    }

    /// 预览页：预览集 + 预览总页数。对应 `getPreviewSet`（返回 `Pair<PreviewSet, Integer>`）
    public func getPreviewSet(url: String) async throws -> (previewSet: PreviewSet, previewPages: Int) {
        let env = environment
        let req = try request(url, referer: env.site.referer)
        return try await perform(req) { _, body in
            (GalleryDetailParser.parsePreviewSet(body, fixThumbUrl: env.fixThumbUrl),
             try GalleryDetailParser.parsePreviewPages(body))
        }
    }

    /// 评分（rating 0.5~5，提交 ceil(rating*2)）。对应 `rateGallery`
    public func rateGallery(apiUid: Int64, apiKey: String, gid: Int64, token: String, rating: Float) async throws -> RateGalleryParser.Result {
        let env = environment
        let json = AndroidJSON.obj(
            ("method", "rategallery"),
            ("apiuid", .int(apiUid)),
            ("apikey", .string(apiKey)),
            ("gid", .int(gid)),
            ("token", .string(token)),
            ("rating", .int(Int64(Double(rating * 2).rounded(.up))))
        )
        let req = try apiRequest(json, referer: EhURL.galleryDetail(env.site, gid: gid, token: token), env: env)
        return try await perform(req) { _, body in try RateGalleryParser.parse(body) }
    }

    /// 发表评论（editId 为 nil）或编辑评论。url 为画廊详情页地址。对应 `commentGallery`
    public func commentGallery(url: String, comment: String, editId: String? = nil) async throws -> GalleryCommentList {
        let env = environment
        var fields: [(String, String)] = []
        if let editId {
            fields.append(("commenttext_edit", comment))
            fields.append(("edit_comment", editId))
        } else {
            fields.append(("commenttext_new", comment))
        }
        let req = try formRequest(url, fields: fields, referer: url, origin: env.site.origin)
        return try await perform(req) { _, body in
            try CommentGalleryParser.parse(body, isBlacklisted: self.hooks.isBlacklisted)
        }
    }

    /// 获取待编辑评论的原文。对应 `getEditComment`
    public func getEditComment(apiUid: Int64, apiKey: String, gid: Int64, token: String,
                               commentId: Int64) async throws -> GetEditCommentParser.Result {
        let env = environment
        let json = AndroidJSON.obj(
            ("method", "geteditcomment"),
            ("apiuid", .int(apiUid)),
            ("apikey", .string(apiKey)),
            ("gid", .int(gid)),
            ("token", .string(token)),
            ("comment_id", .int(commentId))
        )
        let req = try apiRequest(json, referer: EhURL.galleryDetail(env.site, gid: gid, token: token), env: env)
        return try await perform(req) { _, body in try GetEditCommentParser.parse(body) }
    }

    /// 评论投票（1 赞 / -1 踩）。对应 `voteComment`
    public func voteComment(apiUid: Int64, apiKey: String, gid: Int64, token: String, commentId: Int64,
                            commentVote: Int) async throws -> VoteCommentParser.Result {
        let env = environment
        let json = AndroidJSON.obj(
            ("method", "votecomment"),
            ("apiuid", .int(apiUid)),
            ("apikey", .string(apiKey)),
            ("gid", .int(gid)),
            ("token", .string(token)),
            ("comment_id", .int(commentId)),
            ("comment_vote", .int(Int64(commentVote)))
        )
        let req = try apiRequest(json, referer: env.site.referer, env: env)
        return try await perform(req) { _, body in try VoteCommentParser.parse(body, vote: commentVote) }
    }

    /// 由图片页 token 换取画廊 token。page 从 0 开始。对应 `getGalleryToken`
    public func getGalleryToken(gid: Int64, gtoken: String, page: Int) async throws -> String {
        let env = environment
        let json = AndroidJSON.obj(
            ("method", "gtoken"),
            ("pagelist", .array([.array([.int(gid), .string(gtoken), .int(Int64(page + 1))])]))
        )
        let req = try apiRequest(json, referer: env.site.referer, env: env)
        return try await perform(req) { _, body in try GalleryTokenApiParser.parse(body) }
    }

    // MARK: - 收藏

    /// 收藏夹列表页（补全但不过滤）。对应 `getFavorites`（callApi 在 Java 中未使用）
    public func getFavorites(url: String, callApi: Bool = false) async throws -> FavoritesParser.Result {
        let env = environment
        let req = try request(url, referer: env.site.referer)
        let (resp, body) = try await send(req)
        var result: FavoritesParser.Result
        do {
            result = try FavoritesParser.parse(body, thumbResolution: env.thumbResolution, isLocalFavorite: hooks.isLocalFavorite)
        } catch {
            throw mapError(error, resp, body)
        }
        result.galleryInfoList = try await fillGalleryList(result.galleryInfoList, url: url, filter: false, env: env)
        return result
    }

    /// 收藏夹列表页（不补全）。对应 `getAllFavorites`（批量同步用）
    public func getAllFavorites(url: String) async throws -> FavoritesParser.Result {
        let env = environment
        let req = try request(url, referer: env.site.referer)
        return try await perform(req) { _, body in
            try FavoritesParser.parse(body, thumbResolution: env.thumbResolution, isLocalFavorite: self.hooks.isLocalFavorite)
        }
    }

    /// 添加 / 移动 / 删除单个云收藏。dstCat：-1 删除，0~9 收藏夹；note 最多 250 字。对应 `addFavorites`
    public func addFavorites(gid: Int64, token: String, dstCat: Int, note: String? = nil) async throws {
        let catStr: String
        if dstCat == -1 {
            catStr = "favdel"
        } else if (0...9).contains(dstCat) {
            catStr = String(dstCat)
        } else {
            throw EhError.other("Invalid dstCat: \(dstCat)")
        }
        let env = environment
        let url = EhURL.addFavorites(env.site, gid: gid, token: token)
        // submit=Add+to+Favorites 不是必需的，始终用 submit=Apply+Changes
        let req = try formRequest(url, fields: [
            ("favcat", catStr),
            ("favnote", note ?? ""),
            ("submit", "Apply Changes"),
            ("update", "1"),
        ], referer: url, origin: env.site.origin)
        let (resp, body) = try await send(req)
        try EhEngineErrors.check(resp, body: body)
    }

    /// 逐个调用 addFavorites（note 为空）。对应 `addFavoritesRange`
    public func addFavoritesRange(gids: [Int64], tokens: [String], dstCat: Int) async throws {
        precondition(gids.count == tokens.count, "gids 与 tokens 数量不一致")
        for (gid, token) in zip(gids, tokens) {
            try await addFavorites(gid: gid, token: token, dstCat: dstCat, note: nil)
        }
    }

    /// 收藏夹页批量移动 / 删除，返回刷新后的收藏夹页。url 为当前收藏夹页地址。对应 `modifyFavorites`
    public func modifyFavorites(url: String, gids: [Int64], dstCat: Int, callApi: Bool = false) async throws -> FavoritesParser.Result {
        let catStr: String
        if dstCat == -1 {
            catStr = "delete"
        } else if (0...9).contains(dstCat) {
            catStr = "fav\(dstCat)"
        } else {
            throw EhError.other("Invalid dstCat: \(dstCat)")
        }
        let env = environment
        var fields: [(String, String)] = [("ddact", catStr)]
        for gid in gids { fields.append(("modifygids[]", String(gid))) }
        fields.append(("apply", "Apply"))
        let req = try formRequest(url, fields: fields, referer: url, origin: env.site.origin)
        let (resp, body) = try await send(req)
        var result: FavoritesParser.Result
        do {
            result = try FavoritesParser.parse(body, thumbResolution: env.thumbResolution, isLocalFavorite: hooks.isLocalFavorite)
        } catch {
            throw mapError(error, resp, body)
        }
        result.galleryInfoList = try await fillGalleryList(result.galleryInfoList, url: url, filter: false, env: env)
        return result
    }

    // MARK: - 种子 / 排行榜 / 归档

    /// 种子列表。url 通常为 `EhURL.torrentList`。对应 `getTorrentList`
    public func getTorrentList(url: String, gid: Int64, token: String) async throws -> [TorrentInfo] {
        let req = try request(url, referer: EhURL.galleryDetail(environment.site, gid: gid, token: token))
        return try await perform(req) { _, body in TorrentParser.parse(body) }
    }

    /// 排行榜（Referer 固定为表站 toplist.php）。对应 `getTopList`
    public func getTopList(url: String) async throws -> EhTopListDetail {
        let req = try request(url, referer: EhURL.topList)
        return try await perform(req) { _, body in try TopListParser.parse(body) }
    }

    /// H@H 下载选项与表单参数 or。url 通常为 `EhURL.archiver(site, gid:, token:, or: "")`。对应 `getArchiveList`
    public func getArchiveList(url: String, gid: Int64, token: String) async throws -> ArchiveParser.Result {
        let req = try request(url, referer: EhURL.galleryDetail(environment.site, gid: gid, token: token))
        return try await perform(req) { _, body in ArchiveParser.parse(body) }
    }

    /// 归档下载对话框（原图 / 重采样的花费与表单地址）。对应 `getArchiver`
    public func getArchiver(url: String, gid: Int64, token: String) async throws -> ArchiverData {
        let env = environment
        let req = try request(url, referer: EhURL.galleryDetail(env.site, gid: gid, token: token))
        return try await perform(req) { _, body in ArchiveParser.parseArchiver(body, site: env.site) }
    }

    /// 发送到 H@H 客户端下载。没有 H@H 客户端时抛 `EhError.noHAtH`。对应 `downloadArchive`
    public func downloadArchive(gid: Int64, token: String, or: String?, res: String?) async throws {
        guard let or else { throw EhError.other("Invalid form param or: null") }
        guard let res, !res.isEmpty else { throw EhError.other("Invalid res: \(res ?? "null")") }
        let env = environment
        let url = EhURL.archiver(env.site, gid: gid, token: token, or: or)
        let req = try formRequest(url, fields: [("hathdl_xres", res)],
                                  referer: EhURL.galleryDetail(env.site, gid: gid, token: token), origin: env.site.origin)
        let (resp, body) = try await send(req)
        try EhEngineErrors.check(resp, body: body)
        try ArchiveParser.checkDownloadArchive(body)
    }

    /// 归档下载：POST 表单（dltype=org/res, dlcheck）→ 跟随页面脚本跳转 → 解析下载地址。
    /// 没找到跳转或下载地址时返回 nil。对应 `downloadArchiver`
    public func downloadArchiver(url: String?, referer: String?, dltype: String, dlcheck: String) async throws -> String? {
        guard let url, !url.isEmpty else { throw EhError.other("Invalid form param url: \(url ?? "null")") }
        guard let referer, !referer.isEmpty else { throw EhError.other("Invalid form param referer: \(referer ?? "null")") }
        let origin = environment.site.origin
        let req = try formRequest(url, fields: [("dltype", dltype), ("dlcheck", dlcheck)], referer: referer, origin: origin)
        let (resp, body) = try await send(req)
        guard let continueUrl = ArchiveParser.parseArchiverContinueUrl(body) else { return nil }
        // Java：EhRequestBuilder(continueUrl, origin, null)，即 Referer 为 Origin
        let req2: EhHTTPRequest
        do { req2 = try request(continueUrl, referer: origin) } catch { throw mapError(error, resp, body) }
        let (resp2, body2) = try await send(req2)
        guard let host = resp2.url.host else { return nil }
        return ArchiveParser.archiverDownloadUrl(host: host, body: body2)
    }

    // MARK: - 图片页

    /// 图片页 HTML（/s/pToken/gid-page）。对应 `getGalleryPage`
    public func getGalleryPage(url: String, gid: Int64, token: String) async throws -> GalleryPageParser.Result {
        let req = try request(url, referer: EhURL.galleryDetail(environment.site, gid: gid, token: token))
        return try await perform(req) { _, body in try GalleryPageParser.parse(body) }
    }

    /// showpage API（index 从 0 开始）。index > 0 且有上一页 pToken 时 Referer 为上一页地址。对应 `getGalleryPageApi`
    public func getGalleryPageApi(gid: Int64, index: Int, pToken: String, showKey: String,
                                  previousPToken: String?) async throws -> GalleryPageApiParser.Result {
        let env = environment
        let json = AndroidJSON.obj(
            ("method", "showpage"),
            ("gid", .int(gid)),
            ("page", .int(Int64(index + 1))),
            ("imgkey", .string(pToken)),
            ("showkey", .string(showKey))
        )
        var referer: String?
        if index > 0, let previousPToken {
            referer = EhURL.page(env.site, gid: gid, index: index - 1, pToken: previousPToken)
        }
        let req = try apiRequest(json, referer: referer, env: env)
        return try await perform(req) { _, body in try GalleryPageApiParser.parse(body) }
    }

    // MARK: - My Tags

    /// My Tags 列表。未登录返回 nil。url 通常为 `EhURL.myTags(site)`。对应 `getWatchedList`
    public func getWatchedList(url: String) async throws -> UserTagList? {
        guard environment.isLogin else { return nil }
        let req = try request(url, referer: nil)
        return try await perform(req) { _, body in try MyTagLitParser.parse(body) }
    }

    /// 添加用户标签。未登录返回 nil。对应 `addTag`
    public func addTag(url: String, param: TagPushParam) async throws -> UserTagList? {
        guard environment.isLogin else { return nil }
        let req = try request(url, method: .post, referer: nil, contentType: Self.mediaTypeURLEncodedString,
                              body: Data(param.addTagParam().utf8))
        return try await perform(req) { _, body in try MyTagLitParser.parse(body) }
    }

    /// 删除用户标签（METHOD_EDIT_WATCHED 在 Java 中也走这里）。未登录返回 nil。对应 `deleteWatchedTag`
    public func deleteWatchedTag(url: String, tag: UserTag) async throws -> UserTagList? {
        guard environment.isLogin else { return nil }
        let req = try request(url, method: .post, referer: nil, contentType: Self.mediaTypeURLEncodedString,
                              body: Data(tag.deleteParam().utf8))
        return try await perform(req) { _, body in try MyTagLitParser.parse(body) }
    }

    // MARK: - 新闻 / 首页（配额）

    /// news.php（不校验状态码，直接解析）。对应 `getEhNews`
    public func getEhNews() async throws -> EhNewsDetail {
        let req = try request(EhURL.news, referer: nil)
        let (_, body) = try await send(req)
        return EhNewsParser.parse(body)
    }

    /// home.php（固定表站）：图片配额等。对应 `getHomeDetail`
    public func getHomeDetail() async throws -> HomeDetail {
        let req = try request(EhURL.homeE, referer: environment.site.referer)
        return try await perform(req) { _, body in
            if let html = EhEventParse.parse(body) { self.hooks.onEventPane?(html) }
            return EhHomeParser.parse(body)
        }
    }

    /// 重置图片配额。对应 `resetLimit`（无 Origin）
    public func resetLimit() async throws -> HomeDetail {
        let req = try formRequest(EhURL.homeE, fields: [("reset_imagelimit", "Reset Limit")],
                                  referer: environment.site.referer, origin: nil)
        return try await perform(req) { _, body in
            if let html = EhEventParse.parse(body) { self.hooks.onEventPane?(html) }
            return EhHomeParser.parse(body)
        }
    }

    // MARK: - 内部：请求构造与执行

    func request(_ url: String, method: HTTPMethod = .get, referer: String?, origin: String? = nil,
                 contentType: String? = nil, body: Data? = nil) throws -> EhHTTPRequest {
        var h = HTTPHeaders()
        if let contentType { h.set("Content-Type", contentType) }
        return client.makeRequest(try EhHTTPClient.url(url), method: method, referer: referer, origin: origin,
                                  headers: h, body: body)
    }

    func formRequest(_ url: String, fields: [(String, String)], referer: String?, origin: String?) throws -> EhHTTPRequest {
        try request(url, method: .post, referer: referer, origin: origin, contentType: Self.mediaTypeForm,
                    body: Data(FormEncoding.encode(fields).utf8))
    }

    func apiRequest(_ json: AndroidJSON, referer: String?, env: EhAPIEnvironment) throws -> EhHTTPRequest {
        try request(EhURL.api(env.site), method: .post, referer: referer, origin: env.site.origin,
                    contentType: Self.mediaTypeJSON, body: json.data)
    }

    /// 执行请求（不做状态码校验，与 Java 一致由解析结果决定成败）
    func send(_ req: EhHTTPRequest) async throws -> (EhHTTPResponse, String) {
        let resp: EhHTTPResponse
        do {
            resp = try await client.execute(req, validate: false)
        } catch {
            throw EhEngineErrors.map(error, response: nil, body: nil)
        }
        return (resp, resp.text)
    }

    /// 执行并解析；解析失败经 `doThrowException` 规则转换
    func perform<T>(_ req: EhHTTPRequest, _ parse: (EhHTTPResponse, String) throws -> T) async throws -> T {
        let (resp, body) = try await send(req)
        do {
            return try parse(resp, body)
        } catch {
            throw mapError(error, resp, body)
        }
    }

    func mapError(_ error: Error, _ resp: EhHTTPResponse?, _ body: String?) -> Error {
        EhEngineErrors.map(error, response: resp, body: body, onParseError: hooks.onParseError)
    }
}

/// 与 OkHttp `MultipartBody`（type = FORM）字节一致的 multipart 编码：
/// 每个 part 只写自定义的 Content-Disposition 头（Java 中 `MediaType.parse("file")` / `"submit"` 均为 null，
/// 因此没有 Content-Type），随后写 Content-Length
enum OkHttpMultipart {
    struct Part {
        var disposition: String
        var data: Data
    }

    static func contentType(boundary: String) -> String { "multipart/form-data; boundary=\(boundary)" }

    static func encode(_ parts: [Part], boundary: String) -> Data {
        var body = Data()
        func put(_ s: String) { body.append(Data(s.utf8)) }
        for p in parts {
            put("--\(boundary)\r\n")
            put("Content-Disposition: \(p.disposition)\r\n")
            put("Content-Length: \(p.data.count)\r\n")
            put("\r\n")
            body.append(p.data)
            put("\r\n")
        }
        put("--\(boundary)--\r\n")
        return body
    }
}
