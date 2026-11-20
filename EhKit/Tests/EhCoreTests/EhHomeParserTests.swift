import Testing
@testable import EhCore

@Suite struct EhHomeParserTests {
    @Test func newQuotaPage() throws {
        let d = EhHomeParser.parse(try MiscFixture.html("HomePageNew"))
        #expect(d.used == 538)
        #expect(d.total == 50000)
        #expect(d.resetCost == 1076)
        #expect(d.fromGalleryVisits == 306_261)
        #expect(d.fromTorrentCompletions == 27176)
        #expect(d.fromArchiveDownloads == 75999)
        #expect(d.fromHentaiAtHome == 0)
        #expect(d.currentModerationPower == 13)
        #expect(d.resetCostText == "1076 Gp")
        #expect(d.imageLimitsText(baseLimitsText: "IP") == "538/50000")
    }

    @Test func oldLimitPage() throws {
        let d = EhHomeParser.parse(try MiscFixture.html("MyHomePage"))
        #expect(d.used == 4672)
        #expect(d.total == 5000)
        #expect(d.resetCost == 9344)
        #expect(d.fromGalleryVisits == 180_764)
        #expect(d.fromTorrentCompletions == 2516)
        #expect(d.fromArchiveDownloads == 55455)
        #expect(d.fromHentaiAtHome == 0)
        #expect(d.currentModerationPower == 6)
    }

    @Test func ipRestrictedPage() throws {
        let d = EhHomeParser.parse(try MiscFixture.html("Home"))
        #expect(d.used == 0)
        #expect(d.total == 0)
        #expect(d.resetCost == 0)
        #expect(d.currentModerationPower == 6)
        #expect(d.imageLimitsText(baseLimitsText: "IP") == "IP")
    }

    @Test func emptyPage() {
        #expect(EhHomeParser.parse("<html></html>") == HomeDetail())
    }
}
