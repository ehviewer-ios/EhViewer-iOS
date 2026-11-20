import Testing
@testable import EhCore

@Suite struct FavoritesParserTests {
    @Test func parseFixture() throws {
        let r = try FavoritesParser.parse(try GalleryFixture.load("FavoritesListParser"))
        #expect(r.catArray == (0..<10).map { "Favorites \($0)" })
        #expect(r.countArray == [67, 9, 0, 0, 0, 0, 0, 0, 0, 2])
        #expect(r.favOrder == "f")
        #expect(r.galleryInfoList.count == 50)
        #expect(r.pages == -1)
        #expect(r.nextHref == "https://e-hentai.org/favorites.php?favcat=0&next=2301191-1622386290")
        #expect(r.lastHref == "https://e-hentai.org/favorites.php?favcat=0&prev=1-0")
        #expect(r.prevHref == "")
        let gi = r.galleryInfoList[0]
        #expect(gi.gid == 2954138)
        #expect(gi.token == "d6acae440f")
        #expect(gi.favoriteSlot == 0)
        #expect(gi.simpleTags == ["language:chinese", "language:translated", "artist:baalbuddy"])
    }

    @Test func needSignIn() {
        #expect(throws: EhError.notSignedIn) {
            try FavoritesParser.parse("<p>This page requires you to log on.</p>")
        }
    }

    @Test func malformed() {
        #expect(throws: EhError.self) { try FavoritesParser.parse("<html><div class=\"ido\"></div></html>") }
    }
}
