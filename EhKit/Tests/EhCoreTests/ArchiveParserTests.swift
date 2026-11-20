import Testing
@testable import EhCore

@Suite struct ArchiveParserTests {
    @Test func parseHathList() throws {
        let r = ArchiveParser.parse(try MiscFixture.html("ArchiveDownloadDialog"))
        #expect(r.paramOr == "475687-4d0aae5d32a448278ccdf0e8ac7bd32578e76479")
        #expect(r.archiveList.map(\.res) == ["780", "980", "1280", "1600", "2400", "org"])
        #expect(r.archiveList.first?.name == "780x")
        #expect(r.archiveList.last?.name == "Original")
    }

    @Test func parseArchiverEx() throws {
        let d = ArchiveParser.parseArchiver(try MiscFixture.html("ArchiveDownloadDialog"), site: .ex)
        let action = "https://exhentai.org/archiver.php?gid=2881867&token=b5727f74ec&or=475687-4d0aae5d32a448278ccdf0e8ac7bd32578e76479"
        #expect(d.originalCost == "Free!")
        #expect(d.originalSize == "18.46 MiB")
        #expect(d.originalUrl == action)
        #expect(d.resampleCost == "Free!")
        #expect(d.resampleSize == "2.17 MiB")
        #expect(d.resampleUrl == action)
    }

    @Test func parseArchiverE() {
        let html = """
        <html><body><div id="db">
        <h1>Title</h1><p>x</p><p>Funds: 100 GP</p>
        <div>
          <div><div>Cost: <strong>20 GP</strong></div><form action="https://e-hentai.org/archiver.php?o"></form><p>Size: <strong>1 MiB</strong></p></div>
          <div><div>Cost: <strong>5 GP</strong></div><form action="https://e-hentai.org/archiver.php?r"></form><p>Size: <strong>0.5 MiB</strong></p></div>
        </div></div></body></html>
        """
        let d = ArchiveParser.parseArchiver(html, site: .e)
        #expect(d.funds == "Funds: 100 GP")
        #expect(d.originalCost == "20 GP")
        #expect(d.originalSize == "1 MiB")
        #expect(d.originalUrl == "https://e-hentai.org/archiver.php?o")
        #expect(d.resampleCost == "5 GP")
        #expect(d.resampleSize == "0.5 MiB")
        #expect(d.resampleUrl == "https://e-hentai.org/archiver.php?r")
    }

    @Test func brokenArchiverReturnsPartial() {
        let d = ArchiveParser.parseArchiver("<html><body><div id=\"db\"><h1>t</h1></div></body></html>", site: .ex)
        #expect(d.funds == "t")
        #expect(d.originalUrl == nil)
    }

    @Test func downloadFlow() throws {
        #expect(ArchiveParser.parseArchiverContinueUrl(
            "<script>document.location = \"https://abc.hath.network/archive/1/2/3/?start=1\";</script>")
            == "https://abc.hath.network/archive/1/2/3/?start=1")
        let body = "<script>document.location = \"https://x.org/a\"\n</script>"
        #expect(ArchiveParser.parseArchiverContinueUrl(body) == "https://x.org/a")
        #expect(ArchiveParser.parseArchiverContinueUrl("nothing") == nil)

        let page = "<p><a href=\"/archive/123/abc/def/?start=1\">Click Here To Start Downloading</a></p>"
        #expect(ArchiveParser.parseArchiverDownloadUrl(page) == "/archive/123/abc/def/?start=1")
        #expect(ArchiveParser.archiverDownloadUrl(host: "h.example.org", body: page)
            == "https://h.example.org/archive/123/abc/def/?start=1")
        #expect(ArchiveParser.archiverDownloadUrl(host: "h", body: "") == nil)

        #expect(throws: EhError.noHAtH) {
            try ArchiveParser.checkDownloadArchive(
                "<p>You must have a H@H client assigned to your account to use this feature.</p>")
        }
        try ArchiveParser.checkDownloadArchive("<p>Your download has been queued.</p>")
    }
}
