import Testing
@testable import EhCore

@Suite struct ProfileParserTests {
    static let profileHtml = """
    <html><body><div id="profile">
    <div id="profilename"><span>brokendog</span></div>
    <div>Member</div>
    <div><img src="style_images/avatar.png"></div>
    </div></body></html>
    """

    @Test func parseProfile() throws {
        let r = try ProfileParser.parse(Self.profileHtml)
        #expect(r.displayName == "brokendog")
        #expect(r.avatar == "https://forums.e-hentai.org/style_images/avatar.png")
    }

    @Test func absoluteAndMissingAvatar() throws {
        let abs = Self.profileHtml.replacingOccurrences(of: "style_images/avatar.png", with: "https://x.org/a.png")
        #expect(try ProfileParser.parse(abs).avatar == "https://x.org/a.png")
        let none = "<html><body><div id=\"profilename\"><b>n</b></div></body></html>"
        let r = try ProfileParser.parse(none)
        #expect(r.displayName == "n")
        #expect(r.avatar == nil)
    }

    @Test func parseFailure() {
        #expect(throws: EhError.self) { try ProfileParser.parse("<html></html>") }
    }

    @Test func parseNewEscaped() throws {
        let body = #"<div id=\"userlinks\"><p><b>Logged in as: <a href=\"x\">brokendog</a></b></p></div>"#
        #expect(try ProfileParser.parseNew(body).displayName == "brokendog")
        #expect(try ProfileParser.parseNew("ERR_CONNECTION_REFUSED").displayName == nil)
    }

    @Test func forums() throws {
        let html = """
        <div id="userlinks"><p class="home"><b>Logged in as: <a href="https://forums.e-hentai.org/index.php?showuser=6254716">brokendog</a></b></p></div>
        """
        #expect(try ForumsParser.parse(html) == "https://forums.e-hentai.org/index.php?showuser=6254716")
        #expect(throws: EhError.self) { try ForumsParser.parse("<html></html>") }
    }

    @Test func signIn() throws {
        #expect(try SignInParser.parse("<p>You are now logged in as: brokendog<br>") == "brokendog")
        #expect(throws: EhError.server("Username or password incorrect")) {
            try SignInParser.parse("<h4>The error returned was:</h4>\n<p>Username or password incorrect</p>")
        }
        #expect(throws: EhError.server("Captcha wrong")) {
            try SignInParser.parse("<span class=\"postcolor\">Captcha wrong</span>")
        }
        #expect(throws: EhError.self) { try SignInParser.parse("<html></html>") }
    }
}
