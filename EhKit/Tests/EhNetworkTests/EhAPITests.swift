import Foundation
import Testing
@testable import EhNetwork

private let formType = "application/x-www-form-urlencoded"
private let jsonType = "application/json; charset=utf-8"

@Suite struct EhAPISignInTests {
    @Test func signIn() async throws {
        let (api, mock) = makeAPI { r in html(r, "<p>You are now logged in as: brokendog<br>") }
        let name = try await api.signIn(username: "user name", password: "p@ss&1")
        #expect(name == "brokendog")
        let r = try #require(mock.requests.first)
        #expect(r.urlString == "https://forums.e-hentai.org/index.php?act=Login&CODE=01")
        #expect(r.method == .post)
        #expect(r.headers["Content-Type"] == formType)
        #expect(r.headers["Referer"] == "https://forums.e-hentai.org/index.php?act=Login&CODE=00")
        #expect(r.headers["Origin"] == "https://forums.e-hentai.org")
        #expect(r.bodyString == "UserName=user%20name&PassWord=p%40ss%261&submit=Log%20me%20in&CookieDate=1&temporary_https=off")
    }

    @Test func signInError() async throws {
        let (api, _) = makeAPI { r in
            html(r, "<h4>The error returned was:</h4>\n<p>Username or password incorrect</p>")
        }
        await #expect(throws: EhError.server("Username or password incorrect")) {
            try await api.signIn(username: "a", password: "b")
        }
    }

    @Test func getProfile() async throws {
        let forums = """
        <html><body><div id="userlinks"><p><b><a href="https://forums.e-hentai.org/index.php?showuser=42">me</a></b></p></div></body></html>
        """
        let profile = """
        <html><body><div id="profilename"><span>brokendog</span></div><div>Member</div>\
        <div><img src="style_images/avatar.png"></div></body></html>
        """
        let (api, mock) = makeAPI { r in
            r.urlString == "https://forums.e-hentai.org/" ? html(r, forums) : html(r, profile)
        }
        let p = try await api.getProfile()
        #expect(p.displayName == "brokendog")
        #expect(p.avatar == "https://forums.e-hentai.org/style_images/avatar.png")
        #expect(mock.requests.count == 2)
        #expect(mock.requests[0].headers["Referer"] == nil)
        #expect(mock.requests[1].urlString == "https://forums.e-hentai.org/index.php?showuser=42")
        #expect(mock.requests[1].headers["Referer"] == "https://forums.e-hentai.org/")
    }

    @Test func getProfileFromForums() async throws {
        let forums = """
        <html><body><div id="userlinks"><p><b><a href="x">brokendog</a></b></p></div><div>a</div>\
        <div><img src="https://x.org/a.png"></div></body></html>
        """
        let (api, mock) = makeAPI { r in html(r, forums) }
        let p = try await api.getProfileFromForums()
        #expect(p.displayName == "brokendog")
        #expect(p.avatar == "https://x.org/a.png")
        #expect(mock.requests.first?.urlString == "https://forums.e-hentai.org/")
    }
}

@Suite struct EhAPIListTests {
    @Test func galleryListNoApi() async throws {
        let page = try APIFixture.text("GalleryListParserTestEExtended")
        let (api, mock) = makeAPI { r in html(r, page) }
        let url = "https://e-hentai.org/?f_search=test"
        let result = try await api.getGalleryList(url: url)
        #expect(result.galleryInfoList.count == 25)
        #expect(mock.requests.count == 1)
        let r = mock.requests[0]
        #expect(r.method == .get)
        #expect(r.urlString == url)
        #expect(r.headers["Referer"] == "https://e-hentai.org")
        #expect(r.headers["Origin"] == nil)
    }

    @Test func galleryListFillsByApiAndFilters() async throws {
        let page = try APIFixture.text("GalleryListParserTestEMinimal")
        let local = try GalleryListParser.parse(page).galleryInfoList
        try #require(local.count > 3)
        try #require(local.allSatisfy { $0.simpleTags == nil })
        let removedByTitle = local[0].gid
        let removedByTag = local[1].gid
        let meta = gmetadata(local.map { gi in
            (gi.gid, gi.token, gi.gid == removedByTag ? ["female:bad"] : ["female:good"], 10)
        })
        let (api, mock) = makeAPI(EhAPIEnvironment(site: .ex), hooks: EhAPIHooks(galleryFilter: ClosureGalleryFilter(
            needTags: { true },
            title: { $0.gid != removedByTitle },
            tag: { !($0.simpleTags ?? []).contains("female:bad") }
        ))) { r in
            r.url.path == "/api.php" ? json(r, meta) : html(r, page)
        }
        let url = "https://exhentai.org/tag/female:good"
        let result = try await api.getGalleryList(url: url)
        #expect(result.galleryInfoList.count == local.count - 2)
        #expect(!result.galleryInfoList.contains { $0.gid == removedByTitle || $0.gid == removedByTag })
        #expect(result.galleryInfoList.allSatisfy { $0.pages == 10 && $0.simpleTags == ["female:good"] })

        #expect(mock.requests.count == 2)
        let r = mock.requests[1]
        #expect(r.urlString == "https://exhentai.org/api.php")
        #expect(r.method == .post)
        #expect(r.headers["Content-Type"] == jsonType)
        #expect(r.headers["Referer"] == url)
        #expect(r.headers["Origin"] == "https://exhentai.org")
        // 标题过滤在 API 之前，被过滤的不请求
        let ids = local.dropFirst().map { "[\($0.gid),\"\($0.token)\"]" }.joined(separator: ",")
        #expect(r.bodyString == "{\"method\":\"gdata\",\"gidlist\":[\(ids)],\"namespace\":1}")
    }

    @Test func needApiConditions() async throws {
        let calls = Box(0)
        let (api, _) = makeAPI { r in
            calls.mutate { $0 += 1 }
            return json(r, gmetadata([]))
        }
        let noPages = [GalleryInfo(gid: 1, token: "a", simpleTags: [])]
        let withPages = [GalleryInfo(gid: 1, token: "a", simpleTags: [], pages: 3)]
        let rated = [GalleryInfo(gid: 1, token: "a", rated: true, simpleTags: [], pages: 3)]
        // showGalleryPages 且无页数
        _ = try await api.fillGalleryList(noPages, url: "u", filter: false, env: EhAPIEnvironment(showGalleryPages: true))
        #expect(calls.value == 1)
        _ = try await api.fillGalleryList(withPages, url: "u", filter: false, env: EhAPIEnvironment(showGalleryPages: true))
        _ = try await api.fillGalleryList(noPages, url: "u", filter: false, env: EhAPIEnvironment(showGalleryPages: false))
        #expect(calls.value == 1)
        // 已评分
        _ = try await api.fillGalleryList(rated, url: "u", filter: false, env: EhAPIEnvironment())
        #expect(calls.value == 2)
        // 缩略图地址修正
        let thumb = [GalleryInfo(gid: 1, token: "a", thumb: "https://s.exhentai.org/t/31/7a/317a1a25-260198-640-480-png_250.jpg", simpleTags: [], pages: 1)]
        let fixed = try await api.fillGalleryList(thumb, url: "u", filter: false, env: EhAPIEnvironment())
        #expect(fixed[0].thumb == "https://ehgt.org/31/7a/317a1a25-260198-640-480-png_250.jpg")
    }

    @Test func fillByApiBatchesOf25() async throws {
        let list = (1...30).map { GalleryInfo(gid: Int64($0), token: String(format: "%010d", $0)) }
        let (api, mock) = makeAPI { r in
            let s = r.bodyString
            let gids = list.filter { s.contains("[\($0.gid),\"") }
            return json(r, gmetadata(gids.map { ($0.gid, $0.token, ["a:b"], 7) }))
        }
        let filled = try await api.fillGalleryListByApi(list, referer: "https://e-hentai.org/")
        #expect(mock.requests.count == 2)
        #expect(mock.requests[0].bodyString.hasPrefix("{\"method\":\"gdata\",\"gidlist\":[[1,\"0000000001\"],"))
        #expect(mock.requests[1].bodyString == "{\"method\":\"gdata\",\"gidlist\":[[26,\"0000000026\"],[27,\"0000000027\"],[28,\"0000000028\"],[29,\"0000000029\"],[30,\"0000000030\"]],\"namespace\":1}")
        #expect(filled.allSatisfy { $0.pages == 7 && $0.title == "T\($0.gid)" })
    }

    @Test func fillByApiBestEffortSkipsFailedBatch() async throws {
        let list = (1...30).map { GalleryInfo(gid: Int64($0), token: "t") }
        let n = Box(0)
        let (api, _) = makeAPI { r in
            n.mutate { $0 += 1 }
            if n.value == 1 { return html(r, "<html>oops</html>", status: 500) }
            return json(r, gmetadata((26...30).map { (Int64($0), "t", [], 3) }))
        }
        await #expect(throws: EhError.self) { _ = try await api.fillGalleryListByApi(list, referer: "r") }
        n.value = 0
        let filled = await api.fillGalleryListByApiBestEffort(list, referer: "r")
        #expect(filled.prefix(25).allSatisfy { $0.pages == 0 })
        #expect(filled.suffix(5).allSatisfy { $0.pages == 3 })
    }

    @Test func imageSearchMultipart() async throws {
        let page = try APIFixture.text("ImageSearch")
        let (api, mock) = makeAPI { r in
            if r.urlString == "https://upld.e-hentai.org/image_lookup.php" {
                return resp(302, r.url, headers: ["Location": "https://e-hentai.org/?f_shash=abc&fs_from=x"])
            }
            if r.url.path == "/api.php" { return json(r, gmetadata([])) }
            return html(r, page)
        }
        let img = Data([0xFF, 0xD8, 0xFF, 0x00, 0x01])
        let result = try await api.imageSearch(imageData: img, fileName: "cover", uss: true, osc: false, se: true)
        #expect(result.galleryInfoList.count == 2)

        let r0 = mock.requests[0]
        #expect(r0.method == .post)
        #expect(r0.followRedirects == false)
        #expect(r0.timeout == 20)
        #expect(r0.headers["Referer"] == "https://e-hentai.org/")
        #expect(r0.headers["Origin"] == "https://e-hentai.org")
        let ct = try #require(r0.headers["Content-Type"])
        #expect(ct.hasPrefix("multipart/form-data; boundary="))
        let boundary = String(ct.dropFirst("multipart/form-data; boundary=".count))
        var expected = Data()
        func put(_ s: String) { expected.append(Data(s.utf8)) }
        put("--\(boundary)\r\nContent-Disposition: form-data; name=\"sfile\"; filename=\"cover.jpg\"; size=\"40\"\r\nContent-Length: 5\r\n\r\n")
        expected.append(img)
        put("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"fs_similar\"\r\nContent-Length: 2\r\n\r\non\r\n")
        put("--\(boundary)\r\nContent-Disposition: form-data; name=\"fs_exp\"\r\nContent-Length: 2\r\n\r\non\r\n")
        put("--\(boundary)\r\nContent-Disposition: form-data; name=\"f_sfile\"\r\nContent-Length: 11\r\n\r\nFile Search\r\n")
        put("--\(boundary)--\r\n")
        #expect(r0.body == expected)

        let r1 = mock.requests[1]
        #expect(r1.method == .get)
        #expect(r1.urlString == "https://e-hentai.org/?f_shash=abc&fs_from=x")
        #expect(r1.headers["Referer"] == "https://e-hentai.org/")
        #expect(r1.headers["Origin"] == nil)
    }

    @Test func imageSearchExSite() async throws {
        let (api, mock) = makeAPI(EhAPIEnvironment(site: .ex)) { r in html(r, "<html></html>") }
        _ = try? await api.imageSearch(imageData: Data([1]), fileName: "a.png", uss: false, osc: false, se: false)
        let r = try #require(mock.requests.first)
        #expect(r.urlString == "https://upld.exhentai.org/upld/image_lookup.php")
        #expect(r.headers["Referer"] == "https://exhentai.org/")
        #expect(r.bodyString.contains("filename=\"a.png\"; size=\"40\""))
        #expect(!r.bodyString.contains("fs_similar"))
    }
}

@Suite struct EhAPIDetailTests {
    @Test func galleryDetail() async throws {
        let page = try APIFixture.text("GalleryDetail")
        let (api, mock) = makeAPI(EhAPIEnvironment(site: .ex)) { r in html(r, page) }
        let url = "https://exhentai.org/g/3101249/7fb0ea5a0e/"
        let gd = try await api.getGalleryDetail(url: url)
        #expect(gd.gid == 3101249)
        #expect(gd.token == "7fb0ea5a0e")
        let r = mock.requests[0]
        #expect(r.urlString == url)
        #expect(r.headers["Referer"] == "https://exhentai.org")
    }

    @Test func galleryDetailErrors() async throws {
        let (api, _) = makeAPI { r in html(r, "<html><body><div class=\"d\"><p>This gallery is pining for the fjords.</p></div></body></html>") }
        await #expect(throws: EhError.pining) { _ = try await api.getGalleryDetail(url: "https://e-hentai.org/g/1/abc/") }
    }

    @Test func previewSet() async throws {
        let page = try APIFixture.text("GalleryDetail")
        let (api, mock) = makeAPI { r in html(r, page) }
        let (set, pages) = try await api.getPreviewSet(url: "https://e-hentai.org/g/3101249/7fb0ea5a0e/?p=1")
        #expect(pages == (try GalleryDetailParser.parsePreviewPages(page)))
        #expect(set == GalleryDetailParser.parsePreviewSet(page))
        #expect(mock.requests[0].headers["Referer"] == "https://e-hentai.org")
    }

    @Test func rateGallery() async throws {
        let (api, mock) = makeAPI(EhAPIEnvironment(site: .ex)) { r in json(r, "{\"rating_avg\":4.5,\"rating_usr\":4.5,\"rating_cnt\":123}") }
        let r = try await api.rateGallery(apiUid: 4596468, apiKey: "71ecdd05c929c7fdcd61", gid: 3101249, token: "7fb0ea5a0e", rating: 4.3)
        #expect(r.ratingCount == 123)
        let q = mock.requests[0]
        #expect(q.urlString == "https://exhentai.org/api.php")
        #expect(q.method == .post)
        #expect(q.headers["Content-Type"] == jsonType)
        #expect(q.headers["Referer"] == "https://exhentai.org/g/3101249/7fb0ea5a0e/")
        #expect(q.headers["Origin"] == "https://exhentai.org")
        #expect(q.bodyString == #"{"method":"rategallery","apiuid":4596468,"apikey":"71ecdd05c929c7fdcd61","gid":3101249,"token":"7fb0ea5a0e","rating":9}"#)
    }

    @Test func commentGalleryNewAndEdit() async throws {
        let page = try APIFixture.text("GalleryDetail")
        let (api, mock) = makeAPI { r in html(r, page) }
        let url = "https://e-hentai.org/g/3101249/7fb0ea5a0e/"
        let list = try await api.commentGallery(url: url, comment: "nice & good")
        #expect(list.comments.count == (try CommentGalleryParser.parse(page)).comments.count)
        #expect(!list.comments.isEmpty)
        _ = try await api.commentGallery(url: url, comment: "edit", editId: "123")
        let r0 = mock.requests[0], r1 = mock.requests[1]
        #expect(r0.method == .post)
        #expect(r0.urlString == url)
        #expect(r0.headers["Referer"] == url)
        #expect(r0.headers["Origin"] == "https://e-hentai.org")
        #expect(r0.headers["Content-Type"] == formType)
        #expect(r0.bodyString == "commenttext_new=nice%20%26%20good")
        #expect(r1.bodyString == "commenttext_edit=edit&edit_comment=123")
    }

    @Test func commentGallerySiteError() async throws {
        let (api, _) = makeAPI { r in
            html(r, "<html><body><div id=\"chd\"></div><p>Your comment is too short.</p></body></html>")
        }
        await #expect(throws: EhError.server("Your comment is too short.")) {
            _ = try await api.commentGallery(url: "https://e-hentai.org/g/1/a/", comment: "x")
        }
    }

    @Test func getEditComment() async throws {
        let body = #"{"comment_id":55,"editable_comment":"<textarea name=\"commenttext_edit\">hello\nworld</textarea>"}"#
        let (api, mock) = makeAPI { r in json(r, body) }
        let r = try await api.getEditComment(apiUid: 1, apiKey: "k", gid: 2, token: "t", commentId: 55)
        #expect(r.id == 55)
        #expect(r.comment == "hello\nworld")
        let q = mock.requests[0]
        #expect(q.headers["Referer"] == "https://e-hentai.org/g/2/t/")
        #expect(q.bodyString == #"{"method":"geteditcomment","apiuid":1,"apikey":"k","gid":2,"token":"t","comment_id":55}"#)
    }

    @Test func voteComment() async throws {
        let (api, mock) = makeAPI { r in json(r, #"{"comment_id":1253922,"comment_score":-19,"comment_vote":-1}"#) }
        let r = try await api.voteComment(apiUid: 1, apiKey: "k", gid: 2, token: "t", commentId: 1253922, commentVote: -1)
        #expect(r.score == -19)
        #expect(r.vote == -1)
        #expect(r.expectVote == -1)
        let q = mock.requests[0]
        #expect(q.headers["Referer"] == "https://e-hentai.org")
        #expect(q.headers["Origin"] == "https://e-hentai.org")
        #expect(q.bodyString == #"{"method":"votecomment","apiuid":1,"apikey":"k","gid":2,"token":"t","comment_id":1253922,"comment_vote":-1}"#)
    }

    @Test func galleryToken() async throws {
        let (api, mock) = makeAPI { r in json(r, #"{"tokenlist":[{"gid":618395,"token":"0439fa3666"}]}"#) }
        let t = try await api.getGalleryToken(gid: 618395, gtoken: "cfe1a0a8b6", page: 2)
        #expect(t == "0439fa3666")
        let q = mock.requests[0]
        #expect(q.urlString == "https://e-hentai.org/api.php")
        #expect(q.headers["Referer"] == "https://e-hentai.org")
        #expect(q.bodyString == #"{"method":"gtoken","pagelist":[[618395,"cfe1a0a8b6",3]]}"#)
    }

    @Test func galleryTokenError() async throws {
        let (api, _) = makeAPI { r in json(r, #"{"tokenlist":[{"gid":1,"error":"not found"}]}"#) }
        await #expect(throws: EhError.server("not found")) { _ = try await api.getGalleryToken(gid: 1, gtoken: "a", page: 0) }
    }

    @Test func torrentList() async throws {
        let page = try APIFixture.text("torrentList")
        let (api, mock) = makeAPI { r in html(r, page) }
        let url = "https://e-hentai.org/gallerytorrents.php?gid=3905209&t=abc"
        let list = try await api.getTorrentList(url: url, gid: 3905209, token: "abc")
        #expect(list.count == 2)
        #expect(mock.requests[0].urlString == url)
        #expect(mock.requests[0].headers["Referer"] == "https://e-hentai.org/g/3905209/abc/")
    }

    @Test func topList() async throws {
        let page = try APIFixture.text("GalleryTopList")
        let (api, mock) = makeAPI(EhAPIEnvironment(site: .ex)) { r in html(r, page) }
        let url = "https://e-hentai.org/toplist.php?tl=11"
        _ = try await api.getTopList(url: url)
        #expect(mock.requests[0].urlString == url)
        #expect(mock.requests[0].headers["Referer"] == "https://e-hentai.org/toplist.php")
    }
}

@Suite struct EhAPIFavoritesTests {
    @Test func favorites() async throws {
        let page = try APIFixture.text("FavoritesListParser")
        let (api, mock) = makeAPI(hooks: EhAPIHooks(galleryFilter: ClosureGalleryFilter(title: { _ in false }))) { r in
            r.url.path == "/api.php" ? json(r, gmetadata([])) : html(r, page)
        }
        let url = "https://e-hentai.org/favorites.php?favcat=all"
        let result = try await api.getFavorites(url: url)
        // 收藏页不过滤
        #expect(result.galleryInfoList.count == (try FavoritesParser.parse(page)).galleryInfoList.count)
        #expect(result.catArray.count == 10)
        #expect(mock.requests[0].urlString == url)
        #expect(mock.requests[0].headers["Referer"] == "https://e-hentai.org")
        let all = try await api.getAllFavorites(url: url)
        #expect(all.galleryInfoList.count == result.galleryInfoList.count)
    }

    @Test func favoritesNotSignedIn() async throws {
        let (api, _) = makeAPI { r in html(r, "<html><p>This page requires you to log on.</p></html>") }
        await #expect(throws: EhError.notSignedIn) { _ = try await api.getFavorites(url: "https://e-hentai.org/favorites.php") }
    }

    @Test func addFavorites() async throws {
        let (api, mock) = makeAPI(EhAPIEnvironment(site: .ex)) { r in html(r, "<html>ok</html>") }
        try await api.addFavorites(gid: 1, token: "tok", dstCat: 3, note: "hi there")
        try await api.addFavorites(gid: 1, token: "tok", dstCat: -1)
        let url = "https://exhentai.org/gallerypopups.php?gid=1&t=tok&act=addfav"
        let r0 = mock.requests[0]
        #expect(r0.urlString == url)
        #expect(r0.method == .post)
        #expect(r0.headers["Referer"] == url)
        #expect(r0.headers["Origin"] == "https://exhentai.org")
        #expect(r0.headers["Content-Type"] == formType)
        #expect(r0.bodyString == "favcat=3&favnote=hi%20there&submit=Apply%20Changes&update=1")
        #expect(mock.requests[1].bodyString == "favcat=favdel&favnote=&submit=Apply%20Changes&update=1")

        await #expect(throws: EhError.other("Invalid dstCat: 10")) {
            try await api.addFavorites(gid: 1, token: "tok", dstCat: 10)
        }
        #expect(mock.requests.count == 2)
    }

    @Test func addFavoritesHttpError() async throws {
        let (api, _) = makeAPI { r in html(r, "<html>err</html>", status: 503) }
        await #expect(throws: EhError.http(status: 503)) { try await api.addFavorites(gid: 1, token: "t", dstCat: 0) }
    }

    @Test func addFavoritesRange() async throws {
        let (api, mock) = makeAPI { r in html(r, "ok") }
        try await api.addFavoritesRange(gids: [1, 2], tokens: ["a", "b"], dstCat: 9)
        #expect(mock.requests.map(\.urlString) == [
            "https://e-hentai.org/gallerypopups.php?gid=1&t=a&act=addfav",
            "https://e-hentai.org/gallerypopups.php?gid=2&t=b&act=addfav",
        ])
        #expect(mock.requests.allSatisfy { $0.bodyString == "favcat=9&favnote=&submit=Apply%20Changes&update=1" })
    }

    @Test func modifyFavorites() async throws {
        let page = try APIFixture.text("FavoritesListParser")
        let (api, mock) = makeAPI { r in r.url.path == "/api.php" ? json(r, gmetadata([])) : html(r, page) }
        let url = "https://e-hentai.org/favorites.php?favcat=1"
        let result = try await api.modifyFavorites(url: url, gids: [11, 22], dstCat: 2)
        #expect(!result.galleryInfoList.isEmpty)
        let r = mock.requests[0]
        #expect(r.method == .post)
        #expect(r.urlString == url)
        #expect(r.headers["Referer"] == url)
        #expect(r.headers["Origin"] == "https://e-hentai.org")
        #expect(r.bodyString == "ddact=fav2&modifygids%5B%5D=11&modifygids%5B%5D=22&apply=Apply")
        _ = try await api.modifyFavorites(url: url, gids: [5], dstCat: -1)
        #expect(mock.requests.last { $0.url.path != "/api.php" }?.bodyString == "ddact=delete&modifygids%5B%5D=5&apply=Apply")
    }
}

@Suite struct EhAPIArchiveTests {
    @Test func archiveListAndArchiver() async throws {
        let page = try APIFixture.text("ArchiveDownloadDialog")
        let (api, mock) = makeAPI(EhAPIEnvironment(site: .ex)) { r in html(r, page) }
        let url = "https://exhentai.org/archiver.php?gid=2881867&token=b5727f74ec"
        let list = try await api.getArchiveList(url: url, gid: 2881867, token: "b5727f74ec")
        #expect(list.paramOr == "475687-4d0aae5d32a448278ccdf0e8ac7bd32578e76479")
        let data = try await api.getArchiver(url: url, gid: 2881867, token: "b5727f74ec")
        #expect(data.originalSize == "18.46 MiB")
        #expect(mock.requests.allSatisfy { $0.headers["Referer"] == "https://exhentai.org/g/2881867/b5727f74ec/" && $0.method == .get })
    }

    @Test func downloadArchive() async throws {
        let (api, mock) = makeAPI { r in html(r, "<html>queued</html>") }
        try await api.downloadArchive(gid: 1, token: "t", or: "abc-123", res: "org")
        let r = mock.requests[0]
        #expect(r.urlString == "https://e-hentai.org/archiver.php?gid=1&token=t&or=abc-123")
        #expect(r.method == .post)
        #expect(r.bodyString == "hathdl_xres=org")
        #expect(r.headers["Referer"] == "https://e-hentai.org/g/1/t/")
        #expect(r.headers["Origin"] == "https://e-hentai.org")
        await #expect(throws: EhError.self) { try await api.downloadArchive(gid: 1, token: "t", or: nil, res: "org") }
        await #expect(throws: EhError.self) { try await api.downloadArchive(gid: 1, token: "t", or: "", res: "") }
        #expect(mock.requests.count == 1)
    }

    @Test func downloadArchiveNoHath() async throws {
        let (api, _) = makeAPI { r in
            html(r, "<p>You must have a H@H client assigned to your account to use this feature.</p>")
        }
        await #expect(throws: EhError.noHAtH) { try await api.downloadArchive(gid: 1, token: "t", or: "", res: "780") }
    }

    @Test func downloadArchiver() async throws {
        let (api, mock) = makeAPI(EhAPIEnvironment(site: .ex)) { r in
            if r.method == .post {
                return html(r, "<script>document.location = \"https://abc.hath.network/archive/1/x/\";</script>")
            }
            return html(r, "<p><a href=\"/archive/1/x/?start=1\">Click Here To Start Downloading</a></p>")
        }
        let form = "https://exhentai.org/archiver.php?gid=1&token=t&or=o"
        let referer = "https://exhentai.org/g/1/t/"
        let u = try await api.downloadArchiver(url: form, referer: referer, dltype: "org", dlcheck: "Download Original Archive")
        #expect(u == "https://abc.hath.network/archive/1/x/?start=1")
        let r0 = mock.requests[0], r1 = mock.requests[1]
        #expect(r0.urlString == form)
        #expect(r0.bodyString == "dltype=org&dlcheck=Download%20Original%20Archive")
        #expect(r0.headers["Referer"] == referer)
        #expect(r0.headers["Origin"] == "https://exhentai.org")
        #expect(r1.method == .get)
        #expect(r1.urlString == "https://abc.hath.network/archive/1/x/")
        // Java：EhRequestBuilder(continueUrl, origin, null)
        #expect(r1.headers["Referer"] == "https://exhentai.org")
        #expect(r1.headers["Origin"] == nil)
    }

    @Test func downloadArchiverNoRedirect() async throws {
        let (api, mock) = makeAPI { r in html(r, "<html>insufficient funds</html>") }
        let u = try await api.downloadArchiver(url: "https://e-hentai.org/archiver.php?gid=1", referer: "r", dltype: "res", dlcheck: "x")
        #expect(u == nil)
        #expect(mock.requests.count == 1)
        await #expect(throws: EhError.self) {
            _ = try await api.downloadArchiver(url: "", referer: "r", dltype: "res", dlcheck: "x")
        }
    }
}

@Suite struct EhAPIPageTests {
    @Test func galleryPage() async throws {
        let page = try APIFixture.text("GalleryPageParserTest")
        let (api, mock) = makeAPI { r in html(r, page) }
        let url = "https://e-hentai.org/s/0123456789/1-2"
        let r = try await api.getGalleryPage(url: url, gid: 1, token: "abc")
        #expect(r == (try GalleryPageParser.parse(page)))
        #expect(mock.requests[0].urlString == url)
        #expect(mock.requests[0].headers["Referer"] == "https://e-hentai.org/g/1/abc/")
    }

    @Test func galleryPageApi() async throws {
        let body = try APIFixture.text("GalleryPageApiParserTest", ext: "json")
        let (api, mock) = makeAPI(EhAPIEnvironment(site: .ex)) { r in json(r, body) }
        let r = try await api.getGalleryPageApi(gid: 7, index: 0, pToken: "aaaaaaaaaa", showKey: "sk", previousPToken: nil)
        #expect(r == (try GalleryPageApiParser.parse(body)))
        _ = try await api.getGalleryPageApi(gid: 7, index: 3, pToken: "bbbbbbbbbb", showKey: "sk", previousPToken: "cccccccccc")
        let q0 = mock.requests[0], q1 = mock.requests[1]
        #expect(q0.urlString == "https://exhentai.org/api.php")
        #expect(q0.headers["Referer"] == nil)
        #expect(q0.headers["Origin"] == "https://exhentai.org")
        #expect(q0.bodyString == #"{"method":"showpage","gid":7,"page":1,"imgkey":"aaaaaaaaaa","showkey":"sk"}"#)
        #expect(q1.headers["Referer"] == "https://exhentai.org/s/cccccccccc/7-3")
        #expect(q1.bodyString == #"{"method":"showpage","gid":7,"page":4,"imgkey":"bbbbbbbbbb","showkey":"sk"}"#)
    }

    @Test func galleryPageApiPlainTextError() async throws {
        let (api, _) = makeAPI { r in resp(200, r.url, headers: ["Content-Type": "text/plain"], body: "Invalid request.") }
        await #expect(throws: EhError.server("Invalid request.")) {
            _ = try await api.getGalleryPageApi(gid: 7, index: 0, pToken: "a", showKey: "b", previousPToken: nil)
        }
    }
}

@Suite struct EhAPIMyTagsTests {
    @Test func notLoggedIn() async throws {
        let (api, mock) = makeAPI { r in html(r, "") }
        #expect(try await api.getWatchedList(url: "https://e-hentai.org/mytags") == nil)
        #expect(try await api.addTag(url: "https://e-hentai.org/mytags", param: TagPushParam(tagNameNew: "a")) == nil)
        #expect(try await api.deleteWatchedTag(url: "https://e-hentai.org/mytags", tag: UserTag(userTagId: "usertag_1")) == nil)
        #expect(mock.requests.isEmpty)
    }

    @Test func watchedAddDelete() async throws {
        let page = try APIFixture.text("MyTagList")
        let (api, mock) = makeAPI(EhAPIEnvironment(isLogin: true)) { r in html(r, page) }
        let url = "https://e-hentai.org/mytags"
        let list = try #require(try await api.getWatchedList(url: url))
        #expect(list.size == 10)
        #expect(mock.requests[0].headers["Referer"] == nil)
        #expect(mock.requests[0].method == .get)

        let p = TagPushParam(tagNameNew: "female:big breasts", tagWatchNew: "on", tagColorNew: "#ff0000")
        _ = try await api.addTag(url: url, param: p)
        let r1 = mock.requests[1]
        #expect(r1.method == .post)
        #expect(r1.headers["Content-Type"] == "application/x-www-form-urlencoded; charset=utf-8")
        #expect(r1.headers["Referer"] == nil)
        #expect(r1.headers["Origin"] == nil)
        #expect(r1.bodyString == p.addTagParam())

        _ = try await api.deleteWatchedTag(url: url, tag: list.get(0))
        #expect(mock.requests[2].bodyString == list.get(0).deleteParam())
    }
}

@Suite struct EhAPIHomeTests {
    @Test func news() async throws {
        let page = try APIFixture.text("EhNews")
        let (api, mock) = makeAPI(EhAPIEnvironment(site: .ex)) { r in html(r, page, status: 500) }
        let d = try await api.getEhNews()
        #expect(d.webData == page)
        #expect(d.eventPane != nil)
        #expect(mock.requests[0].urlString == "https://e-hentai.org/news.php")
        #expect(mock.requests[0].headers["Referer"] == nil)
    }

    @Test func homeAndResetLimit() async throws {
        let page = try APIFixture.text("Home")
        let events = Box<[String]>([])
        let body = page.replacingOccurrences(of: "</body>", with: "<div id=\"eventpane\"><p>It is the dawn of a new day!</p></div></body>")
        let (api, mock) = makeAPI(EhAPIEnvironment(site: .ex), hooks: EhAPIHooks(onEventPane: { h in events.mutate { $0.append(h) } })) { r in
            html(r, body)
        }
        let d = try await api.getHomeDetail()
        #expect(d == EhHomeParser.parse(body))
        _ = try await api.resetLimit()
        #expect(events.value.count == 2)
        #expect(events.value[0].contains("dawn of a new day"))
        let r0 = mock.requests[0], r1 = mock.requests[1]
        #expect(r0.urlString == "https://e-hentai.org/home.php")
        #expect(r0.method == .get)
        #expect(r0.headers["Referer"] == "https://exhentai.org")
        #expect(r1.urlString == "https://e-hentai.org/home.php")
        #expect(r1.method == .post)
        #expect(r1.headers["Referer"] == "https://exhentai.org")
        #expect(r1.headers["Origin"] == nil)
        #expect(r1.headers["Content-Type"] == formType)
        #expect(r1.bodyString == "reset_imagelimit=Reset%20Limit")
    }
}

@Suite struct EhAPIErrorTests {
    @Test func sadPanda() async throws {
        let (api, _) = makeAPI(EhAPIEnvironment(site: .ex)) { r in
            resp(200, r.url, headers: [
                "Content-Disposition": "inline; filename=\"sadpanda.jpg\"",
                "Content-Type": "image/gif",
                "Content-Length": "9615",
            ], body: "GIF89a")
        }
        await #expect(throws: EhError.server("Sad Panda")) { _ = try await api.getGalleryList(url: "https://exhentai.org/") }
    }

    @Test func exhentaiBlankPage() async throws {
        let (api, _) = makeAPI(EhAPIEnvironment(site: .ex)) { r in html(r, "") }
        await #expect(throws: EhError.server(EhEngineErrors.igneousWrongMessage)) {
            _ = try await api.getGalleryList(url: "https://exhentai.org/")
        }
        do {
            _ = try await api.getGalleryList(url: "https://exhentai.org/?page=2")
            Issue.record("should throw")
        } catch let EhError.parse(msg, _) {
            #expect(msg == EhEngineErrors.emptyHtmlMessage)
        }
    }

    @Test func kokomade() async throws {
        let (api, _) = makeAPI { r in html(r, "<html><img src=\"https://exhentai.org/img/kokomade.jpg\"></html>") }
        await #expect(throws: EhError.server("今回はここまで\n\n" + EhEngineErrors.kokomadeTip)) {
            _ = try await api.getGalleryDetail(url: "https://e-hentai.org/g/1/a/")
        }
    }

    @Test func banned() async throws {
        let (api, _) = makeAPI { r in
            resp(200, r.url, headers: ["Content-Type": "text/html"],
                 body: "Your IP address has been temporarily banned for excessive pageloads. The ban expires in 59 minutes")
        }
        do {
            _ = try await api.getGalleryList(url: "https://e-hentai.org/")
            Issue.record("should throw")
        } catch let EhError.banned(msg) {
            #expect(msg.contains("59 minutes"))
        }
    }

    @Test func parseErrorPlainTextEmptyAndHtml() async throws {
        let bodies = Box<[String]>([])
        let hooks = EhAPIHooks(onParseError: { _, b in bodies.mutate { $0.append(b) } })
        let (api1, _) = makeAPI(hooks: hooks) { r in json(r, "Key missing, or incorrect key provided.") }
        await #expect(throws: EhError.server("Key missing, or incorrect key provided.")) {
            _ = try await api1.getGalleryToken(gid: 1, gtoken: "a", page: 0)
        }
        let (api2, _) = makeAPI(hooks: hooks) { r in json(r, "") }
        do {
            _ = try await api2.getGalleryToken(gid: 1, gtoken: "a", page: 0)
            Issue.record("should throw")
        } catch let EhError.parse(msg, _) {
            #expect(msg == EhEngineErrors.emptyHtmlMessage)
        }
        let (api3, _) = makeAPI(hooks: hooks) { r in html(r, "<html><body>changed layout</body></html>") }
        await #expect(throws: EhError.self) { _ = try await api3.getGalleryToken(gid: 1, gtoken: "a", page: 0) }
        #expect(bodies.value == ["<html><body>changed layout</body></html>"])
    }

    @Test func transportErrorMapped() async throws {
        let (api, _) = makeAPI { _ in throw EhTransportError.timedOut }
        await #expect(throws: EhError.network("请求超时")) { _ = try await api.getHomeDetail() }
    }

    @Test func cancellation() async throws {
        let (api, _) = makeAPI { r in html(r, "<html></html>") }
        let task = Task { () -> Error? in
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try await api.getGalleryDetail(url: "https://e-hentai.org/g/1/a/"); return nil } catch { return error }
        }
        let e = await task.value
        #expect((e as? EhError) == .cancelled)
    }
}
