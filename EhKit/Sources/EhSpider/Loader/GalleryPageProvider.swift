import EhNetwork
import Foundation

/// 预览页（详情页 ?p=N）结果：用于批量获取 pToken。对应 SpiderQueen `readPreviews` 用到的三项解析结果
public struct PreviewPageResult: Sendable, Hashable {
    /// 画廊总页数（`GalleryDetailParser.parsePages`）
    public var pages: Int
    /// 预览分页数（`parsePreviewPages`）
    public var previewPages: Int
    /// 本预览页的缩略图集合（含每页的 /s/ 链接）
    public var previewSet: PreviewSet

    public init(pages: Int, previewPages: Int, previewSet: PreviewSet) {
        self.pages = pages
        self.previewPages = previewPages
        self.previewSet = previewSet
    }

    /// 页序号（0 起）→ pToken
    public var pTokens: [Int: String] {
        var map: [Int: String] = [:]
        for item in previewSet.items {
            if let r = GalleryPageUrlParser.parse(item.pageUrl) { map[r.page] = r.pToken }
        }
        return map
    }
}

/// 图片下载结果
public struct ImageDownloadResult: Sendable, Hashable {
    /// 最终响应 URL（用于反劫持校验：与请求地址不一致视为被劫持）
    public var finalURL: String
    public var statusCode: Int
    public var mimeType: String?
    /// Content-Length；未知为 nil
    public var contentLength: Int64?
    /// 实际写入字节数
    public var receivedBytes: Int64

    public init(finalURL: String, statusCode: Int, mimeType: String?, contentLength: Int64?, receivedBytes: Int64) {
        self.finalURL = finalURL
        self.statusCode = statusCode
        self.mimeType = mimeType
        self.contentLength = contentLength
        self.receivedBytes = receivedBytes
    }
}

/// `GalleryLoader` 所需的全部网络操作（对应 SpiderQueen 中对 `EhEngine` / OkHttp 的调用）。
/// 通过协议注入，便于测试与替换；默认实现见 `DefaultGalleryPageProvider`。
public protocol GalleryPageProvider: Sendable {
    /// 获取预览页（详情页第 previewIndex 页）：总页数、预览页数、pToken。
    /// 对应 `readSpiderInfoFromInternet` / `getPTokenFromInternet`（`EhUrl.getGalleryDetailUrl(gid, token, previewIndex)`）
    func fetchPreviewPage(gid: Int64, token: String, previewIndex: Int) async throws -> PreviewPageResult

    /// 获取图片页 HTML 并解析（imageUrl / nl key / 原图地址 / showKey）。对应 `EhEngine.getGalleryPage`
    /// - Parameter pageURL: 完整页面地址（可能已带 `nl=` 参数）
    func fetchPage(pageURL: String, gid: Int64, token: String) async throws -> GalleryPageParser.Result

    /// showpage API。对应 `EhEngine.getGalleryPageApi`。showKey 失效时应抛 `EhError.parse("Key mismatch", ...)`
    func fetchPageAPI(gid: Int64, index: Int, pToken: String, showKey: String,
                      previousPToken: String?) async throws -> GalleryPageApiParser.Result

    /// 原图：请求 fullimg 地址（不跟随重定向），返回 Location 头；没有 Location（GP 不足）返回 nil
    func resolveOriginImageURL(_ url: String, referer: String) async throws -> String?

    /// 下载图片到文件（覆盖写入），带进度。≥400 时不抛错，由调用方根据 statusCode 判断
    /// - Parameter timeout: 下载超时（秒）；nil 用默认图片超时
    func downloadImage(_ url: String, referer: String, to fileURL: URL, timeout: TimeInterval?,
                       progress: EhDownloadProgress?) async throws -> ImageDownloadResult
}

/// 基于 `EhHTTPClient` + EhCore 解析器的默认实现。请求地址 / 参数 / header 对照 `EhEngine`
public struct DefaultGalleryPageProvider: GalleryPageProvider {
    public let client: EhHTTPClient
    public let site: EhSite
    /// 对应 `Settings.getFixThumbUrl()`（只影响大图预览地址，不影响 pToken）
    public var fixThumbUrl: Bool
    /// 原图请求超时（Android 固定 30s）
    public var originImageTimeout: TimeInterval = 30

    public init(client: EhHTTPClient, site: EhSite, fixThumbUrl: Bool = false) {
        self.client = client
        self.site = site
        self.fixThumbUrl = fixThumbUrl
    }

    /// 对应 `EhEngine.getPreviewSet` + SpiderQueen 的 detail 请求：Referer = `EhUrl.getReferer()`
    public func fetchPreviewPage(gid: Int64, token: String, previewIndex: Int) async throws -> PreviewPageResult {
        let url = EhURL.galleryDetail(site, gid: gid, token: token, page: previewIndex)
        let body = try await client.getText(url, referer: site.referer)
        return try Self.parsePreviewPage(body, fixThumbUrl: fixThumbUrl)
    }

    static func parsePreviewPage(_ body: String, fixThumbUrl: Bool = false) throws -> PreviewPageResult {
        let pages = try GalleryDetailParser.parsePages(body)
        let previewPages = try GalleryDetailParser.parsePreviewPages(body)
        let set = GalleryDetailParser.parsePreviewSet(body, fixThumbUrl: fixThumbUrl)
        return PreviewPageResult(pages: pages, previewPages: previewPages, previewSet: set)
    }

    /// 对应 `EhEngine.getGalleryPage`：Referer = 详情页
    public func fetchPage(pageURL: String, gid: Int64, token: String) async throws -> GalleryPageParser.Result {
        let referer = EhURL.galleryDetail(site, gid: gid, token: token)
        let body = try await client.getText(pageURL, referer: referer)
        return try GalleryPageParser.parse(body)
    }

    /// 对应 `EhEngine.getGalleryPageApi`：POST api.php，JSON {method, gid, page, imgkey, showkey}；
    /// Referer 为上一页（index > 0 且有 previousPToken 时），Origin 为站点
    public func fetchPageAPI(gid: Int64, index: Int, pToken: String, showKey: String,
                             previousPToken: String?) async throws -> GalleryPageApiParser.Result {
        let json: [String: Any] = [
            "method": "showpage", "gid": gid, "page": index + 1, "imgkey": pToken, "showkey": showKey,
        ]
        var referer: String?
        if index > 0, let previousPToken {
            referer = EhURL.page(site, gid: gid, index: index - 1, pToken: previousPToken)
        }
        let resp = try await client.postJSON(EhURL.api(site), jsonObject: json, referer: referer, origin: site.origin)
        return try GalleryPageApiParser.parse(resp.text)
    }

    /// 对应 SpiderQueen 原图分支：图片 client（不跟随重定向）+ 30s 超时，取 `Location`
    public func resolveOriginImageURL(_ url: String, referer: String) async throws -> String? {
        guard let u = URL(string: url) else { throw EhError.other("无效 URL：\(url)") }
        var req = client.makeRequest(u, referer: referer)
        req.followRedirects = false
        req.timeout = originImageTimeout
        let resp = try await client.execute(req, validate: false)
        guard let loc = resp.headers["Location"], !loc.isEmpty else { return nil }
        return URL(string: loc, relativeTo: u)?.absoluteString ?? loc
    }

    /// 对应 SpiderQueen 图片下载：普通 client（跟随重定向），callTimeout = downloadTimeout
    public func downloadImage(_ url: String, referer: String, to fileURL: URL, timeout: TimeInterval?,
                              progress: EhDownloadProgress?) async throws -> ImageDownloadResult {
        guard let u = URL(string: url) else { throw EhError.other("无效 URL：\(url)") }
        var req = client.makeRequest(u, referer: referer)
        req.followRedirects = true
        if let timeout, timeout > 0 { req.timeout = timeout }
        let counter = LockedBox<Int64>(0)
        let resp = try await client.download(req, to: fileURL, progress: { received, total in
            counter.withLock { $0 = received }
            progress?(received, total)
        }, validate: false)
        var received = counter.get
        if received == 0 { received = ImageFiles.fileSize(fileURL) }
        let mime = resp.contentType?.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) }
        return ImageDownloadResult(finalURL: resp.url.absoluteString, statusCode: resp.status, mimeType: mime,
                                   contentLength: resp.contentLength, receivedBytes: received)
    }
}
