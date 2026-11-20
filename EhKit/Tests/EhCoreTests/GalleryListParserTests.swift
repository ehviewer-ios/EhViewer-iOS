import Testing
import Foundation
@testable import EhCore

@Suite struct GalleryListParserTests {
    static let modes = [
        "GalleryListParserTestEMinimal", "GalleryListParserTestEMinimalPlus", "GalleryListParserTestECompat",
        "GalleryListParserTestEExtended", "GalleryListParserTestEThumbnail",
        "GalleryListParserTestExMinimal", "GalleryListParserTestExMinimalPlus", "GalleryListParserTestExCompat",
        "GalleryListParserTestExExtended", "GalleryListParserTestExThumbnail",
    ]

    /// 移植自 Android GalleryListParserTest
    @Test(arguments: modes)
    func parseDisplayModes(_ file: String) throws {
        let result = try GalleryListParser.parse(try GalleryFixture.load(file))
        #expect(result.galleryInfoList.count == 25)
        let isThumbnail = file.hasSuffix("Thumbnail")
        for gi in result.galleryInfoList {
            #expect(gi.title != nil)
            #expect(gi.thumb != nil)
            #expect(gi.posted != nil)
            #expect(gi.gid > 0)
            #expect(gi.token.count == 10)
            #expect(gi.pages > 0)
            #expect(gi.thumbWidth > 0 && gi.thumbHeight > 0)
            if isThumbnail {
                #expect(gi.uploader == nil)
            } else {
                #expect(gi.uploader != nil)
            }
        }
        // 旧版页码分页
        #expect(result.pages == (file.contains("TestEx") ? 1984 : 1928))
        #expect(result.nextPage == 1)
        #expect(result.nextHref == nil)
    }

    @Test func eSiteFirstItem() throws {
        let gi = try #require(try GalleryListParser.parse(try GalleryFixture.load("GalleryListParserTestECompat")).galleryInfoList.first)
        #expect(gi.gid == 1392268)
        #expect(gi.token == "7ff56437fa")
        #expect(gi.title == "[NekoNiwa] Stomach-filling Activity")
        #expect(gi.category == .nonH)
        #expect(gi.posted == "2019-04-03 10:59")
        #expect(gi.uploader == "maverih345456")
        #expect(gi.pages == 26)
        #expect(gi.thumbWidth == 250)
        #expect(gi.thumbHeight == 353)
        #expect(gi.thumb == "https://ul.ehgt.org/dc/ad/dcad4eda683c3fa6422737048171330dcf1215cd-753622-2150-3035-jpg_250.jpg")
        #expect(gi.rating == 0) // background-position:-80px -1px
        #expect(gi.favoriteSlot == -2)
        #expect(gi.tgList == ["parody:kantai collection"])
    }

    @Test func exSiteFirstItemAndLanguage() throws {
        let list = try GalleryListParser.parse(try GalleryFixture.load("GalleryListParserTestExMinimal")).galleryInfoList
        #expect(list[0].gid == 1392234)
        #expect(list[0].rating == 5.0)
        #expect(list[0].simpleLanguage == "ZH")
        #expect(list[0].uploader == "实践梦想")
        #expect(list[1].rating == 4.5)
        #expect(list[1].pages == 8)
    }

    @Test func extendedModeHasSimpleTags() throws {
        let gi = try GalleryListParser.parse(try GalleryFixture.load("GalleryListParserTestExExtended")).galleryInfoList[0]
        #expect(gi.simpleTags == [
            "language:chinese", "language:translated", "parody:touhou project", "character:flandre scarlet",
            "character:koishi komeiji", "character:satori komeiji", "group:aoirokanata", "artist:shikitani asuka",
        ])
        #expect(gi.uploader == "实践梦想")
        #expect(gi.pages == 28)
    }

    @Test func compatModeTagList() throws {
        let gi = try GalleryListParser.parse(try GalleryFixture.load("GalleryListParserTestExCompat")).galleryInfoList[0]
        #expect(gi.tgList?.count == 8)
        #expect(gi.tgList?.first == "language:chinese")
        #expect(gi.simpleTags == nil)
    }

    /// 新版 prev/next 游标分页
    @Test func newCursorPagination() throws {
        let r = try GalleryListParser.parse(try GalleryFixture.load("GalleryListParserNew3"))
        #expect(r.galleryInfoList.count == 25)
        #expect(r.pages == -1)
        #expect(r.nextPage == -1)
        #expect(r.resultCount == "1,000+")
        #expect(r.firstHref == "")
        #expect(r.prevHref == "")
        #expect(r.nextHref == "https://exhentai.org/?f_search=female:mother++female:cheating&next=2416609")
        #expect(r.lastHref == "https://exhentai.org/?f_search=female:mother++female:cheating&prev=1")
        #expect(r.hrefs.nextHref == r.nextHref)
        let gi = r.galleryInfoList[0]
        #expect(gi.gid == 2426224)
        #expect(gi.category == .manga)
        #expect(gi.simpleLanguage == "EN")
        #expect(gi.tgList?.contains("female:mother") == true)
    }

    @Test func imageSearchResultCount() throws {
        let r = try GalleryListParser.parse(try GalleryFixture.load("ImageSearch"))
        #expect(r.galleryInfoList.count == 2)
        #expect(r.resultCount == "2")
        #expect(r.pages == -1)
        #expect(r.galleryInfoList[0].gid == 2892498)
        #expect(r.galleryInfoList[0].pages == 29)
    }

    @Test func uploaderList() throws {
        let r = try GalleryListParser.parse(try GalleryFixture.load("GalleryListUploader"))
        #expect(r.galleryInfoList.count == 25)
        #expect(r.pages == 217)
        #expect(r.galleryInfoList.allSatisfy { $0.uploader == "qq3870990" })
        #expect(r.galleryInfoList[0].category == .doujinshi)
    }

    @Test func frontPage() throws {
        let r = try GalleryListParser.parse(try GalleryFixture.load("test"))
        #expect(r.galleryInfoList.count == 25)
        #expect(r.pages == 25796)
        #expect(r.nextPage == 2)
        #expect(r.galleryInfoList[0].simpleLanguage == "ES")
    }

    /// Compact 模式下 "No unfiltered results in this page range" 视为空页而非错误
    @Test func emptyCompactList() throws {
        let r = try GalleryListParser.parse(try GalleryFixture.load("EmptyGalleryList"))
        #expect(r.galleryInfoList.isEmpty)
        #expect(r.pages == 2575)
        #expect(r.nextPage == 0)
    }

    @Test func noHitsFound() throws {
        let body = "<html><body><div class=\"ido\"><p>No hits found</p></div></body></html>"
        let r = try GalleryListParser.parse(body)
        #expect(r.pages == 0)
        #expect(r.galleryInfoList.isEmpty)
    }

    @Test func noWatchedTags() throws {
        let body = "<html><body><p>You do not have any watched tags</p><p>No hits found</p></body></html>"
        let r = try GalleryListParser.parse(body)
        #expect(r.noWatchedTags)
        #expect(r.pages == 0)
    }

    @Test func garbageThrows() {
        #expect(throws: EhError.self) { try GalleryListParser.parse("<html><body>hello</body></html>") }
    }

    @Test func localFavoriteAndThumbResolution() throws {
        let body = try GalleryFixture.load("GalleryListParserTestECompat")
        let r = try GalleryListParser.parse(body, thumbResolution: 2, isLocalFavorite: { $0 == 1392268 })
        #expect(r.galleryInfoList[0].favoriteSlot == -1)
        #expect(r.galleryInfoList[1].favoriteSlot == -2)
        #expect(r.galleryInfoList[0].thumb?.hasSuffix("-jpg_300.jpg") == true)
    }

    @Test func ratingStyle() {
        #expect(GalleryListParser.parseRating("background-position:0px -1px;opacity:1") == "5")
        #expect(GalleryListParser.parseRating("background-position:-16px -21px") == "3.5")
        #expect(GalleryListParser.parseRating("background-position:-80px -1px") == "0")
        #expect(GalleryListParser.parseRating("background-position:0px") == nil)
    }

    @Test func favoriteSlotColor() {
        #expect(GalleryListParser.parseFavoriteSlot("border-color:#000;background-color:rgba(0,0,0,0.1)") == 0)
        #expect(GalleryListParser.parseFavoriteSlot("background-color:rgba(224,128,224,0.1)") == 9)
        #expect(GalleryListParser.parseFavoriteSlot("background-color:rgba(1,2,3,0.1)") == -2)
        #expect(GalleryListParser.parseFavoriteSlot("") == -2)
    }

    @Test func resultCountText() {
        #expect(GalleryListParser.parseResultCount("Found thousands of results") == "1,000+")
        #expect(GalleryListParser.parseResultCount("Found about 12,345 results") == "12,345+")
        #expect(GalleryListParser.parseResultCount("Found 123 results") == "123")
        #expect(GalleryListParser.parseResultCount("Found 1 2 results") == "12")
    }
}
