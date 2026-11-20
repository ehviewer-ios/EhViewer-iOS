import Testing
import Foundation
@testable import EhCore

@Suite struct GalleryDetailParserTests {
    /// 新版（gt200 大缩略图，无偏移）详情页
    @Test func parseGalleryDetail() throws {
        let gd = try GalleryDetailParser.parse(try GalleryFixture.load("GalleryDetail"))
        #expect(gd.gid == 3101249)
        #expect(gd.token == "7fb0ea5a0e")
        #expect(gd.apiUid == 4596468)
        #expect(gd.apiKey == "71ecdd05c929c7fdcd61")
        #expect(gd.info.title == "[DMM.com] Flower Knight Girl (event CG) 2022.11～")
        #expect(gd.info.titleJpn == "[DMM.com] FLOWER KNIGHT GIRL ～X指定～ 2022.11～")
        #expect(gd.info.thumb == "https://s.exhentai.org/t/c7/8a/c78aece64f667d3484456b98a9bb54890f35c30f-205668-960-640-jpg_250.jpg")
        #expect(gd.info.category == .gameCG)
        #expect(gd.info.uploader == "longshenadu")
        #expect(gd.info.posted == "2024-10-25 08:20")
        #expect(gd.parent == "https://exhentai.org/g/3084561/231f9a7b85/")
        #expect(gd.visible == "Yes")
        #expect(gd.language == "Japanese")
        #expect(gd.size == "172.2 MiB")
        #expect(gd.info.pages == 838)
        #expect(gd.favoriteCount == 2225)
        #expect(gd.ratingCount == 189)
        #expect(abs(gd.info.rating - 4.46) < 0.001)
        #expect(!gd.isFavorited)
        #expect(gd.info.favoriteName == nil)
        #expect(gd.torrentCount == 5)
        #expect(gd.torrentUrl == "https://exhentai.org/gallerytorrents.php?gid=3101249&t=7fb0ea5a0e")
        #expect(gd.archiveUrl == "https://exhentai.org/archiver.php?gid=3101249&token=7fb0ea5a0e")
        #expect(gd.newVersions.isEmpty)

        // tag
        #expect(gd.tags.map(\.groupName) == ["parody", "group", "artist", "female", "other"])
        #expect(gd.tags[0].tags == ["flower knight girl"])
        #expect(gd.tags[2].tags.count == 10)
        #expect(gd.tags[3].tags.first == "big breasts")

        // 预览：gt200 新版结构走 NORMAL_PREVIEW_NEW，裁剪区域为整张缩略图
        #expect(gd.previewPages == 42)
        let ps = try #require(gd.previewSet)
        #expect(!ps.isLarge)
        #expect(ps.count == 20)
        #expect(ps.items[0] == GalleryPreview(
            position: 0,
            imageUrl: "https://s.exhentai.org/t/c7/8a/c78aece64f667d3484456b98a9bb54890f35c30f-205668-960-640-jpg_l.jpg",
            pageUrl: "https://exhentai.org/s/c78aece64f/3101249-1",
            clip: .init(x: 0, y: 0, width: 200, height: 133)
        ))
        #expect(ps.items.map(\.position) == Array(0..<20))
        #expect(ps.pageUrl(at: 19) == "https://exhentai.org/s/22853a521d/3101249-20")

        // SpiderInfo 用的正则版
        #expect(gd.spiderInfoPages == 838)
        #expect(gd.spiderInfoPreviewPages == 42)
        #expect(gd.spiderInfoPreviewSet == gd.previewSet)
    }

    @Test func comments() throws {
        let gd = try GalleryDetailParser.parse(try GalleryFixture.load("GalleryDetail"))
        let list = gd.comments
        #expect(list.comments.count == 28)
        #expect(!list.hasMore)

        // 上传者评论
        let uploader = list.comments[0]
        #expect(uploader.id == 0)
        #expect(uploader.isUploaderComment)
        #expect(uploader.user == "longshenadu")
        #expect(uploader.time == ParserUtils.parseDate("2024-10-25 08:20"))
        #expect(!uploader.voteUpAble)
        #expect(uploader.comment.contains("<br"))

        let c = list.comments[1]
        #expect(c.id == 5277323)
        #expect(c.score == -43)
        #expect(c.voteUpAble && c.voteDownAble)
        #expect(!c.voteUpEd && !c.voteDownEd)
        #expect(c.user == "cyh1012719457")
        #expect(c.voteState?.hasPrefix("Base +5") == true)
        #expect(c.lastEdited == 0)

        // 带 "Last edited on" 的评论
        let edited = try #require(list.comments.first { $0.id == 5538338 })
        #expect(edited.score == -100)
        #expect(edited.user == "JJYY753")
        #expect(edited.time == ParserUtils.parseDate("2023-02-26 12:54"))
        #expect(edited.lastEdited == ParserUtils.parseDate("2023-03-27 12:39"))
        #expect(edited.comment == "已编辑.")
    }

    @Test func blacklistFiltersComments() throws {
        let gd = try GalleryDetailParser.parse(try GalleryFixture.load("GalleryDetail"), isBlacklisted: { $0 == "cyh1012719457" })
        #expect(gd.comments.comments.count == 27)
        #expect(!gd.comments.comments.contains { $0.user == "cyh1012719457" })
    }

    /// 旧版（gdtm 雪碧图 + 偏移）详情页，含新版本列表与收藏状态
    @Test func parseOldPageWithNewVersions() throws {
        let gd = try GalleryDetailParser.parse(try GalleryFixture.load("newPage"))
        #expect(gd.gid == 2217617)
        #expect(gd.token == "36d9cc5391")
        #expect(gd.info.title == "[Twitter] AkiyamaRyo (2019.11.09-2022.5.10)")
        #expect(gd.info.titleJpn == "")
        #expect(gd.info.category == .misc)
        #expect(gd.info.uploader == "AdamAbbott")
        #expect(gd.visible == "No (Replaced)")
        #expect(gd.size == "840.5 MB")
        #expect(gd.info.pages == 394)
        #expect(gd.favoriteCount == 23177)
        #expect(gd.ratingCount == 1195)
        #expect(abs(gd.info.rating - 4.82) < 0.001)
        #expect(gd.isFavorited)
        #expect(gd.info.favoriteName == "Favorites 0")
        #expect(gd.torrentCount == 17)
        #expect(gd.archiveUrl == "https://e-hentai.org/archiver.php?gid=2217617&token=36d9cc5391&or=468590--51c2afe3295b9ddb4c7de89e410541aba3bbff90")
        #expect(gd.tags.map(\.groupName) == ["parody", "character", "male", "female", "mixed", "other"])

        // 新版本
        #expect(gd.newVersions.count > 5)
        #expect(gd.newVersions[0] == GalleryNewVersion(
            versionUrl: "https://e-hentai.org/g/2218381/63d480f14c/",
            versionName: "[Twitter] AkiyamaRyo (2019.11.09-2022.5.11), added 2022-05-12 04:48"
        ))
        let newInfo = try #require(gd.info(forNewVersion: 0))
        #expect(newInfo.gid == 2218381)
        #expect(newInfo.token == "63d480f14c")
        #expect(gd.updateVersionNames.count == gd.newVersions.count)

        // 雪碧图预览
        #expect(gd.previewPages == 10)
        let ps = try #require(gd.previewSet)
        #expect(!ps.isLarge)
        #expect(ps.count == 40)
        #expect(ps.items[0].imageUrl == "https://ehgt.org/m/002217/2217617-00.jpg")
        #expect(ps.items[0].pageUrl == "https://e-hentai.org/s/8f98b5c426/2217617-1")
        #expect(ps.items[0].clip == .init(x: 0, y: 0, width: 100, height: 34))
        #expect(ps.items[1].clip?.x == 100)
        #expect(ps.items[39].clip == .init(x: 1900, y: 0, width: 85, height: 150))
        #expect(gd.spiderInfoPages == 394)
        #expect(gd.spiderInfoPreviewPages == 10)

        // 评论："click to show all"
        #expect(gd.comments.hasMore)
        #expect(gd.comments.comments.count == 52)
        #expect(gd.comments.comments[1].id == 4404214)
        #expect(gd.comments.comments[1].time == ParserUtils.parseDate("2021-07-24 16:37"))
    }

    @Test func parseSpiderInfoPage() throws {
        let gd = try GalleryDetailParser.parse(try GalleryFixture.load("spiderInfo"))
        #expect(gd.gid == 2564406)
        #expect(gd.info.category == .artistCG)
        #expect(gd.info.pages == 8)
        #expect(gd.previewPages == 1)
        #expect(gd.previewSet?.count == 8)
        #expect(gd.previewSet?.items[7].clip?.x == 700)
        #expect(gd.torrentCount == 0)
        #expect(gd.parent == "")
    }

    @Test func fixThumbUrlOnlyAffectsLargePreviews() throws {
        let html = """
        <div id="gdt"><a href="https://e-hentai.org/s/abc/1-1"><div title="Page 1: a.jpg" style="background:transparent url(https://s.exhentai.org/t/ab/cd/abcdef-1-2-3-jpg_l.jpg) 0 0 no-repeat"></div></a></div>
        """
        let set = GalleryDetailParser.parsePreviewSet(html, fixThumbUrl: true)
        #expect(set.isLarge)
        #expect(set.items.first?.imageUrl == "https://ehgt.org/ab/cd/abcdef-1-2-3-jpg_l.jpg")
        #expect(set.items.first?.clip == nil)
        let raw = GalleryDetailParser.parsePreviewSet(html)
        #expect(raw.items.first?.imageUrl == "https://s.exhentai.org/t/ab/cd/abcdef-1-2-3-jpg_l.jpg")
    }

    @Test func errorPages() {
        #expect(throws: EhError.offensive) {
            try GalleryDetailParser.parse("<p>(And if you choose to ignore this warning, you lose all rights to complain about it in the future.)</p>")
        }
        #expect(throws: EhError.pining) {
            try GalleryDetailParser.parse("<div><p>This gallery is pining for the fjords.</p></div>")
        }
        #expect(throws: EhError.server("此画廊已被下架\nThis gallery is unavailable")) {
            try GalleryDetailParser.parse("<h1>This gallery is unavailable</h1>")
        }
        #expect(throws: EhError.self) {
            try GalleryDetailParser.parse("Your IP address has been temporarily banned for excessive pageloads.")
        }
        #expect(throws: EhError.server("Gallery not found. If you just added this gallery, wait a few minutes.")) {
            try GalleryDetailParser.parse("<div class=\"d\">\n<p>Gallery not found. If you just added this gallery, wait a few minutes.</p></div>")
        }
        #expect(throws: EhError.self) { try GalleryDetailParser.parse("<html></html>") }
    }

    @Test func coverStyle() {
        #expect(GalleryDetailParser.parseCoverStyle(
            "width:250px; height:356px; background:transparent url(https://exhentai.org/t/fe/1f/x_250.jpg) 0 0 no-repeat"
        ) == "https://exhentai.org/t/fe/1f/x_250.jpg")
        #expect(GalleryDetailParser.parseCoverStyle("nothing") == "")
    }

    @Test func detailCodableRoundTripAndBackwardCompat() throws {
        let gd = try GalleryDetailParser.parse(try GalleryFixture.load("spiderInfo"))
        let data = try JSONEncoder().encode(gd)
        #expect(try JSONDecoder().decode(GalleryDetail.self, from: data) == gd)
        // 只有 info 的旧数据也能解码
        let old = #"{"info":{"gid":1,"token":"a","category":1,"disowned":false,"rating":0,"rated":false,"pages":0,"thumbWidth":0,"thumbHeight":0,"favoriteSlot":-2}}"#
        let decoded = try JSONDecoder().decode(GalleryDetail.self, from: Data(old.utf8))
        #expect(decoded.gid == 1)
        #expect(decoded.apiUid == -1)
        #expect(decoded.spiderInfoPages == 0)
    }
}
