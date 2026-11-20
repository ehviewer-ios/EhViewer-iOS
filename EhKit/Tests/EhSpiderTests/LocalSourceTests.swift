import Foundation
import Testing
import ZIPFoundation
@testable import EhSpider

/// 用 ZIPFoundation 写测试 zip（条目按给定顺序）
func makeZip(at url: URL, entries: [(String, Data?)]) throws {
    try? FileManager.default.removeItem(at: url)
    let archive = try Archive(url: url, accessMode: .create)
    for (path, data) in entries {
        if let data {
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count),
                                 compressionMethod: .deflate,
                                 provider: { (position: Int64, size: Int) -> Data in
                                     data.subdata(in: Int(position) ..< Int(position) + size)
                                 })
        } else {
            try archive.addEntry(with: path, type: .directory, uncompressedSize: Int64(0),
                                 provider: { (_: Int64, _: Int) -> Data in Data() })
        }
    }
}

@Suite struct NaturalComparatorTests {
    func order(_ a: String?, _ b: String?) {
        #expect(NaturalComparator.compare(a, b) < 0, "\(String(describing: a)) < \(String(describing: b))")
        #expect(NaturalComparator.compare(b, a) > 0)
    }

    func equal(_ a: String?, _ b: String?) {
        #expect(NaturalComparator.compare(a, b) == 0)
        #expect(NaturalComparator.compare(b, a) == 0)
    }

    // 移植自 Android NaturalComparatorTest
    @Test func androidCases() {
        order("1", "2")
        order("2", "11")
        order("2", "00011")
        order("a2", "a11")
        order("a2a", "a11a")
        equal("2", "2")
        equal("11", "11")
        equal("a11", "a11")
        equal("a2", "a2")
        equal("a2a", "a2a")
        order("", "1")
        equal("", "")
        equal(nil, nil)
        order(nil, "1")
        order("1", "22222222222222222222222222222222222222222222222222222222222222222222222")
        order("000000000000000001", "1")
        order("000000000000000001", "0001")
        order("00000000000000000", "0")
        order("00000000000000000", "000")
    }

    @Test func ignoresCase() {
        equal("Page", "page")
        order("img 9.jpg", "IMG 10.jpg")
    }
}

@Suite struct LocalDirectorySourceTests {
    @Test func listsImagesInNaturalOrder() async throws {
        let dirs = TestDirs()
        defer { dirs.cleanup() }
        let dir = dirs.root.appendingPathComponent("album")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub.jpg"), withIntermediateDirectories: true)
        for name in ["10.jpg", "2.PNG", "1.jpg", "note.txt", ".hidden.jpg", "img 3.webp"] {
            try Data([0xFF, 0xD8, 0xFF]).write(to: dir.appendingPathComponent(name))
        }
        let source = LocalDirectorySource(directory: dir)
        let events = source.events
        await source.start()
        #expect(await source.pageCount == 4)
        #expect(await source.fileURLs.map(\.lastPathComponent) == ["1.jpg", "2.PNG", "10.jpg", "img 3.webp"])
        #expect(await source.state(of: 2).fileURL?.lastPathComponent == "10.jpg")
        #expect(await source.state(of: 9) == .failed(SpiderMessages.outOfRange))
        let loaded = await source.request(1)
        #expect(loaded.fileURL?.lastPathComponent == "2.PNG")
        let got = await collect(events) { e, _ in
            if case .pageLoaded(1, _, _) = e { return true }
            return false
        }
        #expect(got?.first == .pageCount(4))
        await source.close()
    }

    @Test func notADirectory() async {
        let source = LocalDirectorySource(directory: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"))
        await source.start()
        #expect(await source.loadError != nil)
        #expect(await source.pageCount == nil)
    }

    @Test func startPageInSpiderInfo() async throws {
        let dirs = TestDirs()
        defer { dirs.cleanup() }
        let dir = dirs.root.appendingPathComponent("g")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try SpiderInfo(startPage: 4, gid: 9, token: "t", pages: 10).write(to: dir.appendingPathComponent(".ehviewer"))
        let source = LocalDirectorySource(directory: dir)
        #expect(await source.startPage() == 4)
        await source.putStartPage(7)
        #expect(SpiderInfo.read(contentsOf: dir.appendingPathComponent(".ehviewer"))?.startPage == 7)
    }
}

@Suite struct ArchiveSourceTests {
    @Test func readsImagesInNaturalOrder() async throws {
        let dirs = TestDirs()
        defer { dirs.cleanup() }
        let zip = dirs.root.appendingPathComponent("book.cbz")
        try makeZip(at: zip, entries: [
            ("book/", nil),
            ("book/10.jpg", Data("ten".utf8)),
            ("book/2.jpg", Data("two".utf8)),
            ("book/1.JPG", Data("one".utf8)),
            ("book/readme.txt", Data("x".utf8)),
            ("__MACOSX/book/._1.jpg", Data("fork".utf8)),
        ])
        let source = ArchiveSource(archiveURL: zip, extractDirectory: dirs.root.appendingPathComponent("x"))
        await source.start()
        #expect(await source.pageCount == 3)
        #expect(await source.state(of: 0) == .none)
        let s0 = await source.request(0)
        #expect(try Data(contentsOf: #require(s0.fileURL)) == Data("one".utf8))
        let s2 = await source.request(2)
        #expect(try Data(contentsOf: #require(s2.fileURL)) == Data("ten".utf8))
        #expect(await source.state(of: 0).isLoaded)
        await source.close()
        #expect(!FileManager.default.fileExists(atPath: dirs.root.appendingPathComponent("x").path))
    }

    @Test func rejectsRarAnd7z() async throws {
        let dirs = TestDirs()
        defer { dirs.cleanup() }
        for ext in ["rar", "cbr", "7z"] {
            let url = dirs.root.appendingPathComponent("a.\(ext)")
            try Data("Rar!".utf8).write(to: url)
            #expect(throws: SpiderImportError.unsupportedFormat(ext)) { try ArchiveSource.openArchive(url) }
            let source = ArchiveSource(archiveURL: url)
            await source.start()
            #expect(await source.loadError == SpiderImportError.unsupportedFormat(ext).errorDescription)
        }
    }

    @Test func brokenZip() async throws {
        let dirs = TestDirs()
        defer { dirs.cleanup() }
        let url = dirs.root.appendingPathComponent("broken.zip")
        try Data("not a zip".utf8).write(to: url)
        let source = ArchiveSource(archiveURL: url)
        await source.start()
        #expect(await source.loadError != nil)
    }
}

@Suite struct ArchiveExtractorTests {
    /// 移植自 Android ArchiverZipExtractTest.unzipLongDirectoryKeepsZipOrderAndSkipsNonImages
    @Test func unzipLongDirectoryKeepsZipOrderAndSkipsNonImages() throws {
        let dirs = TestDirs()
        defer { dirs.cleanup() }
        let zip = dirs.root.appendingPathComponent("archive.zip")
        let longDir = String(repeating: "画", count: 120)
        #expect(longDir.utf8.count > 255)
        try makeZip(at: zip, entries: [
            ("\(longDir)/", nil),
            ("\(longDir)/0002.jpg", Data("second".utf8)),
            ("\(longDir)/note.txt", Data("skip".utf8)),
            ("\(longDir)/../escaped.png", Data("escape".utf8)),
            ("\(longDir)/0001.PNG", Data("first".utf8)),
        ])
        let dest = dirs.root.appendingPathComponent("archiver_1")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: dest.appendingPathComponent("stale.txt"))

        #expect(try ArchiveExtractor.unzipArchive(zip, to: dest) == 2)
        #expect(try String(contentsOf: dest.appendingPathComponent("00000001.jpg"), encoding: .utf8) == "second")
        #expect(try String(contentsOf: dest.appendingPathComponent("00000002.png"), encoding: .utf8) == "first")
        #expect(!FileManager.default.fileExists(atPath: dest.appendingPathComponent("stale.txt").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dest.path).count == 2)
    }

    /// 移植自 unzipFailureDeletesTempDir
    @Test func unzipFailureDeletesTempDir() throws {
        let dirs = TestDirs()
        defer { dirs.cleanup() }
        let zip = dirs.root.appendingPathComponent("broken.zip")
        try Data("not a zip".utf8).write(to: zip)
        let dest = dirs.root.appendingPathComponent("archiver_2")
        #expect(throws: (any Error).self) { try ArchiveExtractor.unzipArchive(zip, to: dest) }
        #expect(!FileManager.default.fileExists(atPath: dest.path))
    }

    @Test func zipWithoutImagesFails() throws {
        let dirs = TestDirs()
        defer { dirs.cleanup() }
        let zip = dirs.root.appendingPathComponent("text.zip")
        try makeZip(at: zip, entries: [("a.txt", Data("a".utf8))])
        let dest = dirs.root.appendingPathComponent("out")
        #expect(throws: SpiderImportError.noImages) { try ArchiveExtractor.unzipArchive(zip, to: dest) }
        #expect(!FileManager.default.fileExists(atPath: dest.path))
    }

    @Test func createFileNameTruncatesLongTitles() {
        let long = String(repeating: "画", count: 120) // 360 字节
        let name = ArchiveExtractor.createFileName(long, gid: 5)
        #expect(name.utf8.count <= 251)
        #expect(name.utf8.count == 249)
        #expect((name + ".zip").utf8.count <= 255)
        #expect(ArchiveExtractor.createFileName("a/b:c", gid: 5) == "abc")
        #expect(ArchiveExtractor.createFileName(nil, gid: 5) == "archiver_5")
        #expect(ArchiveExtractor.createFileName("///", gid: 0) == "archiver")
        // 代理对不被截断成半个
        let emoji = String(repeating: "😀", count: 70) // 280 字节
        #expect(ArchiveExtractor.createFileName(emoji, gid: 1).unicodeScalars.allSatisfy { $0.value == 0x1F600 })
    }
}
