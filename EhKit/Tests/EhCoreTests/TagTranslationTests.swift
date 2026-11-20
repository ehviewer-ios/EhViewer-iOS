import Foundation
import Testing
@testable import EhCore

@Suite struct TagTranslationTests {
    /// 4 字节大端长度 + 正文
    static func pack(_ text: String) -> Data {
        let body = Data(text.utf8)
        let n = UInt32(body.count)
        return Data([UInt8(n >> 24), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)]) + body
    }

    /// 与 Android 测试资源 `EhTagDatabaseTest` 字节完全相同
    static let androidResource = pack(
        "1\rYQ==\n12\rYWI=\n123\rYWJj\n1234\rYWJjZA==\na\rMQ==\nab\rMTI=\nabc\rMTIz\nabcd\rMTIzNA==\n")

    @Test func readTheList() throws {
        #expect(Self.androidResource.count == 80)
        let db = try TagTranslation(name: "EhTagDatabaseTest", data: Self.androidResource)
        #expect(db.getTranslation("1") == "a")
        #expect(db.getTranslation("12") == "ab")
        #expect(db.getTranslation("123") == "abc")
        #expect(db.getTranslation("1234") == "abcd")
        #expect(db.getTranslation("a") == "1")
        #expect(db.getTranslation("ab") == "12")
        #expect(db.getTranslation("abc") == "123")
        #expect(db.getTranslation("abcd") == "1234")
        #expect(db.getTranslation("21") == nil)
        #expect(db.getTranslation("") == nil)
        #expect(db.getTranslation("zzzz") == nil)
        #expect(db.tagList.count == 8)
    }

    @Test func locationNamespaceMapsToLocPrefix() {
        #expect(TagTranslation.namespaceToPrefix("location") == "loc:")
        #expect(TagTranslation.prefixToNamespace("loc:") == "location")
        #expect(TagTranslation.namespaceToPrefix("f") == "f")
        #expect(TagTranslation.namespaceToPrefix("unknown") == nil)
    }

    @Test func locPrefixLooksUpAndSuggestsFullNamespace() throws {
        let line = "loc:beach\r" + Data("沙滩".utf8).base64EncodedString() + "\n"
        let db = try TagTranslation(name: "location-test", data: Self.pack(line))
        #expect(db.getTranslation("loc:beach") == "沙滩")
        let hints = db.suggest("location:beach")
        #expect(hints.count == 1)
        #expect(hints.first?.chinese == "沙滩")
        #expect(hints.first?.english == "location:beach")
        #expect(db.suggest("沙").count == 1)
    }

    @Test func suggestLimit() throws {
        let text = (0..<60).map { String(format: "f:tag%02d\r", $0) + Data("标签".utf8).base64EncodedString() + "\n" }.joined()
        let db = try TagTranslation(name: "many", data: Self.pack(text))
        #expect(db.suggest("female:tag").count == 40)
        #expect(db.getTranslation("f:tag37") == "标签")
        #expect(db.getTranslation("f:tag60") == nil)
    }

    @Test func tagCN() throws {
        let text = "f:big breasts\r" + Data("巨乳".utf8).base64EncodedString() + "\n"
            + "loc:beach\r" + Data("沙滩".utf8).base64EncodedString() + "\n"
            + "n:female\r" + Data("女性".utf8).base64EncodedString() + "\n"
        let db = try TagTranslation(name: "cn", data: Self.pack(text))
        #expect(TagTranslation.getTagCN("female:big breasts", db) == "女性:巨乳")
        #expect(TagTranslation.getTagCN("f:big breasts", db) == "女性:巨乳")
        #expect(TagTranslation.getTagCN("location:beach", db) == "location:沙滩")
        #expect(TagTranslation.getTagCN("female:unknown", db) == "女性:unknown")
        #expect(TagTranslation.getTagCN("a:b:c", db) == "a:b:c")
        #expect(TagTranslation.getTagCN("female:big breasts", nil) == "female:big breasts")
        #expect(TagTranslation.getTagCNBody(["loc", "beach"], db) == "沙滩")
        #expect(TagTranslation.getTagCNBody(["x", "y"], db) == "y")
    }

    @Test func truncatedData() {
        #expect(throws: EhError.self) { try TagTranslation(name: "x", data: Data([0, 0, 0, 9, 65])) }
        #expect(throws: EhError.self) { try TagTranslation(name: "x", data: Data([0, 0])) }
    }

    @Test func sha1Vectors() {
        #expect(SHA1.hexString(Data()) == "da39a3ee5e6b4b0d3255bfef95601890afd80709")
        #expect(SHA1.hexString(Data("abc".utf8)) == "a9993e364706816aba3e25717850c26c9cd0d89d")
        #expect(SHA1.hexString(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8))
            == "84983e441c3bd26ebaae4aa1f95129e5e54670f1")
        #expect(SHA1.hexString(Data(repeating: UInt8(ascii: "a"), count: 1_000_000))
            == "34aa973cd4c4daa4f61eeb2bdbad27316534016f")
        // 分块 update 与一次性结果一致
        var s = SHA1()
        let d = Data((0..<1000).map { UInt8($0 & 0xFF) })
        for chunk in stride(from: 0, to: d.count, by: 37) {
            s.update(d.subdata(in: chunk..<min(chunk + 37, d.count)))
        }
        #expect(s.finalize() == SHA1.hash(d))
    }

    @Test func checkData() {
        let data = Self.androidResource
        let sha = SHA1.hash(data)
        #expect(TagTranslation.checkData(sha1: sha, data: data))
        #expect(!TagTranslation.checkData(sha1: sha, data: data + Data([0])))
        #expect(!TagTranslation.checkData(sha1: Data(), data: data))
    }

    @Test func metadata() {
        #expect(TagTranslation.Metadata.default.dataName == "tag-translations-zh-rCN")
        #expect(TagTranslation.Metadata.default.sha1Url.hasSuffix("tag-translations-zh-rCN.sha1"))
    }
}
