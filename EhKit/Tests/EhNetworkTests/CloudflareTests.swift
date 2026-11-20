import Foundation
import Testing
@testable import EhNetwork

@Suite struct CloudflareTests {
    private func response(_ status: Int, _ body: String, headers: [(String, String)] = [("Content-Type", "text/html")]) -> EhHTTPResponse {
        EhHTTPResponse(status: status, headers: HTTPHeaders(headers), body: Data(body.utf8),
                       url: URL(string: "https://forums.e-hentai.org/index.php?act=Login&CODE=01")!)
    }

    @Test func detectsManagedChallengePage() {
        let r = response(403, "<!DOCTYPE html><html><head><title>Just a moment...</title></head><body><script>window._cf_chl_opt={}</script></body></html>")
        #expect(EhResponseValidator.isCloudflareChallenge(r))
        #expect(throws: EhError.cloudflareChallenge("forums.e-hentai.org")) { try EhResponseValidator.validate(r) }
    }

    @Test func detectsByHeader() {
        let r = response(403, "", headers: [("cf-mitigated", "challenge")])
        #expect(EhResponseValidator.isCloudflareChallenge(r))
    }

    @Test func ordinaryForbiddenIsNotChallenge() {
        #expect(!EhResponseValidator.isCloudflareChallenge(response(403, "<html>Forbidden</html>")))
        #expect(!EhResponseValidator.isCloudflareChallenge(response(200, "<title>Just a moment...</title>")))
    }

    @Test func engineErrorsMapParseFailureToChallenge() {
        let r = response(403, "<title>Just a moment...</title><script>_cf_chl_opt</script>")
        let mapped = EhEngineErrors.map(EhError.parse("Can't parse sign in"), response: r, body: r.text)
        #expect((mapped as? EhError) == .cloudflareChallenge("forums.e-hentai.org"))
    }
}
