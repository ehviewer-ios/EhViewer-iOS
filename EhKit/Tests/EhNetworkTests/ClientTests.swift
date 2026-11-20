import Foundation
import Testing
@testable import EhNetwork

/// 脚本化的传输桩：按 URL 返回预设响应，记录请求
final class MockTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [EhHTTPRequest] = []
    let handler: @Sendable (EhHTTPRequest) throws -> EhHTTPResponse
    var requests: [EhHTTPRequest] { lock.withLock { _requests } }

    init(_ handler: @escaping @Sendable (EhHTTPRequest) throws -> EhHTTPResponse) { self.handler = handler }

    func send(_ request: EhHTTPRequest) async throws -> EhHTTPResponse {
        lock.withLock { _requests.append(request) }
        return try handler(request)
    }

    func download(_ request: EhHTTPRequest, to fileURL: URL, progress: EhDownloadProgress?) async throws -> EhHTTPResponse {
        var r = try await send(request)
        try r.body.write(to: fileURL)
        progress?(Int64(r.body.count), Int64(r.body.count))
        r.body = Data()
        return r
    }
}

func resp(_ status: Int, _ url: URL, headers: HTTPHeaders = ["Content-Type": "text/html; charset=UTF-8"], body: String = "") -> EhHTTPResponse {
    EhHTTPResponse(status: status, headers: headers, body: Data(body.utf8), url: url)
}

@Suite struct ClientTests {
    @Test func unifiedHeadersAndCookies() async throws {
        let mock = MockTransport { r in resp(200, r.url, body: "<html>ok</html>") }
        let client = EhHTTPClient(transport: mock)
        client.cookieStore.setLoginCookies(memberId: "1", passHash: "h")
        let text = try await client.getText("https://e-hentai.org/", referer: "https://e-hentai.org")
        #expect(text == "<html>ok</html>")
        let req = try #require(mock.requests.first)
        #expect(req.headers["User-Agent"] == EhNetworkConfig.chromeUserAgent)
        #expect(req.headers["Accept"] == EhNetworkConfig.chromeAccept)
        #expect(req.headers["Accept-Language"] == EhNetworkConfig.chromeAcceptLanguage)
        #expect(req.headers["Referer"] == "https://e-hentai.org")
        let cookie = try #require(req.headers["Cookie"])
        #expect(cookie.contains("ipb_member_id=1"))
        #expect(cookie.contains("ipb_pass_hash=h"))
        #expect(cookie.hasSuffix("nw=1"))
    }

    @Test func redirectsStoreCookiesPerHop() async throws {
        let mock = MockTransport { r in
            switch r.url.absoluteString {
            case "https://forums.e-hentai.org/index.php?act=Login&CODE=01":
                #expect(r.method == .post)
                return resp(302, r.url, headers: [
                    "Location": "/index.php?act=done",
                    "Set-Cookie": "ipb_member_id=9; path=/; domain=.e-hentai.org; max-age=1000",
                ])
            case "https://forums.e-hentai.org/index.php?act=done":
                #expect(r.method == .get)
                #expect(r.body == nil)
                #expect(r.headers["Content-Type"] == nil)
                #expect(r.headers["Cookie"]?.contains("ipb_member_id=9") == true)
                return resp(200, r.url, headers: [
                    "Content-Type": "text/html",
                    "Set-Cookie": "ipb_pass_hash=p; path=/; domain=.e-hentai.org; max-age=1000",
                ], body: "welcome")
            default:
                Issue.record("unexpected \(r.url)")
                return resp(404, r.url)
            }
        }
        let client = EhHTTPClient(transport: mock)
        let r = try await client.postForm(EhURL.apiSignIn, fields: [("UserName", "a b"), ("PassWord", "p&w"), ("submit", "Log me in")],
                                          referer: "https://forums.e-hentai.org/index.php?act=Login&CODE=00",
                                          origin: "https://forums.e-hentai.org")
        #expect(r.status == 200)
        #expect(r.url.absoluteString == "https://forums.e-hentai.org/index.php?act=done")
        #expect(client.hasSignedIn)
        #expect(String(decoding: mock.requests[0].body ?? Data(), as: UTF8.self) == "UserName=a%20b&PassWord=p%26w&submit=Log%20me%20in")
        #expect(mock.requests[0].headers["Origin"] == "https://forums.e-hentai.org")
    }

    @Test func redirectDisabledReturns302() async throws {
        let mock = MockTransport { r in
            resp(302, r.url, headers: ["Location": "https://exhentai.org/", "Set-Cookie": "igneous=x; domain=.exhentai.org; path=/"])
        }
        let client = EhHTTPClient(transport: mock)
        let r = try await client.get("https://exhentai.org/uconfig.php", followRedirects: false)
        #expect(r.status == 302)
        #expect(mock.requests.count == 1)
        #expect(client.cookieStore.contains(URL(string: "https://exhentai.org/")!, name: "igneous"))
    }

    @Test func tooManyRedirects() async {
        let mock = MockTransport { r in resp(302, r.url, headers: ["Location": r.url.absoluteString]) }
        var cfg = EhNetworkConfig()
        cfg.maxRedirects = 3
        let client = EhHTTPClient(config: cfg, transport: mock)
        await #expect(throws: EhError.self) { try await client.get("https://e-hentai.org/") }
        #expect(mock.requests.count == 4)
    }

    @Test func errorDetection() async {
        let banPage = "Your IP address has been temporarily banned for excessive pageloads which indicates that you are using automated mirroring/harvesting software. The ban expires in 59 minutes and 2 seconds"
        let mock = MockTransport { r in
            switch r.url.path {
            case "/ban": return resp(200, r.url, headers: ["Content-Type": "text/html"], body: banPage)
            case "/404": return resp(404, r.url)
            case "/kokomade": return resp(200, r.url, body: "<img src=\"https://exhentai.org/img/kokomade.jpg\">")
            case "/panda": return EhHTTPResponse(status: 200, headers: [
                "Content-Disposition": "inline; filename=\"sadpanda.jpg\"", "Content-Type": "image/gif", "Content-Length": "9615",
            ], body: Data(count: 9615), url: r.url)
            default: throw EhTransportError.timedOut
            }
        }
        let client = EhHTTPClient(transport: mock)
        do {
            _ = try await client.get("https://e-hentai.org/ban")
            Issue.record("should throw")
        } catch let EhError.banned(msg) {
            #expect(msg.contains("The ban expires in 59 minutes"))
        } catch { Issue.record("wrong error \(error)") }
        await #expect(throws: EhError.http(status: 404)) { try await client.get("https://e-hentai.org/404") }
        await #expect(throws: EhError.server("今回はここまで")) { try await client.get("https://exhentai.org/kokomade") }
        await #expect(throws: EhError.server("Sad Panda")) { try await client.get("https://exhentai.org/panda") }
        await #expect(throws: EhError.network(EhTransportError.timedOut.description)) { try await client.get("https://e-hentai.org/timeout") }
        // validate=false 原样返回
        let raw = try? await client.execute(client.makeRequest(URL(string: "https://e-hentai.org/404")!), validate: false)
        #expect(raw?.status == 404)
    }

    @Test func cancellationMapsToCancelled() async {
        let mock = MockTransport { _ in throw CancellationError() }
        let client = EhHTTPClient(transport: mock)
        await #expect(throws: EhError.cancelled) { try await client.get("https://e-hentai.org/") }
    }

    @Test func postJSONAndDownload() async throws {
        let mock = MockTransport { r in
            if r.url.path == "/api.php" {
                #expect(r.headers["Content-Type"] == "application/json; charset=utf-8")
                return resp(200, r.url, headers: ["Content-Type": "application/json"], body: "{\"ok\":1}")
            }
            return EhHTTPResponse(status: 200, headers: ["Content-Type": "image/jpeg"], body: Data([0xff, 0xd8, 0xff]), url: r.url)
        }
        let client = EhHTTPClient(transport: mock)
        let j = try await client.postJSON("https://e-hentai.org/api.php", jsonObject: ["method": "gdata", "gidlist": [[1, "a"]]])
        #expect(j.text == "{\"ok\":1}")
        struct Body: Encodable { let method: String }
        _ = try await client.postJSON("https://e-hentai.org/api.php", body: Body(method: "x"))
        #expect(String(decoding: mock.requests[1].body!, as: UTF8.self) == "{\"method\":\"x\"}")

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("eh-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: file) }
        let progressCalls = Counter()
        let d = try await client.downloadImage("https://ehgt.org/a/b/c.jpg", referer: "https://e-hentai.org/", to: file,
                                               progress: { _, _ in progressCalls.hitSys() })
        #expect(d.status == 200)
        #expect(try Data(contentsOf: file) == Data([0xff, 0xd8, 0xff]))
        #expect(progressCalls.sys == 1)
        #expect(mock.requests.last?.followRedirects == false)
        #expect(mock.requests.last?.timeout == 20)
    }

    @Test func downloadErrorRemovesFile() async {
        let mock = MockTransport { r in resp(403, r.url, body: "forbidden") }
        let client = EhHTTPClient(transport: mock)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("eh-\(UUID().uuidString).jpg")
        await #expect(throws: EhError.http(status: 403)) { try await client.downloadImage("https://ehgt.org/x.jpg", to: file) }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func redirectRequestRules() {
        let post = EhHTTPRequest(method: .post, url: URL(string: "https://a.org/x")!,
                                 headers: ["Content-Type": "application/json", "Authorization": "t", "Host": "a.org"], body: Data("1".utf8))
        let r302 = EhHTTPClient.redirectRequest(from: post, response: resp(302, post.url, headers: ["Location": "https://b.org/y"]))
        #expect(r302?.method == .get)
        #expect(r302?.body == nil)
        #expect(r302?.headers["Authorization"] == nil)
        #expect(r302?.headers["Host"] == nil)
        #expect(EhHTTPClient.redirectRequest(from: post, response: resp(307, post.url, headers: ["Location": "/z"])) == nil)
        let get = EhHTTPRequest(url: URL(string: "https://a.org/x/y")!)
        #expect(EhHTTPClient.redirectRequest(from: get, response: resp(308, get.url, headers: ["Location": "../z?q=1"]))?.url.absoluteString == "https://a.org/z?q=1")
        #expect(EhHTTPClient.redirectRequest(from: get, response: resp(200, get.url)) == nil)
        #expect(EhHTTPClient.redirectRequest(from: get, response: resp(302, get.url, headers: ["Location": "ftp://x/"])) == nil)
    }

    @Test func formEncodingMatchesOkHttp() {
        #expect(FormEncoding.escape("a b+c&d=e/~*-._中") == "a%20b%2Bc%26d%3De%2F%7E*-._%E4%B8%AD")
        #expect(FormEncoding.encode([("k", "v"), ("x", "")]) == "k=v&x=")
    }

    @Test func multipartEncoding() {
        let body = MultipartPart.encode([MultipartPart(name: "f_sfile", filename: "a.jpg", contentType: "image/jpeg", data: Data("IMG".utf8)),
                                         MultipartPart(name: "fs_similar", value: "on")], boundary: "B")
        #expect(String(decoding: body, as: UTF8.self) ==
            "--B\r\nContent-Disposition: form-data; name=\"f_sfile\"; filename=\"a.jpg\"\r\nContent-Type: image/jpeg\r\n\r\nIMG\r\n"
            + "--B\r\nContent-Disposition: form-data; name=\"fs_similar\"\r\n\r\non\r\n--B--\r\n")
    }

    @Test func responseTextCharset() {
        let latin = EhHTTPResponse(status: 200, headers: ["Content-Type": "text/html; charset=ISO-8859-1"], body: Data([0xe9]), url: URL(string: "https://a.org")!)
        #expect(latin.text == "é")
        let bad = EhHTTPResponse(status: 200, headers: [:], body: Data([0xff, 0x41]), url: URL(string: "https://a.org")!)
        #expect(bad.text.hasSuffix("A"))
    }

    @Test func updateConfigRebuilds() async {
        let client = EhHTTPClient(transport: MockTransport { r in resp(200, r.url) })
        await client.updateConfig { $0.userAgent = "UA2"; $0.dnsOverHttps = true }
        #expect(client.config.userAgent == "UA2")
        #expect(await client.resolver.options.dnsOverHttps)
        #expect(client.makeRequest(URL(string: "https://e-hentai.org/")!).headers["User-Agent"] == "UA2")
    }

    @Test func headersCollection() {
        var h: HTTPHeaders = ["A": "1"]
        h.add("a", "2")
        #expect(h.values(for: "A") == ["1", "2"])
        h.set("A", "3")
        #expect(h.values(for: "a") == ["3"])
        h["b"] = "x"
        h["B"] = nil
        #expect(!h.contains("b"))
        h.setIfAbsent("A", "4")
        #expect(h["A"] == "3")
    }
}
