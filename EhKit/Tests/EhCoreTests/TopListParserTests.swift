import Testing
@testable import EhCore

@Suite struct TopListParserTests {
    @Test func parseFixture() throws {
        let d = try TopListParser.parse(try MiscFixture.html("GalleryTopList"))
        #expect(d.title == "EHG Toplists")

        let g = d.galleryTopListInfo
        #expect(g.type == .gallery)
        #expect(g.allTimeTopList.length == 10)
        #expect(g.allTimeTopList.get(0)?.href == "https://e-hentai.org/g/596447/3894f02c20/")
        #expect(g.allTimeTopList.get(0)?.value?.hasPrefix("[LemonFont]") == true)
        #expect(g.get(3) == g.allTimeTopList)
        #expect(g.get(0) == g.yesterdayTopList)

        #expect(d.uploaderTopListInfo.allTimeTopList.get(0)?.value == "pork:zero")
        #expect(d.uploaderTopListInfo.allTimeTopList.get(0)?.href == "https://e-hentai.org/uploader/pork:zero")

        for i in 0..<7 {
            let info = try #require(d.get(i))
            #expect(info.type.rawValue == i)
            for j in 0..<info.size {
                #expect(try #require(info.get(j)).length > 0, "type \(i) period \(j)")
            }
        }
        #expect(d.get(7) == nil)
    }

    @Test func errors() {
        #expect(throws: EhError.offensive) {
            try TopListParser.parse("<p>(And if you choose to ignore this warning, you lose all rights to complain about it in the future.)</p>")
        }
        #expect(throws: EhError.pining) {
            try TopListParser.parse("<p>This gallery is pining for the fjords.</p>")
        }
        #expect(throws: EhError.server("Key missing")) {
            try TopListParser.parse("<div class=\"d\">\n<p>Key missing</p></div>")
        }
        #expect(throws: EhError.self) {
            try TopListParser.parse("<html><body>nothing</body></html>")
        }
    }
}
