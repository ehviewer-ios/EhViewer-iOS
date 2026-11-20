import Foundation
import Testing
@testable import EhSpider

/// 记录请求的传输桩
final class RecordingTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [EhHTTPRequest] = []
    let handler: @Sendable (EhHTTPRequest) -> EhHTTPResponse
    var requests: [EhHTTPRequest] { lock.withLock { _requests } }

    init(_ handler: @escaping @Sendable (EhHTTPRequest) -> EhHTTPResponse) { self.handler = handler }

    func send(_ request: EhHTTPRequest) async throws -> EhHTTPResponse {
        lock.withLock { _requests.append(request) }
        return handler(request)
    }

    func download(_ request: EhHTTPRequest, to fileURL: URL, progress: EhDownloadProgress?) async throws -> EhHTTPResponse {
        var r = try await send(request)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try r.body.write(to: fileURL)
        progress?(Int64(r.body.count), Int64(r.body.count))
        r.body = Data()
        return r
    }
}

func html(_ body: String, _ url: URL, status: Int = 200, headers: [(String, String)] = []) -> EhHTTPResponse {
    var h = HTTPHeaders([("Content-Type", "text/html; charset=UTF-8")])
    for (k, v) in headers { h.set(k, v) }
    return EhHTTPResponse(status: status, headers: h, body: Data(body.utf8), url: url)
}

@Suite struct DefaultProviderTests {
    static let detailHTML = """
    <table><tr><td class="gdt1">Length:</td><td class="gdt2">3 pages</td></tr></table>
    <table class="ptt"><tr><td class="ptds"><a href="x">1</a></td><td class="ptdd">&gt;</td></tr></table>
    <div id="gdt" class="gt200">
    <a href="https://e-hentai.org/s/0123456789/42-1"><div title="Page 1: a.jpg" style="width:200px;height:283px;background:transparent url(https://ehgt.org/a.webp) 0 0 no-repeat"></div></a>
    <a href="https://e-hentai.org/s/abcdefabcd/42-2"><div title="Page 2: b.jpg" style="width:200px;height:283px;background:transparent url(https://ehgt.org/b.webp) 0 0 no-repeat"></div></a>
    </div>
    """

    @Test func previewPageRequestAndParse() async throws {
        let transport = RecordingTransport { r in html(Self.detailHTML, r.url) }
        let provider = DefaultGalleryPageProvider(client: EhHTTPClient(transport: transport), site: .e)
        let result = try await provider.fetchPreviewPage(gid: 42, token: "tok", previewIndex: 2)
        let req = try #require(transport.requests.first)
        #expect(req.url.absoluteString == "https://e-hentai.org/g/42/tok/?p=2")
        #expect(req.headers["Referer"] == "https://e-hentai.org")
        #expect(result.pages == 3)
        #expect(result.previewPages == 1)
        #expect(result.pTokens == [0: "0123456789", 1: "abcdefabcd"])
    }

    @Test func pageHTMLAndAPI() async throws {
        let pageHTML = ##"<img id="img" src="https://h.example/h/abc/keystamp/1.jpg" style="x"><a href="#" onclick="return nl('12345-678')">reload</a><script>var showkey="abc123def";</script>"##
        let apiJSON = ##"{"i3":"<a onclick=\"return load_image(2, 'xx')\" href=\"#\"><img id=\"img\" src=\"https://h.example/2.jpg\" style=\"height:1px\" /></a>","i6":" &nbsp; <a href=\"#\" id=\"loadfail\" onclick=\"return nl('999-1')\">Reload broken image</a>","i7":null}"##
        let transport = RecordingTransport { r in
            if r.url.path.hasSuffix("api.php") {
                return EhHTTPResponse(status: 200, headers: ["Content-Type": "application/json"], body: Data(apiJSON.utf8), url: r.url)
            }
            return html(pageHTML, r.url)
        }
        let provider = DefaultGalleryPageProvider(client: EhHTTPClient(transport: transport), site: .ex)
        let page = try await provider.fetchPage(pageURL: "https://exhentai.org/s/0123456789/42-1", gid: 42, token: "tok")
        #expect(page.imageUrl == "https://h.example/h/abc/keystamp/1.jpg")
        #expect(page.skipHathKey == "12345-678")
        #expect(page.showKey == "abc123def")
        #expect(transport.requests[0].headers["Referer"] == "https://exhentai.org/g/42/tok/")

        let api = try await provider.fetchPageAPI(gid: 42, index: 1, pToken: "abcdefabcd", showKey: "abc123def",
                                                  previousPToken: "0123456789")
        #expect(api.imageUrl == "https://h.example/2.jpg")
        #expect(api.skipHathKey == "999-1")
        let req = transport.requests[1]
        #expect(req.method == .post)
        #expect(req.url.absoluteString == "https://exhentai.org/api.php")
        #expect(req.headers["Referer"] == "https://exhentai.org/s/0123456789/42-1")
        #expect(req.headers["Origin"] == "https://exhentai.org")
        let body = try #require(req.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(body["method"] as? String == "showpage")
        #expect(body["page"] as? Int == 2)
        #expect(body["imgkey"] as? String == "abcdefabcd")
        #expect(body["showkey"] as? String == "abc123def")
        #expect((body["gid"] as? NSNumber)?.int64Value == 42)
    }

    @Test func originImageAndDownload() async throws {
        let transport = RecordingTransport { r in
            if r.url.path.contains("fullimg") {
                return html("", r.url, status: 302, headers: [("Location", "https://o.example/orig.png")])
            }
            if r.url.host == "img.example" {
                return EhHTTPResponse(status: 302, headers: ["Location": "https://img2.example/final.jpg"], url: r.url)
            }
            return EhHTTPResponse(status: 200, headers: ["Content-Type": "image/png", "Content-Length": "4"],
                                  body: Data([0x89, 0x50, 0x4E, 0x47]), url: r.url)
        }
        let provider = DefaultGalleryPageProvider(client: EhHTTPClient(transport: transport), site: .e)
        let loc = try await provider.resolveOriginImageURL("https://e-hentai.org/fullimg/42/1/x/a.png?nl=k",
                                                           referer: "https://e-hentai.org/s/0123456789/42-1")
        #expect(loc == "https://o.example/orig.png")
        // 原图请求不跟随重定向
        #expect(transport.requests.count == 1)

        let dirs = TestDirs()
        defer { dirs.cleanup() }
        let file = dirs.root.appendingPathComponent("img")
        let r = try await provider.downloadImage("https://o.example/orig.png", referer: "https://e-hentai.org/s/x/42-1",
                                                 to: file, timeout: nil, progress: nil)
        #expect(r.statusCode == 200 && r.mimeType == "image/png" && r.contentLength == 4 && r.receivedBytes == 4)
        #expect(r.finalURL == "https://o.example/orig.png")
        // 图片下载跟随重定向，最终地址不同 → 加载器视为被劫持
        let r2 = try await provider.downloadImage("https://img.example/1.jpg", referer: "https://e-hentai.org/s/x/42-1",
                                                  to: file, timeout: 5, progress: nil)
        #expect(r2.finalURL == "https://img2.example/final.jpg")
        #expect(transport.requests.last?.headers["Referer"] == "https://e-hentai.org/s/x/42-1")
    }

    @Test func archiverFlow() async throws {
        let transport = RecordingTransport { r in
            switch r.url.host {
            case "e-hentai.org" where r.method == .post:
                return html(#"<script>document.location = "https://e-hentai.org/archive/42/tok/abc/2";</script>"#, r.url)
            case "e-hentai.org":
                return html(#"<p><a href="/archive/42/tok/abc/2?start=1">Click Here To Start Downloading</a></p>"#, r.url)
            default:
                return html("", r.url)
            }
        }
        let provider = DefaultArchiveProvider(client: EhHTTPClient(transport: transport), site: .e)
        let form = DefaultArchiveProvider.archiverForm(original: true)
        let url = try await provider.resolveArchiverDownloadURL(
            url: "https://e-hentai.org/archiver.php?gid=42&token=tok&or=xyz",
            referer: "https://e-hentai.org/archiver.php?gid=42&token=tok&or=xyz", dltype: form.dltype, dlcheck: form.dlcheck)
        #expect(url == "https://e-hentai.org/archive/42/tok/abc/2?start=1")
        let post = transport.requests[0]
        #expect(String(data: post.body ?? Data(), encoding: .utf8) == "dltype=org&dlcheck=Download%20Original%20Archive")
        #expect(post.headers["Origin"] == "https://e-hentai.org")
        #expect(transport.requests[1].headers["Referer"] == "https://e-hentai.org")
    }

    @Test func archiveRangeHeader() async throws {
        let transport = RecordingTransport { r in
            EhHTTPResponse(status: 206, headers: ["Content-Range": "bytes 10-19/20", "Content-Length": "10"],
                           body: Data(repeating: 7, count: 10), url: r.url)
        }
        let provider = DefaultArchiveProvider(client: EhHTTPClient(transport: transport), site: .e)
        let dirs = TestDirs()
        defer { dirs.cleanup() }
        let r = try await provider.downloadArchive(url: "https://a.example/z.zip", to: dirs.root.appendingPathComponent("c"),
                                                   offset: 10, progress: nil)
        #expect(transport.requests.first?.headers["Range"] == "bytes=10-")
        #expect(r.statusCode == 206 && r.contentRange == "bytes 10-19/20" && r.receivedBytes == 10)
    }
}
