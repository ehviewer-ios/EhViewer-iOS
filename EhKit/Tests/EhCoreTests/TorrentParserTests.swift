import Testing
@testable import EhCore

@Suite struct TorrentParserTests {
    @Test func parseFixture() throws {
        let result = TorrentParser.parse(try MiscFixture.html("torrentList"))
        try #require(result.count == 2)
        #expect(result[0].posted == "2026-04-26 05:14")
        #expect(result[1].posted == "2026-04-26 05:14")
        #expect(result[0].url == "https://ehtracker.org/get/3905209/96d5199ddac01181000340a59bb84c218faf0b16.torrent")
        #expect(result[1].url == "https://ehtracker.org/get/3905209/713846c3ddf05826d4443790a5b6619eae734d71.torrent")
        #expect(result[0].name.contains("Part 2"))
        #expect(result[1].name.contains("1280x"))
    }

    @Test func emptyBody() {
        #expect(TorrentParser.parse("<html></html>").isEmpty)
    }
}
