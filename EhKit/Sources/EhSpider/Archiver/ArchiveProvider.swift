import EhNetwork
import Foundation

/// 归档 zip 下载响应
public struct ArchiveDownloadResponse: Sendable, Hashable {
    public var statusCode: Int
    /// Content-Range 头（断点续传时）
    public var contentRange: String?
    /// 本次响应体长度；未知为 nil
    public var contentLength: Int64?
    /// 本次写入文件的字节数
    public var receivedBytes: Int64

    public init(statusCode: Int, contentRange: String? = nil, contentLength: Int64? = nil, receivedBytes: Int64) {
        self.statusCode = statusCode
        self.contentRange = contentRange
        self.contentLength = contentLength
        self.receivedBytes = receivedBytes
    }
}

/// 归档相关网络操作（对应 `EhEngine.getArchiveList / getArchiver / downloadArchive / downloadArchiver` + zip 下载）。
/// 默认实现见 `DefaultArchiveProvider`。
public protocol ArchiveProvider: Sendable {
    /// H@H 下载选项与表单参数 or（`EhEngine.getArchiveList`）
    func fetchArchiveList(url: String, gid: Int64, token: String) async throws -> ArchiveParser.Result
    /// 归档下载对话框：花费、大小、表单地址（`EhEngine.getArchiver`）
    func fetchArchiver(url: String, gid: Int64, token: String) async throws -> ArchiverData
    /// 请求 H@H 客户端下载（`EhEngine.downloadArchive`）；没有 H@H 时抛 `EhError.noHAtH`
    func requestHAtHDownload(gid: Int64, token: String, or: String, res: String) async throws
    /// 提交归档表单并取得 zip 下载地址（`EhEngine.downloadArchiver`）；nil 表示没有下载地址
    /// - Parameters:
    ///   - url: 表单地址（`ArchiverData.originalUrl / resampleUrl`）
    ///   - referer: 归档页地址（`GalleryDetail.archiveUrl`）
    ///   - dltype: "org" / "res"
    ///   - dlcheck: "Download Original Archive" / "Download Resample Archive"
    func resolveArchiverDownloadURL(url: String, referer: String, dltype: String, dlcheck: String) async throws -> String?
    /// 下载 zip 到 fileURL（覆盖写入）。offset > 0 时发送 `Range: bytes=offset-`，fileURL 只包含本次响应体
    func downloadArchive(url: String, to fileURL: URL, offset: Int64,
                         progress: EhDownloadProgress?) async throws -> ArchiveDownloadResponse
}

public extension ArchiveProvider {
    /// 原图 / 重采样归档的表单参数
    static func archiverForm(original: Bool) -> (dltype: String, dlcheck: String) {
        original ? ("org", "Download Original Archive") : ("res", "Download Resample Archive")
    }
}

/// 基于 `EhHTTPClient` + `ArchiveParser` 的默认实现
public struct DefaultArchiveProvider: ArchiveProvider {
    public let client: EhHTTPClient
    public let site: EhSite

    public init(client: EhHTTPClient, site: EhSite) {
        self.client = client
        self.site = site
    }

    /// Referer = 详情页
    public func fetchArchiveList(url: String, gid: Int64, token: String) async throws -> ArchiveParser.Result {
        let body = try await client.getText(url, referer: EhURL.galleryDetail(site, gid: gid, token: token))
        return ArchiveParser.parse(body)
    }

    public func fetchArchiver(url: String, gid: Int64, token: String) async throws -> ArchiverData {
        let body = try await client.getText(url, referer: EhURL.galleryDetail(site, gid: gid, token: token))
        return ArchiveParser.parseArchiver(body, site: site)
    }

    /// POST hathdl_xres=res 到 `archiver.php?gid&token&or`，Referer 详情页、Origin 站点
    public func requestHAtHDownload(gid: Int64, token: String, or: String, res: String) async throws {
        guard !res.isEmpty else { throw EhError.other("Invalid res: \(res)") }
        let resp = try await client.postForm(EhURL.archiver(site, gid: gid, token: token, or: or),
                                             fields: [("hathdl_xres", res)],
                                             referer: EhURL.galleryDetail(site, gid: gid, token: token),
                                             origin: site.origin)
        try ArchiveParser.checkDownloadArchive(resp.text)
    }

    /// POST dltype/dlcheck → 解析 `document.location` → GET 跳转页（Referer=Origin）→ "https://{host}{path}"
    public func resolveArchiverDownloadURL(url: String, referer: String, dltype: String,
                                           dlcheck: String) async throws -> String? {
        guard !url.isEmpty else { throw EhError.other("Invalid form param url: \(url)") }
        guard !referer.isEmpty else { throw EhError.other("Invalid form param referer: \(referer)") }
        let resp = try await client.postForm(url, fields: [("dltype", dltype), ("dlcheck", dlcheck)],
                                             referer: referer, origin: site.origin)
        guard let continueURL = ArchiveParser.parseArchiverContinueUrl(resp.text) else { return nil }
        let next = try await client.get(continueURL, referer: site.origin)
        guard let host = next.url.host else { return nil }
        return ArchiveParser.archiverDownloadUrl(host: host, body: next.text)
    }

    public func downloadArchive(url: String, to fileURL: URL, offset: Int64,
                                progress: EhDownloadProgress?) async throws -> ArchiveDownloadResponse {
        guard let u = URL(string: url) else { throw EhError.other("无效 URL：\(url)") }
        var headers = HTTPHeaders()
        if offset > 0 { headers.set("Range", "bytes=\(offset)-") }
        var req = client.makeRequest(u, headers: headers)
        // 归档文件较大，不使用图片超时
        req.timeout = max(client.config.timeout, 60)
        let counter = LockedBox<Int64>(0)
        let resp = try await client.download(req, to: fileURL, progress: { received, total in
            counter.withLock { $0 = received }
            progress?(received, total)
        }, validate: false)
        var received = counter.get
        if received == 0 { received = ImageFiles.fileSize(fileURL) }
        return ArchiveDownloadResponse(statusCode: resp.status, contentRange: resp.headers["Content-Range"],
                                       contentLength: resp.contentLength, receivedBytes: received)
    }
}
