import Foundation
import Testing
@testable import EhCore

// MARK: - 测试用最小 CBOR 编码器

private indirect enum C {
    case u(UInt64), n(Int64), t(String), b([UInt8]), a([C]), m([(C, C)])
    case im([(C, C)]) // 不定长 map
    case it([String]) // 不定长文本
    case raw([UInt8])

    var bytes: [UInt8] {
        switch self {
        case let .u(v): return Self.head(0, v)
        case let .n(v): return Self.head(1, UInt64(-1 - v))
        case let .t(s): return Self.head(3, UInt64(s.utf8.count)) + Array(s.utf8)
        case let .b(d): return Self.head(2, UInt64(d.count)) + d
        case let .a(items): return Self.head(4, UInt64(items.count)) + items.flatMap(\.bytes)
        case let .m(entries): return Self.head(5, UInt64(entries.count)) + entries.flatMap { $0.0.bytes + $0.1.bytes }
        case let .im(entries): return [0xBF] + entries.flatMap { $0.0.bytes + $0.1.bytes } + [0xFF]
        case let .it(chunks): return [0x7F] + chunks.flatMap { C.t($0).bytes } + [0xFF]
        case let .raw(r): return r
        }
    }

    static func head(_ major: UInt8, _ v: UInt64) -> [UInt8] {
        let m = major << 5
        switch v {
        case 0 ..< 24: return [m | UInt8(v)]
        case 24 ..< 0x100: return [m | 24, UInt8(v)]
        case 0x100 ..< 0x10000: return [m | 25, UInt8(v >> 8), UInt8(v & 0xFF)]
        case 0x10000 ..< 0x1_0000_0000: return [m | 26] + (0 ..< 4).reversed().map { UInt8((v >> (8 * UInt64($0))) & 0xFF) }
        default: return [m | 27] + (0 ..< 8).reversed().map { UInt8((v >> (8 * UInt64($0))) & 0xFF) }
        }
    }
}

private func data(_ c: C) -> Data { Data(c.bytes) }

/// Android SpiderInfoTest 中 `.cursor/cache/02-cbor/.ehviewer` 的原始字节
private let androidCborIndefinite: [UInt8] = [
    0xBF, 0x63, 0x67, 0x69, 0x64, 0x1A, 0x35, 0xA4, 0xE9, 0x02,
    0x65, 0x74, 0x6F, 0x6B, 0x65, 0x6E, 0x6A, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30,
    0x30, 0x30, 0x30, 0x30, 0x65, 0x70, 0x61, 0x67, 0x65, 0x73, 0x18, 0x4D, 0x69,
    0x70, 0x54, 0x6F, 0x6B, 0x65, 0x6E, 0x4D, 0x61, 0x70, 0xBF, 0x00, 0x6A,
    0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x31, 0xFF, 0x6C,
    0x70, 0x72, 0x65, 0x76, 0x69, 0x65, 0x77, 0x50, 0x61, 0x67, 0x65, 0x73, 0x02,
    0x6E, 0x70, 0x72, 0x65, 0x76, 0x69, 0x65, 0x77, 0x50, 0x65, 0x72, 0x50, 0x61,
    0x67, 0x65, 0x18, 0x28, 0xFF,
]

private let androidCborDefinite: [UInt8] = [
    0xA2, 0x63, 0x67, 0x69, 0x64, 0x1A, 0x35, 0xA4, 0xE9, 0x02,
    0x65, 0x74, 0x6F, 0x6B, 0x65, 0x6E, 0x6A, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30,
    0x30, 0x30, 0x30, 0x30,
]

private let validHeader = "VERSION2\n00000000\n123456\nabcdef01\n1\n2\n20\n3\n"

@Suite struct SpiderInfoTextTests {
    // 移植自 Android SpiderInfoTest
    @Test func tryParsePTokenLineAcceptsValidLine() {
        let r = SpiderInfo.tryParsePTokenLine("0 token0")
        #expect(r?.index == 0)
        #expect(r?.pToken == "token0")
    }

    @Test func tryParsePTokenLineSkipsCorruptIndex() {
        #expect(SpiderInfo.tryParsePTokenLine("abc badtoken") == nil)
    }

    @Test func tryParsePTokenLineSkipsMalformed() {
        #expect(SpiderInfo.tryParsePTokenLine("notoken") == nil)
        #expect(SpiderInfo.tryParsePTokenLine("") == nil)
        #expect(SpiderInfo.tryParsePTokenLine("1 ") == nil)
        #expect(SpiderInfo.tryParsePTokenLine(" x") == nil)
        #expect(SpiderInfo.tryParsePTokenLine("1 " + String(repeating: "a", count: 1025)) == nil)
    }

    @Test func corruptLineDoesNotPreventLaterLines() throws {
        let content = validHeader + "0 token0\nabc badtoken\n2 token2\n"
        let info = try #require(SpiderInfo.read(Data(content.utf8)))
        #expect(info.gid == 123_456)
        #expect(info.token == "abcdef01")
        #expect(info.startPage == 0)
        #expect(info.previewPages == 2)
        #expect(info.previewPerPage == 20)
        #expect(info.pages == 3)
        #expect(info.pTokenMap == [0: "token0", 2: "token2"])
    }

    @Test func headerOnlySkipsPTokens() throws {
        let content = validHeader + "0 token0\n"
        let info = try #require(SpiderInfo.readHeader(Data(content.utf8)))
        #expect(info.pTokenMap.isEmpty)
        #expect(info.pages == 3)
    }

    @Test func versionOneFormat() throws {
        // v1：无 VERSION 行；第 7 行被读取但不作为 previewPerPage
        let content = "0000000a\n42\ntok\n1\n5\n40\n10\n3 p3\n"
        let info = try #require(SpiderInfo.read(Data(content.utf8)))
        #expect(info.startPage == 10)
        #expect(info.gid == 42)
        #expect(info.token == "tok")
        #expect(info.previewPages == 5)
        #expect(info.previewPerPage == -1)
        #expect(info.pages == 10)
        #expect(info.pTokenMap == [3: "p3"])
    }

    @Test func crlfAndLastLineWithoutNewline() throws {
        let content = "VERSION2\r\n0000000f\r\n7\r\nT\r\n1\r\n1\r\n40\r\n2\r\n0 a\r\n1 b"
        let info = try #require(SpiderInfo.read(Data(content.utf8)))
        #expect(info.startPage == 15)
        #expect(info.token == "T")
        // 与 Java readAsciiLine 一致：最后一行没有换行会遇到 EOF 被丢弃
        #expect(info.pTokenMap == [0: "a"])
    }

    @Test func rejectsInvalid() {
        #expect(SpiderInfo.read(Data("INVALID_FORMAT".utf8)) == nil)
        #expect(SpiderInfo.read(Data()) == nil)
        #expect(SpiderInfo.read(Data("VERSION3\n0\n1\nt\n1\n1\n1\n1\n".utf8)) == nil)
        // pages 越界
        #expect(SpiderInfo.read(Data("VERSION2\n0\n1\nt\n1\n1\n1\n0\n".utf8)) == nil)
        #expect(SpiderInfo.read(Data("VERSION2\n0\n1\nt\n1\n1\n1\n100001\n".utf8)) == nil)
        // gid 非数字
        #expect(SpiderInfo.read(Data("VERSION2\n0\nx\nt\n1\n1\n1\n1\n".utf8)) == nil)
        // 头部截断
        #expect(SpiderInfo.read(Data("VERSION2\n0\n1\nt\n".utf8)) == nil)
        // pToken 行过长 → IOException → 整体失败（与 Android 一致）
        let long = validHeader + "0 " + String(repeating: "x", count: 3000) + "\n"
        #expect(SpiderInfo.read(Data(long.utf8)) == nil)
        #expect(SpiderInfo.readHeader(Data(long.utf8)) != nil)
    }

    @Test func startPageHexParsing() {
        #expect(SpiderInfo.getStartPage("00000000") == 0)
        #expect(SpiderInfo.getStartPage("000000ff") == 255)
        #expect(SpiderInfo.getStartPage("1g") == 16) // 非 hex 字符只乘 16
        #expect(SpiderInfo.getStartPage(nil) == 0)
        #expect(SpiderInfo.getStartPage("ffffffff") == 0) // 溢出为负 → 0
    }

    @Test func writeRoundTrip() throws {
        var info = SpiderInfo(startPage: 26, gid: 2_345_678, token: "0123456789", pages: 4,
                              previewPages: 1, previewPerPage: 40)
        info.pTokenMap = [3: "ddd", 0: "aaa", 1: SpiderInfo.tokenFailed, 2: ""]
        let text = String(decoding: info.textData(), as: UTF8.self)
        #expect(text == "VERSION2\n0000001a\n2345678\n0123456789\n1\n1\n40\n4\n0 aaa\n3 ddd\n")
        let back = try #require(SpiderInfo.read(info.textData()))
        #expect(back.startPage == 26)
        #expect(back.gid == 2_345_678)
        #expect(back.pTokenMap == [0: "aaa", 3: "ddd"])
        #expect(SpiderInfo.detectFormat(info.textData()) == .text(version: 0))
    }

    @Test func writeAndReadFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("spider-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(SpiderNaming.spiderInfoFilename)
        let info = SpiderInfo(gid: 1, token: "t", pages: 1, pTokenMap: [0: "p"])
        try info.write(to: url)
        #expect(SpiderInfo.read(contentsOf: url)?.pTokenMap == [0: "p"])
    }
}

@Suite struct SpiderInfoCborTests {
    // 移植自 Android SpiderInfoTest.readCborHeader_readsGidAndTokenFromIndefiniteMap
    @Test func androidIndefiniteMapReadsAllFields() throws {
        let d = Data(androidCborIndefinite)
        #expect(SpiderInfo.detectFormat(d) == .cbor)
        let info = try #require(SpiderInfo.read(d))
        #expect(info.gid == 900_000_002)
        #expect(info.token == "0000000000")
        #expect(info.pages == 77)
        #expect(info.pTokenMap == [0: "0000000001"])
        #expect(info.previewPages == 2)
        #expect(info.previewPerPage == 40)
        #expect(info.startPage == 0)
        // 文本解析器不能读 CBOR
        #expect(SpiderInfo.readText(d) == nil)
        // 只读头部时跳过 pTokenMap
        let header = try #require(SpiderInfo.readHeader(d))
        #expect(header.pTokenMap.isEmpty)
        #expect(header.previewPerPage == 40)
    }

    @Test func androidDefiniteMap() throws {
        let info = try #require(SpiderInfo.readCbor(Data(androidCborDefinite)))
        #expect(info.gid == 900_000_002)
        #expect(info.token == "0000000000")
        #expect(info.pages == -1)
    }

    @Test func rejectsInvalid() {
        #expect(SpiderInfo.readCbor(Data("INVALID_FORMAT".utf8)) == nil)
        // 缺 token
        #expect(SpiderInfo.read(data(.m([(.t("gid"), .u(1))]))) == nil)
        // gid 为负
        #expect(SpiderInfo.read(data(.m([(.t("gid"), .n(-5)), (.t("token"), .t("x"))]))) == nil)
        // 空 token
        #expect(SpiderInfo.read(data(.m([(.t("gid"), .u(1)), (.t("token"), .t(""))]))) == nil)
        // 顶层不是 map
        #expect(SpiderInfo.readCbor(data(.a([.u(1)]))) == nil)
    }

    @Test func fullFieldsWithUnknownAndStartPage() throws {
        let c = C.m([
            (.t("gid"), .u(3_000_000)),
            (.t("unknownNested"), .m([(.t("x"), .a([.u(1), .b([1, 2, 3]), .m([])]))])),
            (.t("token"), .t("abcdef0123")),
            (.t("pages"), .u(300)),
            (.t("pTokenMap"), .m([(.u(0), .t("p0")), (.u(299), .t("p299")), (.t("5"), .t("p5")), (.u(7), .u(1))])),
            (.t("startPage"), .u(12)),
            (.t("previewPages"), .u(8)),
            (.t("previewPerPage"), .u(40)),
            (.raw([0xF9, 0x3C, 0x00]), .raw([0xFB, 0x40, 0x09, 0x21, 0xFB, 0x54, 0x44, 0x2D, 0x18])), // 1.0 → π
        ])
        let info = try #require(SpiderInfo.read(data(c)))
        #expect(info.gid == 3_000_000)
        #expect(info.token == "abcdef0123")
        #expect(info.pages == 300)
        #expect(info.startPage == 12)
        #expect(info.previewPages == 8)
        #expect(info.previewPerPage == 40)
        #expect(info.pTokenMap == [0: "p0", 299: "p299", 5: "p5"])
        // CBOR 读出后可写为文本格式，再被读回
        let back = try #require(SpiderInfo.read(info.textData()))
        #expect(back.pTokenMap == info.pTokenMap)
        #expect(back.startPage == 12)
    }

    @Test func indefiniteTextToken() throws {
        let info = try #require(SpiderInfo.read(data(.im([(.t("gid"), .u(9)), (.t("token"), .it(["ab", "cd"]))]))))
        #expect(info.token == "abcd")
    }

    @Test func partialAfterGidAndTokenIsKept() throws {
        // 与 Android 一致：gid/token 之后的内容损坏时，仍返回已读字段
        var bytes = C.im([(.t("gid"), .u(5)), (.t("token"), .t("tok")), (.t("pages"), .u(3))]).bytes
        bytes.removeLast() // 去掉 break
        bytes += C.t("pTokenMap").bytes + [0xBF, 0x00] // 截断
        let info = try #require(SpiderInfo.read(Data(bytes)))
        #expect(info.gid == 5)
        #expect(info.token == "tok")
        #expect(info.pages == 3)
        #expect(info.pTokenMap.isEmpty)
    }

    @Test func tooDeepIsRejectedButHeaderKept() throws {
        var nested = C.a([])
        for _ in 0 ..< 40 { nested = .a([nested]) }
        let c = C.m([(.t("gid"), .u(1)), (.t("token"), .t("t")), (.t("deep"), nested)])
        let info = try #require(SpiderInfo.read(data(c)))
        #expect(info.gid == 1)
        var reader = CBORReader(Data(nested.bytes))
        #expect(throws: CBORError.tooDeep) { try reader.readValue() }
    }

    @Test func cborReaderDecodesScalars() throws {
        var r = CBORReader(bytes: [0xF9, 0x3C, 0x00, 0xFA, 0x3F, 0xC0, 0x00, 0x00, 0xF5, 0xF6, 0x38, 0x63, 0xC1, 0x1A, 0x00, 0x00, 0x00, 0x01])
        #expect(try r.readValue() == .float(1.0))
        #expect(try r.readValue() == .float(1.5))
        #expect(try r.readValue() == .bool(true))
        #expect(try r.readValue() == .null)
        #expect(try r.readValue().int64Value == -100)
        let tagged = try r.readValue()
        #expect(tagged == .tagged(1, .unsigned(1)))
        #expect(tagged.int64Value == 1)
        #expect(r.isAtEnd)
        var t = CBORReader(bytes: [0x62, 0x61])
        #expect(throws: CBORError.truncated) { try t.readValue() }
        #expect(CBORReader.halfToDouble(0x7C00) == .infinity)
        #expect(CBORReader.halfToDouble(0x0001) == pow(2, -24))
    }
}

@Suite struct SpiderNamingTests {
    @Test func sanitizeFilename() {
        #expect(SpiderNaming.sanitizeFilename("a/b\\c:d*e?f\"g<h>i|j") == "abcdefghij")
        #expect(SpiderNaming.sanitizeFilename(" \u{3000}\tname\u{00A0} ") == "name")
        let long = String(repeating: "中", count: 100) // 300 字节
        let s = SpiderNaming.sanitizeFilename(long)
        #expect(s.utf8.count == 255)
        let emoji = String(repeating: "a", count: 253) + "😀"
        #expect(SpiderNaming.sanitizeFilename(emoji) == String(repeating: "a", count: 253))
    }

    @Test func downloadDirname() {
        let info = GalleryInfo(gid: 123, token: "t", title: "[Group] Title: Sub/Part", titleJpn: "日本語")
        #expect(SpiderNaming.downloadDirname(for: info, preferJapanese: false) == "123-[Group] Title SubPart")
        #expect(SpiderNaming.downloadDirname(for: info, preferJapanese: true) == "123-日本語")
        let noJpn = GalleryInfo(gid: 1, title: "T", titleJpn: "")
        #expect(SpiderNaming.downloadDirname(for: noJpn, preferJapanese: true) == "1-T")
        #expect(SpiderNaming.pickExistingDirname(gid: 12, candidates: ["12-a", "12-abc", "123-zzzzzz", "x"]) == "12-abc")
        #expect(SpiderNaming.pickExistingDirname(gid: 9, candidates: ["12-a"]) == nil)
    }

    @Test func imageFilenames() {
        #expect(SpiderNaming.imageFilename(index: 0, extension: ".jpg") == "00000001.jpg")
        #expect(SpiderNaming.imageFilename(index: 122, extension: ".png") == "00000123.png")
        #expect(SpiderNaming.imageFilenameCandidates(index: 1).first == "00000002.jpg")
        #expect(SpiderNaming.imageFilenameCandidates(index: 1).count == 5)
        #expect(SpiderNaming.fixExtension(".bmp") == ".jpg")
        #expect(SpiderNaming.fixExtension(".webp") == ".webp")
        #expect(SpiderNaming.imageExtension(forMimeType: "image/jpeg") == ".jpg")
        #expect(SpiderNaming.imageExtension(forMimeType: "image/bmp") == ".jpg")
        #expect(SpiderNaming.imageExtension(forMimeType: "text/html") == nil)
        #expect(SpiderNaming.imageIndex(fromFilename: "00000123.png") == 122)
        #expect(SpiderNaming.imageIndex(fromFilename: "00000000.png") == nil)
        #expect(SpiderNaming.imageIndex(fromFilename: "123.png") == nil)
        #expect(SpiderNaming.imageIndex(fromFilename: ".ehviewer") == nil)
    }

    @Test func findImageAndTimestamp() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("naming-\(UUID())")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        try Data([1]).write(to: dir.appendingPathComponent("00000003.webp"))
        try fm.createDirectory(at: dir.appendingPathComponent("77-Title"), withIntermediateDirectories: true)
        try Data([1]).write(to: dir.appendingPathComponent("77-Title-longer-but-file"))
        #expect(SpiderNaming.findImageFile(in: dir, index: 2)?.lastPathComponent == "00000003.webp")
        #expect(SpiderNaming.findImageFile(in: dir, index: 0) == nil)
        #expect(SpiderNaming.findExistingDirname(gid: 77, in: dir) == "77-Title")
        #expect(SpiderNaming.galleryDirectoryTimestamp(dir, fallbackTime: 5) > 1_000_000_000_000)
        #expect(SpiderNaming.galleryDirectoryTimestamp(nil, fallbackTime: 5) == 5)
        #expect(SpiderNaming.galleryDirectoryTimestamp(dir.appendingPathComponent("none"), fallbackTime: -3) == 0)
    }
}
