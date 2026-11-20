import Testing
@testable import EhCore

@Suite struct GalleryPageParserTests {
    /// 移植自 Android GalleryPageParserTest
    @Test func parseFixture() throws {
        let r = try GalleryPageParser.parse(try GalleryFixture.load("GalleryPageParserTest"))
        #expect(r.imageUrl == "http://108.6.41.160:2688/h/5c63e9a5810d8d9c873d9e0dfaadc4a0d70a13bf-188862-1280-879-jpg/keystamp=1550291700-145ecbbb10;fileindex=67290651;xres=1280/10.jpg")
        #expect(r.skipHathKey == "26664-430636")
        #expect(r.originImageUrl == "https://e-hentai.org/fullimg.php?gid=1363978&page=10&key=qt2hwrx98a4")
        #expect(r.showKey == "ghz0e5m98a4")
    }

    @Test func missingShowKeyThrows() {
        #expect(throws: EhError.self) {
            try GalleryPageParser.parse(#"<img id="img" src="http://a/b.jpg" style="x">"#)
        }
    }
}
