import Foundation
import Testing
@testable import EhCore

@Suite struct ComicInfoParserTests {
    static let sample = """
    <?xml version='1.0' encoding='UTF-8' ?>
    <ComicInfo>
      <Series>Sanitized Sample Gallery</Series>
      <Web>https://exhentai.org/g/900000002/0000000000</Web>
      <PageCount>77</PageCount>
    </ComicInfo>

    """

    @Test func readsGidAndTokenFromWeb() throws {
        let r = try #require(ComicInfoParser.parse(Self.sample))
        #expect(r.gid == 900_000_002)
        #expect(r.token == "0000000000")
        #expect(ComicInfoParser.parseWebUrl(Self.sample) == "https://exhentai.org/g/900000002/0000000000")
    }

    @Test func readsFromData() throws {
        let r = try #require(ComicInfoParser.parse(data: Data(Self.sample.utf8)))
        #expect(r.gid == 900_000_002)
        #expect(r.token == "0000000000")
        #expect(ComicInfoParser.parse(data: Data(count: 256 * 1024 + 1)) == nil)
    }

    @Test func returnsNilWithoutWeb() {
        #expect(ComicInfoParser.parse("<ComicInfo><Series>Only a title</Series></ComicInfo>") == nil)
        #expect(ComicInfoParser.parse("") == nil)
        #expect(ComicInfoParser.parse(nil as String?) == nil)
    }
}
