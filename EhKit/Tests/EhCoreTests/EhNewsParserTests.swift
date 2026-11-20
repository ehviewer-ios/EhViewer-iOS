import Testing
@testable import EhCore

@Suite struct EhNewsParserTests {
    @Test func parseNews() throws {
        let html = try MiscFixture.html("EhNews")
        let d = EhNewsParser.parse(html)
        #expect(d.webData == html)
        let pane = try #require(d.eventPane)
        #expect(pane.contains("dawn of a new day"))
        #expect(pane.contains("<strong>35</strong>"))
        #expect(d.htmlData?.hasPrefix("<html") == true)
    }

    @Test func eventParse() throws {
        let pane = try #require(EhEventParse.parse(try MiscFixture.html("EhNews")))
        #expect(pane.contains("Credits!"))
        #expect(EhEventParse.parse(try MiscFixture.html("HomePageNew")) == nil)
    }

    @Test func eventPaneNeedsThreeChildren() {
        let d = EhNewsParser.parse("<html><body><div id=\"eventpane\"><p>a</p></div></body></html>")
        #expect(d.eventPane == nil)
        #expect(EhEventParse.parse("<html><body><div id=\"eventpane\"><p>a</p></div></body></html>") == "<p>a</p>")
    }
}
