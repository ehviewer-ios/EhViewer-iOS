import Foundation
import Testing
@testable import EhCore

@Suite struct MyTagLitParserTests {
    @Test func parseFixture() throws {
        let list = try MyTagLitParser.parse(try MiscFixture.html("MyTagList"))
        #expect(list.size == 10)
        #expect(list.userTags.last?.id == 1186)
        let t = list.get(0)
        #expect(t.userTagId == "usertag_3437")
        #expect(t.id == 3437)
        #expect(t.tagName == "language:chinese")
        #expect(t.watched)
        #expect(!t.hidden)
        #expect(t.color == "#default")
        #expect(t.tagWeight == 10)
        #expect(list.userTags.allSatisfy { $0.tagName?.contains(":") == true })
        #expect(t.deleteParam()
            == "usertag_action=mass&tagname_new=&tagcolor_new=&tagweight_new=10&modify_usertags%5B%5D=3437&usertag_target=0")
    }

    @Test func noOuterReturnsEmpty() throws {
        #expect(try MyTagLitParser.parse("<html><body></body></html>").size == 0)
    }

    @Test func errorPage() {
        #expect(throws: EhError.server("Not logged in")) {
            try MyTagLitParser.parse("<div class=\"d\">\n<p>Not logged in</p></div>")
        }
    }

    @Test func tagPushParam() {
        var p = TagPushParam(tagNameNew: "female:big breasts", tagWatchNew: "on", tagColorNew: "#ff0000")
        #expect(p.addTagParam()
            == "usertag_action=add&tagname_new=female%3Abig+breasts&tagwatch_new=on&tagcolor_new=%23ff0000&tagweight_new=10&usertag_target=0")
        p.tagWatchNew = nil
        p.tagHiddenNew = "on"
        p.tagColorNew = nil
        #expect(p.addTagParam()
            == "usertag_action=add&tagname_new=female%3Abig+breasts&taghide_new=on&tagcolor_new=&tagweight_new=10&usertag_target=0")
    }

    @Test func userTagName() throws {
        let line = "f:big breasts\r" + Data("巨乳".utf8).base64EncodedString() + "\n"
            + "n:female\r" + Data("女性".utf8).base64EncodedString() + "\n"
        let db = try TagTranslation(name: "t", data: TagTranslationTests.pack(line))
        let tag = UserTag(userTagId: "usertag_1", tagName: "female:big breasts")
        #expect(tag.getName(db, showTranslation: true) == "女性:巨乳")
        #expect(tag.getName(db, showTranslation: false) == "female:big breasts")
        #expect(tag.getName(nil, showTranslation: true) == "female:big breasts")
    }
}
