import Testing
@testable import EhCore

@Suite struct GalleryListUrlParserTests {
    @Test func normalSearch() throws {
        let b = try #require(GalleryListUrlParser.parse(
            "https://e-hentai.org/?f_cats=1017&f_search=female%3Abig+breasts&advsearch=1&f_sname=on&f_sr=on&f_srdd=3&f_sp=on&f_spf=&f_spt=20"
        ))
        #expect(b.mode == .normal)
        #expect(b.category == 6)
        #expect(b.keyword == "female:big breasts")
        #expect(b.advanceSearch == ListUrlBuilder.AdvanceSearchTable.SNAME)
        #expect(b.minRating == 3)
        #expect(b.pageFrom == -1)
        #expect(b.pageTo == 20)
    }

    @Test func homepageVariants() throws {
        #expect(GalleryListUrlParser.parse("https://exhentai.org/") == ListUrlBuilder())
        #expect(GalleryListUrlParser.parse("https://exhentai.org") == ListUrlBuilder())
        #expect(GalleryListUrlParser.parse("https://lofi.e-hentai.org/")?.mode == .normal)
    }

    @Test func uploaderAndTag() throws {
        let u = try #require(GalleryListUrlParser.parse("https://exhentai.org/uploader/some+one/2"))
        #expect(u.mode == .uploader)
        #expect(u.keyword == "some one")
        let t = try #require(GalleryListUrlParser.parse("https://e-hentai.org/tag/female:big+breasts"))
        #expect(t.mode == .tag)
        #expect(t.keyword == "female:big breasts")
        #expect(GalleryListUrlParser.parse("https://e-hentai.org/uploader/") == nil)
    }

    @Test func categoryPath() throws {
        let b = try #require(GalleryListUrlParser.parse("https://e-hentai.org/2?f_search=abc"))
        #expect(b.category == 2)
        #expect(b.keyword == "abc")
    }

    @Test func invalid() {
        #expect(GalleryListUrlParser.parse("https://example.com/") == nil)
        #expect(GalleryListUrlParser.parse("https://e-hentai.org/watched") == nil)
        #expect(GalleryListUrlParser.parse("not a url") == nil)
        #expect(GalleryListUrlParser.parse(nil) == nil)
    }
}
