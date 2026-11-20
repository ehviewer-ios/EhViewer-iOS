import Testing
@testable import EhCore

@Suite struct GalleryTokenApiParserTests {
    @Test func token() throws {
        #expect(try GalleryTokenApiParser.parse(#"{"tokenlist":[{"gid":618395,"token":"0439fa3666"}]}"#) == "0439fa3666")
    }

    @Test func error() {
        #expect(throws: EhError.server("maximum 25 entries")) {
            try GalleryTokenApiParser.parse(#"{"tokenlist":[{"gid":1,"error":"maximum 25 entries"}]}"#)
        }
        #expect(throws: EhError.self) { try GalleryTokenApiParser.parse(#"{"tokenlist":[]}"#) }
    }
}
