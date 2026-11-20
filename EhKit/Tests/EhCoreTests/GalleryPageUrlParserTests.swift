import Testing
@testable import EhCore

/// 移植自 Android GalleryPageUrlParserTest
@Suite struct GalleryPageUrlParserTests {
    struct Case: Sendable, CustomStringConvertible {
        let url: String, strict: Bool, isNull: Bool, gid: Int64, pToken: String?, page: Int
        var description: String { "\(url) strict=\(strict)" }
    }

    static let cases: [Case] = [
        .init(url: "https://e-hentai.org/s/7b87643838/530350-1", strict: true, isNull: false, gid: 530350, pToken: "7b87643838", page: 0),
        .init(url: "https://exhentai.org/s/7b87643838/530350-1", strict: true, isNull: false, gid: 530350, pToken: "7b87643838", page: 0),
        .init(url: "7b87643838/530350-1", strict: true, isNull: true, gid: 0, pToken: nil, page: 0),
        .init(url: "7b87643838/530350-1", strict: false, isNull: false, gid: 530350, pToken: "7b87643838", page: 0),
        .init(url: "s/7b87643838/530350-1", strict: false, isNull: false, gid: 530350, pToken: "7b87643838", page: 0),
        .init(url: "7b87643838/530350a-1", strict: false, isNull: true, gid: 0, pToken: nil, page: 0),
        .init(url: "https://e-hentai.org/s/7b87643838/530350-12", strict: true, isNull: false, gid: 530350, pToken: "7b87643838", page: 11),
        .init(url: "https://e-hentai.org/s/7b87643838/530350-0", strict: true, isNull: true, gid: 0, pToken: nil, page: 0),
    ]

    @Test(arguments: cases)
    func parse(_ c: Case) {
        let r = GalleryPageUrlParser.parse(c.url, strict: c.strict)
        if c.isNull {
            #expect(r == nil)
        } else {
            #expect(r?.gid == c.gid)
            #expect(r?.pToken == c.pToken)
            #expect(r?.page == c.page)
        }
    }
}
