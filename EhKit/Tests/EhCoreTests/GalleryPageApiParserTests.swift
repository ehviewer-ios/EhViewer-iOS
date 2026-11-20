import Testing
@testable import EhCore

@Suite struct GalleryPageApiParserTests {
    /// 移植自 Android GalleryPageApiParserTest
    @Test func parseFixture() throws {
        let r = try GalleryPageApiParser.parse(try GalleryFixture.load("GalleryPageApiParserTest", ext: "json"))
        #expect(r.imageUrl == "http://69.30.203.46:60111/h/6047fa2f194742f6fa541ec1f631ec3ab438f960-183117-1280-960-jpg/keystamp=1550291100-c4438f48c8;fileindex=67379169;xres=1280/Valentines_2019_002.jpg")
        #expect(r.skipHathKey == "15151-430636")
        #expect(r.originImageUrl == "https://e-hentai.org/fullimg.php?gid=1366222&page=3&key=puxxvyg98a4")
        #expect(r.otherImageUrl == "https://e-hentai.org/r/6047fa2f194742f6fa541ec1f631ec3ab438f960-183117-1280-960-jpg/forumtoken/1366222-3/Valentines_2019_002.jpg")
    }

    /// i7 为 null 时从 i6 中找原图链接
    @Test func originFromI6WhenI7Null() throws {
        let json = #"""
        {"i3":"<img id=\"img\" src=\"https://x/y.jpg\" style=\"a\">",
         "i6":"<a href=\"https://e-hentai.org/fullimg.php?gid=1&amp;page=2&amp;key=k\">Download</a> <a onclick=\"return nl('1-2')\">",
         "i7":null}
        """#
        let r = try GalleryPageApiParser.parse(json)
        #expect(r.imageUrl == "https://x/y.jpg")
        #expect(r.skipHathKey == "1-2")
        #expect(r.originImageUrl == "https://e-hentai.org/fullimg.php?gid=1&page=2&key=k")
        #expect(r.otherImageUrl == nil)
    }

    @Test func errorJson() {
        #expect(throws: EhError.self) { try GalleryPageApiParser.parse(#"{"error":"Key mismatch"}"#) }
        #expect(throws: EhError.self) { try GalleryPageApiParser.parse("not json") }
        #expect(throws: EhError.self) { try GalleryPageApiParser.parse(#"{"i3":"","i6":""}"#) }
    }
}
