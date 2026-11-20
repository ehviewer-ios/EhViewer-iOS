import Foundation
import Testing
@testable import EhCore

func makeTransferTempDir(_ name: String = #function) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("eh-transfer-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite struct TransferMigrationTests {
    // MARK: - 数据 JSON（与 Android toJson / fromJson 字段一致）

    @Test func galleryInfoJsonMatchesAndroidKeys() throws {
        let info = GalleryInfo(gid: 123, token: "abc", title: "T", titleJpn: nil, thumb: "https://t/1.jpg",
                               category: .manga, posted: "2020-01-01 00:00", uploader: "u", rating: 4.3,
                               rated: true, simpleTags: ["a", "b"], pages: 20, thumbWidth: 250, thumbHeight: 350,
                               simpleLanguage: "ZH", favoriteSlot: 2, favoriteName: "Fav 2", tgList: ["f:x"])
        let o = info.transferJSON
        #expect(Set(o.keys) == ["gid", "token", "title", "thumb", "category", "posted", "uploader", "rating",
                                "rated", "simpleLanguage", "simpleTags", "thumbHeight", "thumbWidth",
                                "spanSize", "spanIndex", "spanGroupIndex", "favoriteSlot", "favoriteName",
                                "tgList", "pages"])
        #expect(o["titleJpn"] == nil)  // null 省略
        #expect(o["category"] == .int(4))
        #expect(o["rating"]?.jsonString() == "4.3")
        #expect(o["tgList"] == .array([.array([.string("f:x")])]))
        #expect(GalleryInfo(gid: 1).transferJSON["tgList"] == .array([.null]))
        // rated / rating 必须写出（Android 读取 null 会 NPE）
        #expect(GalleryInfo(gid: 1).transferJSON["rated"] == .bool(false))
        #expect(GalleryInfo(gid: 1).transferJSON["rating"] != nil)

        let back = GalleryInfo(transferJSON: o)
        #expect(back == info)
    }

    @Test func galleryInfoFromAndroidJson() throws {
        // fastjson 输出样例（键顺序任意，tgList 为 [[…]]，无 simpleLanguage 时缺省）
        let json = #"""
        {"rated":false,"thumb":"https://ehgt.org/t.jpg","gid":2345678,"thumbWidth":0,"pages":0,"title":"Title",
         "spanSize":0,"category":2,"token":"0123abcd","uploader":"up","favoriteSlot":-2,"spanGroupIndex":0,
         "rating":4.5,"spanIndex":0,"thumbHeight":0,"posted":"2024-05-01 12:00","tgList":[null],
         "simpleTags":["language:chinese"],"time":1700000000000}
        """#
        let o = try #require(try TransferJSON.parse(Data(json.utf8)).objectValue)
        let info = GalleryInfo(transferJSON: o)
        #expect(info.gid == 2_345_678)
        #expect(info.token == "0123abcd")
        #expect(info.category == .doujinshi)
        #expect(info.rating == 4.5)
        #expect(info.rated == false)
        #expect(info.favoriteSlot == -2)
        #expect(info.simpleTags == ["language:chinese"])
        #expect(info.tgList == nil)
        #expect(info.titleJpn == nil)
        #expect(info.simpleLanguage == nil)
        #expect(info.posted == "2024-05-01 12:00")
    }

    @Test func quickSearchJsonRoundTrip() throws {
        let q = TransferQuickSearch(name: "n", mode: 1, category: 0x3FF, keyword: "artist:x", advanceSearch: 7,
                                    minRating: 3, pageFrom: 10, pageTo: -1, time: 1_700_000_000_000)
        let o = q.transferJSON
        #expect(Set(o.keys) == ["name", "mode", "category", "keyword", "advanceSearch", "minRating",
                                "pageFrom", "pageTo", "time"])
        #expect(TransferQuickSearch(transferJSON: o) == q)
        // 缺失字段 getIntValue → 0（不是模型默认的 -1）
        let partial = TransferQuickSearch(transferJSON: ["name": .string("a")])
        #expect(partial.pageFrom == 0 && partial.pageTo == 0 && partial.keyword == nil)
        // 经过 JSON 文本再解析
        let parsed = try TransferJSON.parse(Data(TransferJSON.object(o).jsonString().utf8))
        #expect(TransferQuickSearch(transferJSON: try #require(parsed.objectValue)) == q)
    }

    @Test func downloadItemJson() throws {
        let item = TransferDownloadItem(info: GalleryInfo(gid: 9, token: "t", title: "x"), finished: 3, legacy: 1,
                                        label: "L", downloaded: 2, remaining: 100, speed: 5, state: 3,
                                        time: 1234, total: 10, archiveUri: nil)
        let o = item.transferJSON
        for k in ["finished", "legacy", "label", "downloaded", "remaining", "speed", "state", "time", "total", "gid"] {
            #expect(o[k] != nil, "missing \(k)")
        }
        #expect(o["archiveUri"] == nil)
        #expect(TransferDownloadItem(transferJSON: o) == item)

        let h = TransferHistoryItem(info: GalleryInfo(gid: 5, token: "a"), mode: 1, time: 99)
        #expect(TransferHistoryItem(transferJSON: h.transferJSON) == h)
    }

    @Test func kindsFromDataType() throws {
        #expect(TransferDataKind(dataType: 1001) == .quickSearch)
        #expect(TransferDataKind(dataType: 1002) == .download)
        #expect(TransferDataKind(dataType: 1003) == .download)
        #expect(TransferDataKind(dataType: 1004) == .favorite)
        #expect(TransferDataKind(dataType: 1007) == .downloadDir)
        #expect(TransferDataKind(dataType: 1008) == .history)
        #expect(TransferDataKind(dataType: 1) == nil)
        #expect(TransferEngine.pageCount(0, pageSize: 10) == 0)
        #expect(TransferEngine.pageCount(10, pageSize: 10) == 1)
        #expect(TransferEngine.pageCount(11, pageSize: 10) == 2)
    }

    // MARK: - 目录 / 文件工具

    @Test func parseGidFromDirname() throws {
        #expect(WiFiDownloadMigration.parseGidFromDirname("123-abc") == 123)
        #expect(WiFiDownloadMigration.parseGidFromDirname("123-") == 123)
        #expect(WiFiDownloadMigration.parseGidFromDirname("+7-x") == 7)  // Long.parseLong 接受 +
        #expect(WiFiDownloadMigration.parseGidFromDirname("-1-x") == -1)
        #expect(WiFiDownloadMigration.parseGidFromDirname("abc-1") == -1)
        #expect(WiFiDownloadMigration.parseGidFromDirname("123") == -1)
        #expect(WiFiDownloadMigration.parseGidFromDirname("") == -1)
    }

    @Test func safePaths() throws {
        #expect(WiFiDownloadMigration.isSafeDirname("1-a"))
        #expect(!WiFiDownloadMigration.isSafeDirname(".."))
        #expect(!WiFiDownloadMigration.isSafeDirname("a/b"))
        #expect(!WiFiDownloadMigration.isSafeDirname(""))
        #expect(WiFiDownloadMigration.safeComponents("a/b.jpg") == ["a", "b.jpg"])
        #expect(WiFiDownloadMigration.safeComponents("../x") == nil)
        #expect(WiFiDownloadMigration.safeComponents("a//b") == nil)
        #expect(WiFiDownloadMigration.safeComponents("/abs") == nil)
        #expect(WiFiDownloadMigration.safeComponents("a/./b") == nil)
    }

    @Test func scanAndFilterAndWrite() throws {
        let root = try makeTransferTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let g1 = root.appendingPathComponent("100-First")
        try fm.createDirectory(at: g1.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try fm.createDirectory(at: g1.appendingPathComponent("backupDir"), withIntermediateDirectories: true)
        try Data("abc".utf8).write(to: g1.appendingPathComponent("00000001.jpg"))
        try Data("xyz".utf8).write(to: g1.appendingPathComponent("sub/00000002.png"))
        try Data("skip".utf8).write(to: g1.appendingPathComponent("backupDir/.ehviewer"))
        try Data().write(to: g1.appendingPathComponent("empty"))
        try fm.createDirectory(at: root.appendingPathComponent("nogid"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("5-second"), withIntermediateDirectories: true)
        try Data("file".utf8).write(to: root.appendingPathComponent("7-file"))

        let dirs = WiFiDownloadMigration.scanGalleryDirs(root: root)
        #expect(dirs.map(\.dirname) == ["100-First", "5-second"])
        #expect(dirs.map(\.gid) == [100, 5])

        let files = WiFiDownloadMigration.scanGalleryDir(g1)
        #expect(files.map(\.name) == ["00000001.jpg", "empty", "sub/00000002.png"])
        #expect(files[0].md5 == "900150983cd24fb0d6963f7d28e17f72")
        #expect(files[0].size == 3)
        #expect(files[1].md5 == "d41d8cd98f00b204e9800998ecf8427e")
        #expect(files[1].size == 0)

        // 对端目录：一个相同、一个内容不同、一个缺失
        let other = try makeTransferTempDir()
        defer { try? fm.removeItem(at: other) }
        let (dest, created) = try #require(WiFiDownloadMigration.ensureGalleryDir(root: other, dirname: "100-First"))
        #expect(created)
        #expect(WiFiDownloadMigration.ensureGalleryDir(root: other, dirname: "100-First")?.created == false)
        #expect(WiFiDownloadMigration.ensureGalleryDir(root: other, dirname: "../evil") == nil)
        try Data("abc".utf8).write(to: dest.appendingPathComponent("00000001.jpg"))
        try Data("abd".utf8).write(to: dest.appendingPathComponent("empty"))
        let remote = files + [.init(name: "../escape", md5: "x", size: 1)]
        let needed = WiFiDownloadMigration.filterFilesNeeded(dest, remoteFiles: remote)
        #expect(needed == ["empty", "sub/00000002.png"])

        // 分块写入：offset 0 截断，之后追加，自动建父目录
        try WiFiDownloadMigration.writeChunk(dest, relPath: "sub/00000002.png", data: Data("xy".utf8), offset: 0)
        try WiFiDownloadMigration.writeChunk(dest, relPath: "sub/00000002.png", data: Data("z".utf8), offset: 2)
        let written = dest.appendingPathComponent("sub/00000002.png")
        #expect(try Data(contentsOf: written) == Data("xyz".utf8))
        #expect(WiFiDownloadMigration.verifyFileMd5(written, expected: files[2].md5.uppercased()))
        try WiFiDownloadMigration.writeChunk(dest, relPath: "sub/00000002.png", data: Data("q".utf8), offset: 0)
        #expect(try Data(contentsOf: written) == Data("q".utf8))
        #expect(try WiFiDownloadMigration.writeChunk(dest, relPath: "../x", data: Data(), offset: 0) == false)

        #expect(WiFiDownloadMigration.chunkCount(fileSize: 0) == 1)
        #expect(WiFiDownloadMigration.chunkCount(fileSize: 256 * 1024) == 1)
        #expect(WiFiDownloadMigration.chunkCount(fileSize: 256 * 1024 + 1) == 2)
    }

    @Test func fileWriteState() throws {
        var s = WiFiDownloadMigration.FileWriteState()
        #expect(s.offset("a") == 0)
        s.addWritten("a", 10)
        s.addWritten("a", 5)
        #expect(s.offset("a") == 15)
        s.clear("a")
        #expect(s.offset("a") == 0)
    }

    // MARK: - 地址 / 二维码

    @Test func qrStringRoundTrip() throws {
        let s = TransferEndpoint.qrString(host: "192.168.1.5", port: 54321)
        #expect(s == "ehviewer://wifi-transfer?host=192.168.1.5&port=54321&v=1")
        let p = try #require(TransferEndpoint.parse(s))
        #expect(p.host == "192.168.1.5" && p.port == 54321)
        #expect(TransferServerInfo(host: "10.0.0.2", port: 54321).qrString == "ehviewer://wifi-transfer?host=10.0.0.2&port=54321&v=1")
        #expect(TransferServerInfo(host: nil, port: 54321).qrString == nil)
    }

    @Test func parseManualAddresses() throws {
        #expect(TransferEndpoint.parse("10.0.0.1")! == ("10.0.0.1", 54321))
        #expect(TransferEndpoint.parse(" 10.0.0.1:1234 \n")! == ("10.0.0.1", 1234))
        #expect(TransferEndpoint.parse("tcp://host.local:99")! == ("host.local", 99))
        #expect(TransferEndpoint.parse("http://172.20.10.1")! == ("172.20.10.1", 54321))
        #expect(TransferEndpoint.parse("[fe80::1]:5")! == ("fe80::1", 5))
        #expect(TransferEndpoint.parse("fe80::1")! == ("fe80::1", 54321))
        #expect(TransferEndpoint.parse("ehviewer://wifi-transfer?host=1.2.3.4")! == ("1.2.3.4", 54321))
        #expect(TransferEndpoint.parse("ehviewer://wifi-transfer?port=1") == nil)
        #expect(TransferEndpoint.parse("1.2.3.4:notaport") == nil)
        #expect(TransferEndpoint.parse("") == nil)
    }

    @Test func pickPrimaryIPv4PrefersEn0() throws {
        typealias A = TransferEndpoint.InterfaceAddress
        let list = [
            A(name: "lo0", address: "127.0.0.1"),
            A(name: "utun3", address: "10.8.0.2"),
            A(name: "pdp_ip0", address: "10.20.30.40"),
            A(name: "bridge100", address: "172.20.10.1"),
            A(name: "en0", address: "192.168.1.20"),
        ]
        #expect(TransferEndpoint.pickPrimaryIPv4(list)?.address == "192.168.1.20")
        #expect(TransferEndpoint.pickPrimaryIPv4(Array(list.dropLast()))?.address == "172.20.10.1")
        #expect(TransferEndpoint.pickPrimaryIPv4([A(name: "en0", address: "169.254.1.2"),
                                                  A(name: "en1", address: "192.168.0.3")])?.address == "192.168.0.3")
        #expect(TransferEndpoint.pickPrimaryIPv4([A(name: "wlan0", address: "192.168.43.10")])?.name == "wlan0")
        #expect(TransferEndpoint.pickPrimaryIPv4(Array(list.prefix(3))) == nil)
    }

    @Test func gatewayGuess() throws {
        #expect(TransferEndpoint.gatewayGuess(address: "192.168.43.57", netmask: "255.255.255.0") == "192.168.43.1")
        #expect(TransferEndpoint.gatewayGuess(address: "172.20.10.3", netmask: "255.255.255.240") == "172.20.10.1")
        #expect(TransferEndpoint.gatewayGuess(address: "10.1.2.3", netmask: nil) == "10.1.2.1")
        #expect(TransferEndpoint.gatewayGuess(address: "172.20.10.1", netmask: "255.255.255.240") == nil)
        #expect(TransferEndpoint.gatewayGuess(address: "bad", netmask: nil) == nil)
    }
}
