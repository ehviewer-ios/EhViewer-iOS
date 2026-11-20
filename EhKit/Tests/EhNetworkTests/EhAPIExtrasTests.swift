import Foundation
import Testing
@testable import EhNetwork

@Suite struct EhAPIJSONTests {
    @Test func androidEscaping() {
        let v = AndroidJSON.obj(("a/b", "x\"y\\z/\n\t\u{01}中"), ("n", -3), ("l", .array([.bool(true), .int(0)])))
        #expect(v.encoded == "{\"a\\/b\":\"x\\\"y\\\\z\\/\\n\\t\\u0001中\",\"n\":-3,\"l\":[true,0]}")
    }
}

@Suite struct EhUrlRouteTests {
    @Test func routes() throws {
        guard case let .galleryDetail(gid, token)? = EhUrlRoute.parseEhUrl("https://e-hentai.org/g/2914213/fc8bce61d9/") else {
            Issue.record("detail"); return
        }
        #expect(gid == 2914213 && token == "fc8bce61d9")

        guard case let .galleryPage(pgid, ptoken, page)? = EhUrlRoute.route("https://exhentai.org/s/0123456789/618395-3") else {
            Issue.record("page"); return
        }
        #expect(pgid == 618395 && ptoken == "0123456789" && page == 2)

        guard case let .galleryList(builder)? = EhUrlRoute.route("https://e-hentai.org/tag/female:big+breasts") else {
            Issue.record("list"); return
        }
        #expect(builder == GalleryListUrlParser.parse("https://e-hentai.org/tag/female:big+breasts"))

        #expect(EhUrlRoute.route("https://github.com/") == .external("https://github.com/"))
        #expect(EhUrlRoute.parseEhUrl("https://github.com/") == nil)
        #expect(EhUrlRoute.route("https://e-hentai.org/g/1/abcdef0123/", ehUrl: false) == .external("https://e-hentai.org/g/1/abcdef0123/"))
        #expect(EhUrlRoute.route("") == nil)
        #expect(EhUrlRoute.route(nil) == nil)
        #expect(!EhUrlRoute.external("x").isInternal)
    }
}

@Suite struct CookieSignInTests {
    @Test func validation() {
        #expect(CookieSignIn.checkIpbMemberId("1234567"))
        #expect(!CookieSignIn.checkIpbMemberId("12a"))
        #expect(CookieSignIn.checkIpbPassHash("0123456789abcdef0123456789abcdef"))
        #expect(CookieSignIn.checkIpbPassHash("zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"))
        #expect(!CookieSignIn.checkIpbPassHash("0123456789ABCDEF0123456789abcdef"))
        #expect(!CookieSignIn.checkIpbPassHash("abc"))
    }

    @Test func clipboard() throws {
        let text = "ipb_member_id: 123\r\nipb_pass_hash: 0123456789abcdef0123456789abcdef\nigneous: ff00\nother: x\nbad"
        let f = try #require(CookieSignIn.parseClipboard(text))
        #expect(f.memberId == "123")
        #expect(f.passHash == "0123456789abcdef0123456789abcdef")
        #expect(f.igneous == "ff00")
        #expect(CookieSignIn.parseClipboard("ipb_member_id: 1") == nil)
    }

    @Test func storeWritesThreeDomains() {
        let store = EhCookieStore()
        CookieSignIn.store(memberId: " 1 ", passHash: "h", igneous: "", in: store)
        #expect(store.hasSignedIn)
        #expect(store.contains(URL(string: "https://exhentai.org/")!, name: "ipb_pass_hash"))
        #expect(store.contains(URL(string: "https://forums.e-hentai.org/")!, name: "ipb_member_id"))
        #expect(!store.contains(URL(string: "https://exhentai.org/")!, name: "igneous"))
        #expect(store.cookies(for: URL(string: "https://e-hentai.org/")!).first { $0.name == "ipb_member_id" }?.value == "1")
    }
}

@Suite struct TagTranslationUpdaterTests {
    static func makeData(_ lines: [(String, String)]) -> Data {
        let text = lines.map { "\($0.0)\r\(Data($0.1.utf8).base64EncodedString())\n" }.joined()
        let body = Data(text.utf8)
        var d = Data()
        let n = UInt32(body.count)
        d.append(contentsOf: [UInt8(n >> 24 & 0xff), UInt8(n >> 16 & 0xff), UInt8(n >> 8 & 0xff), UInt8(n & 0xff)])
        d.append(body)
        return d
    }

    @Test func updateFlow() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ehtag-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let meta = TagTranslation.Metadata(sha1Name: "t.sha1", sha1Url: "https://example.com/t.sha1",
                                           dataName: "t", dataUrl: "https://example.com/t")
        let v1 = Self.makeData([("f:big breasts", "巨乳")])
        let v2 = Self.makeData([("f:big breasts", "巨乳"), ("m:glasses", "眼镜")])
        let served = Box((sha1: SHA1.hash(v1), data: v1))
        let mock = MockTransport { r in
            if r.url.path.hasSuffix(".sha1") { return resp(200, r.url, headers: [:], body: "") .with(body: served.value.sha1) }
            return resp(200, r.url, headers: [:]).with(body: served.value.data)
        }
        let updater = TagTranslationUpdater(client: EhHTTPClient(transport: mock), directory: dir, metadata: meta)

        // 首次：下载 sha1 + 数据
        let t1 = try #require(await updater.update())
        #expect(t1.getTranslation("f:big breasts") == "巨乳")
        #expect(mock.requests.count == 2)
        #expect(mock.requests[0].headers["Referer"] == nil)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("t").path))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("t.tmp").path))

        // 未变化：只下载 sha1
        _ = await updater.update()
        #expect(mock.requests.count == 3)

        // 新数据但 sha1 不匹配：不替换
        served.value = (sha1: SHA1.hash(v1), data: v2)
        served.value.sha1 = Data(repeating: 0, count: 20)
        _ = await updater.update()
        #expect(mock.requests.count == 5)
        #expect(await updater.current?.getTranslation("m:glasses") == nil)

        // 正常更新
        served.value = (sha1: SHA1.hash(v2), data: v2)
        let t2 = try #require(await updater.update())
        #expect(t2.getTranslation("m:glasses") == "眼镜")

        // 新实例从本地加载
        let other = TagTranslationUpdater(client: EhHTTPClient(transport: mock), directory: dir, metadata: meta)
        #expect(await other.instance()?.getTranslation("m:glasses") == "眼镜")

        // 本地数据损坏：instance 删除文件
        try Data("broken".utf8).write(to: dir.appendingPathComponent("t"))
        let third = TagTranslationUpdater(client: EhHTTPClient(transport: mock), directory: dir, metadata: meta)
        #expect(await third.instance() == nil)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("t.sha1").path))
    }

    @Test func downloadFailureKeepsCurrent() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ehtag-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockTransport { r in resp(404, r.url) }
        let updater = TagTranslationUpdater(client: EhHTTPClient(transport: mock), directory: dir, metadata: .default)
        #expect(await updater.update() == nil)
        #expect(mock.requests.count == 1)
        #expect(mock.requests[0].urlString == TagTranslation.Metadata.default.sha1Url)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("tag-translations-zh-rCN.sha1.tmp").path))

        let none = TagTranslationUpdater(client: EhHTTPClient(transport: mock), directory: dir, metadata: nil)
        #expect(await none.update() == nil)
        #expect(mock.requests.count == 1)
    }
}

extension EhHTTPResponse {
    func with(body: Data) -> EhHTTPResponse {
        var r = self
        r.body = body
        return r
    }
}
