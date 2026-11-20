import Testing
@testable import EhCore

/// 移植自 Android GalleryDetailUrlParserTest
@Suite struct GalleryDetailUrlParserTests {
    struct Case: Sendable, CustomStringConvertible {
        let url: String, strict: Bool, isNull: Bool, gid: Int64, token: String?
        var description: String { "\(url) strict=\(strict)" }
    }

    static let cases: [Case] = [
        .init(url: "https://e-hentai.org/g/530350/8b3c7e4a21/", strict: true, isNull: false, gid: 530350, token: "8b3c7e4a21"),
        .init(url: "https://exhentai.org/g/530350/8b3c7e4a21/", strict: true, isNull: false, gid: 530350, token: "8b3c7e4a21"),
        .init(url: "https://lofi.e-hentai.org/g/530350/8b3c7e4a21/", strict: true, isNull: false, gid: 530350, token: "8b3c7e4a21"),
        .init(url: "https://e-hentai.org/mpv/530350/8b3c7e4a21/", strict: true, isNull: false, gid: 530350, token: "8b3c7e4a21"),
        .init(url: "https://exhentai.org/mpv/530350/8b3c7e4a21/", strict: true, isNull: false, gid: 530350, token: "8b3c7e4a21"),
        .init(url: "https://lofi.e-hentai.org/mpv/530350/8b3c7e4a21/", strict: true, isNull: false, gid: 530350, token: "8b3c7e4a21"),
        .init(url: "https://e-hentai.org/mpv/530350/8b3c7e4a21/#page1", strict: true, isNull: false, gid: 530350, token: "8b3c7e4a21"),
        .init(url: "530350/8b3c7e4a21/#page1", strict: true, isNull: true, gid: 0, token: nil),
        .init(url: "530350/8b3c7e4a21", strict: false, isNull: false, gid: 530350, token: "8b3c7e4a21"),
        .init(url: "g/530350/8b3c7e4a21", strict: false, isNull: false, gid: 530350, token: "8b3c7e4a21"),
        .init(url: "530350b/8b3c7e4a21", strict: false, isNull: true, gid: 0, token: nil),
        .init(url: "530350/8b3c7e4a211", strict: false, isNull: true, gid: 0, token: nil),
    ]

    @Test(arguments: cases)
    func parse(_ c: Case) {
        let r = GalleryDetailUrlParser.parse(c.url, strict: c.strict)
        if c.isNull {
            #expect(r == nil)
        } else {
            #expect(r?.gid == c.gid)
            #expect(r?.token == c.token)
        }
    }

    @Test func nilInput() {
        #expect(GalleryDetailUrlParser.parse(nil) == nil)
    }
}
