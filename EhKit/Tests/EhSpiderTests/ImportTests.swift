import Foundation
import Testing
@testable import EhSpider

/// CBOR 编码（只用于测试构造上游格式的 .ehviewer）
enum MiniCBOR {
    static func head(_ major: UInt8, _ n: UInt64) -> [UInt8] {
        let m = major << 5
        switch n {
        case 0 ..< 24: return [m | UInt8(n)]
        case 24 ..< 256: return [m | 24, UInt8(n)]
        case 256 ..< 65536: return [m | 25, UInt8(n >> 8), UInt8(n & 0xFF)]
        default: return [m | 27] + (0 ..< 8).reversed().map { UInt8((n >> (UInt64($0) * 8)) & 0xFF) }
        }
    }
    static func text(_ s: String) -> [UInt8] { head(3, UInt64(s.utf8.count)) + Array(s.utf8) }
    static func uint(_ v: UInt64) -> [UInt8] { head(0, v) }
}

@MainActor
@Suite struct ImportTests {
    struct Fixture {
        let dirs = TestDirs()
        let db: EhDatabase
        let manager: DownloadManager

        @MainActor
        init() throws {
            let clock = TestClock()
            db = try EhDatabase.inMemory(now: clock.now)
            let registry = GalleryLoaderRegistry(environment: dirs.environment(FakeProvider(), database: db))
            manager = DownloadManager(database: db, registry: registry,
                                      location: DownloadLocation(root: dirs.download, database: db),
                                      spiderInfoCache: SpiderInfoCache(directory: dirs.spiderInfo), now: clock.now)
        }
    }

    func writeImages(_ dir: URL, count: Int, names: ((Int) -> String)? = nil) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 0 ..< count {
            let name = names?(i) ?? SpiderNaming.imageFilename(index: i, extension: ".jpg")
            try FakeProvider.imageData(i).write(to: dir.appendingPathComponent(name))
        }
    }

    @Test func importsAndroidDownloadDirectoryWithTextSpiderInfo() async throws {
        let f = try Fixture()
        defer { f.dirs.cleanup() }
        let src = f.dirs.root.appendingPathComponent("external/123456-Some Title")
        try writeImages(src, count: 3)
        var si = SpiderInfo(startPage: 2, gid: 123456, token: "abcdef1234", pages: 3, previewPages: 1, previewPerPage: 40)
        si.pTokenMap = [0: "0123456789"]
        try si.write(to: src.appendingPathComponent(".ehviewer"))

        let info = try await f.manager.importFolder(src, label: nil)
        #expect(info.gid == 123456)
        #expect(info.token == "abcdef1234")
        #expect(info.title == "Some Title")
        #expect(info.state == DownloadInfo.stateFinish)
        #expect(try f.db.downloadDirname(gid: 123456) == "123456-Some Title")
        let dst = f.dirs.download.appendingPathComponent("123456-Some Title")
        #expect(FileManager.default.fileExists(atPath: dst.appendingPathComponent("00000003.jpg").path))
        #expect(SpiderInfo.read(contentsOf: dst.appendingPathComponent(".ehviewer"))?.startPage == 2)
        // 源目录保留（复制）
        #expect(FileManager.default.fileExists(atPath: src.path))
        // 重复导入
        await #expect(throws: SpiderImportError.alreadyImported) { try await f.manager.importFolder(src) }
        // 已登记的下载项可被 GalleryLoader 读到（gid/token 一致）
        #expect(f.manager.downloadDirectory(for: 123456) == dst)
    }

    @Test func importsIncompleteDirectoryWithCborSpiderInfo() async throws {
        let f = try Fixture()
        defer { f.dirs.cleanup() }
        let src = f.dirs.root.appendingPathComponent("copied")
        try writeImages(src, count: 2)
        // {"gid": 456, "token": "abcdef1234", "pages": 5, "startPage": 1}
        var bytes: [UInt8] = MiniCBOR.head(5, 4)
        bytes += MiniCBOR.text("gid") + MiniCBOR.uint(456)
        bytes += MiniCBOR.text("token") + MiniCBOR.text("abcdef1234")
        bytes += MiniCBOR.text("pages") + MiniCBOR.uint(5)
        bytes += MiniCBOR.text("startPage") + MiniCBOR.uint(1)
        try Data(bytes).write(to: src.appendingPathComponent(".ehviewer"))

        let info = try await f.manager.importFolder(src, label: "L")
        #expect(info.gid == 456)
        #expect(info.token == "abcdef1234")
        // 不完整：状态 NONE，可继续下载补齐
        #expect(info.state == DownloadInfo.stateNone)
        #expect(info.legacy == 3)
        #expect(info.label == "L")
        #expect(f.manager.containLabel("L"))
        // 目录名不是 gid- 开头时按 "gid-标题" 新建
        #expect(try f.db.downloadDirname(gid: 456) == "456-copied")
    }

    @Test func importsDownloadRoot() async throws {
        let f = try Fixture()
        defer { f.dirs.cleanup() }
        let root = f.dirs.root.appendingPathComponent("android/download")
        for gid in [11, 12] as [Int64] {
            let d = root.appendingPathComponent("\(gid)-G\(gid)")
            try writeImages(d, count: 1)
            try SpiderInfo(gid: gid, token: "tok\(gid)", pages: 1).write(to: d.appendingPathComponent(".ehviewer"))
        }
        try writeImages(root.appendingPathComponent("no-info"), count: 1)
        let results = await f.manager.importDownloadRoot(root, move: true)
        #expect(results.count == 2)
        #expect(f.manager.downloadInfo(11)?.state == DownloadInfo.stateFinish)
        #expect(f.manager.downloadInfo(12)?.title == "G12")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("11-G11").path))
    }

    @Test func importsPlainAlbum() async throws {
        let f = try Fixture()
        defer { f.dirs.cleanup() }
        let album = f.dirs.root.appendingPathComponent("我的相册")
        // 只有一个子目录且本层无图片时向下钻取
        let inner = album.appendingPathComponent("inner")
        try writeImages(inner, count: 3) { ["p10.jpg", "p2.png", "p1.jpg"][$0] }
        try Data("x".utf8).write(to: inner.appendingPathComponent("readme.txt"))

        let info = try await f.manager.importFolder(album, label: nil)
        #expect(info.token == DownloadManager.localToken)
        #expect(info.title == "我的相册")
        #expect(info.state == DownloadInfo.stateFinish)
        #expect(info.archiveUri?.hasPrefix(DownloadManager.localAlbumURIPrefix) == true)
        #expect(DownloadManager.isLocalAlbum(info))
        let dir = try #require(f.manager.downloadDirectory(for: info.gid))
        // 自然排序：p1, p2, p10
        #expect(try Data(contentsOf: dir.appendingPathComponent("00000001.jpg")) == FakeProvider.imageData(2))
        #expect(try Data(contentsOf: dir.appendingPathComponent("00000002.png")) == FakeProvider.imageData(1))
        #expect(try Data(contentsOf: dir.appendingPathComponent("00000003.jpg")) == FakeProvider.imageData(0))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(".thumb").path))
        let si = try #require(SpiderInfo.read(contentsOf: dir.appendingPathComponent(".ehviewer")))
        #expect(si.gid == info.gid && si.token == "local" && si.pages == 3)
        await #expect(throws: SpiderImportError.alreadyImported) { try await f.manager.importFolder(album) }
        // 本地画廊不参与下载
        f.manager.startDownload(info.galleryInfo, label: nil)
        #expect(f.manager.downloadState(info.gid) == DownloadInfo.stateFinish)
    }

    @Test func importsZipAndRejectsRar() async throws {
        let f = try Fixture()
        defer { f.dirs.cleanup() }
        let zip = f.dirs.root.appendingPathComponent("Book One.zip")
        try makeZip(at: zip, entries: [("1.jpg", FakeProvider.imageData(1))])
        let managed = f.dirs.download.appendingPathComponent("archive")
        let info = try await f.manager.importArchive(zip, copyInto: managed)
        #expect(info.title == "Book One")
        #expect(info.uploader == DownloadManager.localArchiveUploader)
        #expect(info.state == DownloadInfo.stateFinish)
        #expect(DownloadManager.isLocalArchive(info))
        let stored = try #require(info.archiveUri.flatMap(URL.init(string:)))
        #expect(stored.deletingLastPathComponent().lastPathComponent == "archive")
        #expect(FileManager.default.fileExists(atPath: stored.path))
        #expect(try f.db.downloadInfo(gid: info.gid)?.archiveUri == info.archiveUri)

        let rar = f.dirs.root.appendingPathComponent("b.rar")
        try Data("Rar!".utf8).write(to: rar)
        await #expect(throws: SpiderImportError.unsupportedFormat("rar")) { try await f.manager.importArchive(rar) }
        let empty = f.dirs.root.appendingPathComponent("empty.zip")
        try makeZip(at: empty, entries: [("a.txt", Data("a".utf8))])
        await #expect(throws: SpiderImportError.noImages) { try await f.manager.importArchive(empty) }

        // 删除（含文件）时删除复制进来的压缩包
        f.manager.deleteDownload(info.gid, deleteFiles: true)
        #expect(!FileManager.default.fileExists(atPath: stored.path))
    }

    @Test func importsDownloadedArchiverZip() async throws {
        let f = try Fixture()
        defer { f.dirs.cleanup() }
        let longDir = String(repeating: "长", count: 100)
        let zip = f.dirs.root.appendingPathComponent("a.zip")
        try makeZip(at: zip, entries: [
            ("\(longDir)/", nil),
            ("\(longDir)/001.jpg", FakeProvider.imageData(0)),
            ("\(longDir)/002.webp", FakeProvider.imageData(1)),
            ("\(longDir)/info.txt", Data("x".utf8)),
        ])
        let gi = galleryInfo(777, title: "Archived")
        let info = try await f.manager.importDownloadedArchive(zip: zip, galleryInfo: gi, tempDirectory: f.dirs.temp)
        #expect(info.state == DownloadInfo.stateFinish)
        #expect(info.label == DownloadManager.defaultArchiverLabel)
        #expect(f.manager.containLabel(DownloadManager.defaultArchiverLabel))
        let dir = try #require(f.manager.downloadDirectory(for: 777))
        #expect(dir.lastPathComponent == "777-Archived")
        #expect(try Data(contentsOf: dir.appendingPathComponent("00000002.webp")) == FakeProvider.imageData(1))
        let si = try #require(SpiderInfo.read(contentsOf: dir.appendingPathComponent(".ehviewer")))
        #expect(si.gid == 777 && si.token == "tok777" && si.pages == 2)
        #expect(!FileManager.default.fileExists(atPath: zip.path))
        #expect(!FileManager.default.fileExists(atPath: f.dirs.temp.appendingPathComponent("archiver_777").path))
        #expect(try f.db.downloadInfo(gid: 777)?.state == DownloadInfo.stateFinish)
    }
}

/// 假归档下载：第一次请求写一半后挂起直到被取消（模拟暂停），续传请求返回 206 剩余部分
final class FakeArchiveProvider: ArchiveProvider, @unchecked Sendable {
    let lock = NSLock()
    let data: Data
    var supportsRange = true
    private(set) var offsets: [Int64] = []
    var hangFirst = true

    init(size: Int) {
        data = Data((0 ..< size).map { UInt8($0 % 251) })
    }

    func fetchArchiveList(url: String, gid: Int64, token: String) async throws -> ArchiveParser.Result { .init() }
    func fetchArchiver(url: String, gid: Int64, token: String) async throws -> ArchiverData { .init() }
    func requestHAtHDownload(gid: Int64, token: String, or: String, res: String) async throws {}
    func resolveArchiverDownloadURL(url: String, referer: String, dltype: String, dlcheck: String) async throws -> String? {
        "https://archive.example/zip"
    }

    func downloadArchive(url: String, to fileURL: URL, offset: Int64,
                         progress: EhDownloadProgress?) async throws -> ArchiveDownloadResponse {
        let hang: Bool = lock.withLock {
            offsets.append(offset)
            defer { hangFirst = false }
            return hangFirst
        }
        let total = Int64(data.count)
        if hang {
            let half = data.prefix(data.count / 2)
            try half.write(to: fileURL)
            progress?(Int64(half.count), total)
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            throw CancellationError()
        }
        if offset > 0, supportsRange {
            let rest = data.suffix(from: Int(offset))
            try Data(rest).write(to: fileURL)
            progress?(Int64(rest.count), Int64(rest.count))
            return ArchiveDownloadResponse(statusCode: 206, contentRange: "bytes \(offset)-\(total - 1)/\(total)",
                                           contentLength: Int64(rest.count), receivedBytes: Int64(rest.count))
        }
        try data.write(to: fileURL)
        progress?(total, total)
        return ArchiveDownloadResponse(statusCode: 200, contentLength: total, receivedBytes: total)
    }
}

@Suite struct ArchiverDownloaderTests {
    @Test func pauseAndResumeWithRange() async throws {
        let dirs = TestDirs()
        defer { dirs.cleanup() }
        let provider = FakeArchiveProvider(size: 10_000)
        let completed = LockedBox<Data?>(nil)
        let downloader = ArchiverDownloader(provider: provider, directory: dirs.root.appendingPathComponent("archiver")) {
            zip, _, _ in completed.withLock { $0 = try? Data(contentsOf: zip) }
        }
        let events = downloader.events
        let gi = galleryInfo(901, title: "Zip")
        await downloader.start(gi, url: "https://archive.example/zip")
        #expect(await eventuallyAsync { provider.lock.withLock { provider.offsets.count } == 1 })
        try await Task.sleep(for: .milliseconds(30))
        await downloader.pause(gid: 901)
        #expect(await eventuallyAsync {
            let zip = await downloader.zipURL(fileName: "Zip")
            return ImageFiles.fileSize(zip) == 5_000
        })
        #expect(await downloader.progress(gid: 901)?.paused == true)
        // 状态已持久化
        #expect(FileManager.default.fileExists(atPath: dirs.root.appendingPathComponent("archiver/pending.json").path))

        await downloader.resume(gid: 901)
        #expect(await eventuallyAsync { completed.get != nil })
        #expect(completed.get == provider.data)
        #expect(provider.lock.withLock { provider.offsets } == [0, 5_000])
        var sawImported = false
        for await e in events {
            if case .imported(901, _) = e { sawImported = true; break }
        }
        #expect(sawImported)
        #expect(await downloader.activeGids.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: dirs.root.appendingPathComponent("archiver/pending.json").path))
    }

    @Test func restartsWhenRangeUnsupported() async throws {
        let dirs = TestDirs()
        defer { dirs.cleanup() }
        let provider = FakeArchiveProvider(size: 4_000)
        provider.supportsRange = false
        let completed = LockedBox<Data?>(nil)
        let downloader = ArchiverDownloader(provider: provider, directory: dirs.root) { zip, _, _ in
            completed.withLock { $0 = try? Data(contentsOf: zip) }
        }
        await downloader.start(galleryInfo(902, title: "R"), url: "https://archive.example/zip")
        #expect(await eventuallyAsync { provider.lock.withLock { provider.offsets.count } == 1 })
        try await Task.sleep(for: .milliseconds(30))
        await downloader.pause(gid: 902)
        try await Task.sleep(for: .milliseconds(50))
        await downloader.resume(gid: 902)
        #expect(await eventuallyAsync { completed.get != nil })
        #expect(completed.get == provider.data)
    }

    @Test func resumesPendingAfterRelaunch() async throws {
        let dirs = TestDirs()
        defer { dirs.cleanup() }
        let provider = FakeArchiveProvider(size: 2_000)
        let first = ArchiverDownloader(provider: provider, directory: dirs.root)
        await first.start(galleryInfo(903, title: "P"), url: "https://archive.example/zip")
        #expect(await eventuallyAsync { provider.lock.withLock { provider.offsets.count } == 1 })
        try await Task.sleep(for: .milliseconds(30))
        await first.pause(gid: 903)
        #expect(await eventuallyAsync { ImageFiles.fileSize(dirs.root.appendingPathComponent("P.zip")) == 1_000 })

        // 新实例（App 重启）：暂停的任务保持暂停，可继续
        let completed = LockedBox<Data?>(nil)
        let second = ArchiverDownloader(provider: provider, directory: dirs.root) { zip, _, _ in
            completed.withLock { $0 = try? Data(contentsOf: zip) }
        }
        await second.resumePending()
        #expect(await second.progress(gid: 903)?.paused == true)
        #expect(await second.progress(gid: 903)?.downloaded == 1_000)
        await second.resume(gid: 903)
        #expect(await eventuallyAsync { completed.get != nil })
        #expect(completed.get == provider.data)
    }

    @Test func cancelDeletesZip() async throws {
        let dirs = TestDirs()
        defer { dirs.cleanup() }
        let provider = FakeArchiveProvider(size: 2_000)
        let downloader = ArchiverDownloader(provider: provider, directory: dirs.root)
        await downloader.start(galleryInfo(904, title: "C"), url: "https://archive.example/zip")
        #expect(await eventuallyAsync { provider.lock.withLock { provider.offsets.count } == 1 })
        await downloader.cancel(gid: 904)
        try await Task.sleep(for: .milliseconds(50))
        #expect(!FileManager.default.fileExists(atPath: dirs.root.appendingPathComponent("C.zip").path))
        #expect(await downloader.activeGids.isEmpty)
    }

    @Test func resolveTotal() {
        #expect(ArchiverDownloader.resolveTotal(contentRange: "bytes 100-199/200", offset: 100, contentLength: 100) == 200)
        #expect(ArchiverDownloader.resolveTotal(contentRange: "bytes 0-1/*", offset: 0, contentLength: 50) == 50)
        #expect(ArchiverDownloader.resolveTotal(contentRange: nil, offset: 10, contentLength: nil) == 0)
    }
}
