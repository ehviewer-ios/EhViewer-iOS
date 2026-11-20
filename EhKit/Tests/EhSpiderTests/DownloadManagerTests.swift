import Foundation
import Testing
@testable import EhSpider

/// 多画廊假网络：按 gid 分发到各自的 FakeProvider
final class MultiProvider: GalleryPageProvider, @unchecked Sendable {
    let providers: [Int64: FakeProvider]
    init(_ list: [FakeProvider]) {
        providers = Dictionary(uniqueKeysWithValues: list.map { ($0.gid, $0) })
    }

    func p(_ gid: Int64) -> FakeProvider { providers[gid]! }

    func fetchPreviewPage(gid: Int64, token: String, previewIndex: Int) async throws -> PreviewPageResult {
        try await p(gid).fetchPreviewPage(gid: gid, token: token, previewIndex: previewIndex)
    }

    func fetchPage(pageURL: String, gid: Int64, token: String) async throws -> GalleryPageParser.Result {
        try await p(gid).fetchPage(pageURL: pageURL, gid: gid, token: token)
    }

    func fetchPageAPI(gid: Int64, index: Int, pToken: String, showKey: String,
                      previousPToken: String?) async throws -> GalleryPageApiParser.Result {
        try await p(gid).fetchPageAPI(gid: gid, index: index, pToken: pToken, showKey: showKey,
                                      previousPToken: previousPToken)
    }

    func resolveOriginImageURL(_ url: String, referer: String) async throws -> String? { nil }

    func downloadImage(_ url: String, referer: String, to fileURL: URL, timeout: TimeInterval?,
                       progress: EhDownloadProgress?) async throws -> ImageDownloadResult {
        // https://img.example/{gid}/{index}.jpg
        let gid = Int64(URL(string: url)!.deletingLastPathComponent().lastPathComponent)!
        return try await p(gid).downloadImage(url, referer: referer, to: fileURL, timeout: timeout, progress: progress)
    }
}

/// 递增时钟（毫秒）
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64 = 1_700_000_000_000
    var now: @Sendable () -> Int64 { { [self] in lock.withLock { value += 1; return value } } }
}

@MainActor
@Suite struct DownloadManagerTests {
    struct Fixture {
        let dirs = TestDirs()
        let db: EhDatabase
        let provider: MultiProvider
        let registry: GalleryLoaderRegistry
        let manager: DownloadManager

        @MainActor
        init(_ providers: [FakeProvider], restorePending: Bool = false, db: EhDatabase? = nil) throws {
            let clock = TestClock()
            let db = try db ?? EhDatabase.inMemory(now: clock.now)
            self.db = db
            provider = MultiProvider(providers)
            registry = GalleryLoaderRegistry(environment: dirs.environment(
                provider, database: db, settings: LoaderSettings(workerCount: 2, preloadCount: 0)))
            manager = DownloadManager(database: db, registry: registry,
                                      location: DownloadLocation(root: dirs.download, database: db),
                                      spiderInfoCache: SpiderInfoCache(directory: dirs.spiderInfo),
                                      restorePending: restorePending, now: clock.now)
            manager.speedInterval = .milliseconds(50)
        }
    }

    @Test func downloadsOneGalleryAtATime() async throws {
        let a = FakeProvider(gid: 1, pages: 4), b = FakeProvider(gid: 2, pages: 3)
        a.imageDelay = .milliseconds(20)
        let f = try Fixture([a, b])
        defer { f.dirs.cleanup() }
        let m = f.manager
        let events = m.events
        m.startDownload(galleryInfo(1), label: nil)
        m.startDownload(galleryInfo(2), label: nil)
        #expect(m.downloadState(1) == DownloadInfo.stateDownload)
        #expect(m.downloadState(2) == DownloadInfo.stateWait)
        #expect(m.currentGid == 1)
        #expect(m.waitList == [2])
        #expect(try f.db.downloadInfo(gid: 2)?.state == DownloadInfo.stateWait)
        // 新项在列表最前
        #expect(m.order == [2, 1])

        #expect(await eventually { m.downloadState(2) == DownloadInfo.stateFinish })
        #expect(m.downloadState(1) == DownloadInfo.stateFinish)
        #expect(m.isIdle)
        let info1 = try #require(m.downloadInfo(1))
        #expect(info1.finished == 4 && info1.total == 4 && info1.legacy == 0)
        #expect(try f.db.downloadInfo(gid: 1)?.state == DownloadInfo.stateFinish)
        // 两个画廊没有交叠
        let firstOf2 = b.with { $0.downloads }.count
        #expect(firstOf2 == 3)
        // 下载目录与 .ehviewer
        let dir = try #require(m.downloadDirectory(for: 1))
        #expect(SpiderInfo.read(contentsOf: dir.appendingPathComponent(".ehviewer"))?.pages == 4)
        // 历史记录
        #expect(try f.db.allHistory().count == 2)
        // 注册表已释放
        #expect(await f.registry.activeCount == 0)

        var seen: [DownloadEvent] = []
        for await e in events {
            seen.append(e)
            if case let .finished(info) = e, info.gid == 2 { break }
        }
        #expect(seen.contains { if case let .started(i) = $0 { return i.gid == 1 } else { return false } })
        #expect(seen.contains { if case let .finished(i) = $0 { return i.gid == 1 } else { return false } })
    }

    @Test func failedPagesMarkFailed() async throws {
        let a = FakeProvider(gid: 7, pages: 3)
        a.fail509 = [1]
        let f = try Fixture([a])
        defer { f.dirs.cleanup() }
        let m = f.manager
        let events = m.events
        m.startDownload(galleryInfo(7), label: nil)
        #expect(await eventually { m.downloadState(7) == DownloadInfo.stateFailed })
        let info = try #require(m.downloadInfo(7))
        #expect(info.legacy == 1)
        #expect(info.finished == 2)
        var got509 = false
        for await e in events {
            if e == .got509 { got509 = true }
            if case .finished = e { break }
        }
        #expect(got509)
        // 重新开始失败项：只补下载失败页
        a.with { $0.fail509 = [] }
        m.startRangeDownload([7])
        #expect(await eventually { m.downloadState(7) == DownloadInfo.stateFinish })
        #expect(a.with { $0.downloads }.sorted() == [0, 1, 2])
    }

    @Test func stopAndDeleteWithFiles() async throws {
        let a = FakeProvider(gid: 11, pages: 5)
        let gate = AsyncGate()
        a.gate = gate
        let b = FakeProvider(gid: 12, pages: 2)
        let f = try Fixture([a, b])
        defer { f.dirs.cleanup() }
        let m = f.manager
        m.startDownload(galleryInfo(11), label: nil)
        m.startDownload(galleryInfo(12), label: nil)
        #expect(await eventually { a.with { $0.downloads.count } > 0 })
        m.stopDownload(11)
        #expect(m.downloadState(11) == DownloadInfo.stateNone)
        #expect(try f.db.downloadInfo(gid: 11)?.state == DownloadInfo.stateNone)
        // 停止当前后自动开始下一项
        #expect(m.currentGid == 12)
        await gate.release()
        #expect(await eventually { m.downloadState(12) == DownloadInfo.stateFinish })
        let dir = try #require(m.downloadDirectory(for: 12))
        m.deleteDownload(12, deleteFiles: true)
        #expect(m.downloadInfo(12) == nil)
        #expect(try f.db.downloadInfo(gid: 12) == nil)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
        #expect(try f.db.downloadDirname(gid: 12) == nil)
    }

    @Test func startAllAndStopAll() async throws {
        let ps = (21 ... 23).map { FakeProvider(gid: $0, pages: 2) }
        let gate = AsyncGate()
        for p in ps { p.gate = gate }
        let f = try Fixture(ps)
        defer { f.dirs.cleanup() }
        let m = f.manager
        for p in ps { m.addDownload(galleryInfo(p.gid), label: nil) }
        #expect(m.allInfoList.allSatisfy { $0.state == DownloadInfo.stateNone })
        m.startAllDownload()
        // order 为 [23, 22, 21]，downloadOrderAsc = true 时按列表顺序入队
        #expect(m.currentGid == 23)
        #expect(m.waitList == [22, 21])
        m.stopAllDownload()
        #expect(m.isIdle)
        #expect(m.allInfoList.allSatisfy { $0.state == DownloadInfo.stateNone })
        #expect(try f.db.allDownloadInfo().allSatisfy { $0.state == DownloadInfo.stateNone })
        await gate.release()
    }

    @Test func labelsPersist() async throws {
        let f = try Fixture([])
        defer { f.dirs.cleanup() }
        let m = f.manager
        m.addLabel("A")
        m.addLabel("B")
        m.addLabel("A")
        #expect(m.labelList.map(\.label) == ["A", "B"])
        m.addDownload(galleryInfo(1), label: "A")
        m.addDownload(galleryInfo(2), label: nil)
        m.addDownload(galleryInfo(3), label: "B")
        m.changeLabel([2], to: "A")
        #expect(m.downloadInfoList(label: "A").map(\.gid) == [2, 1])
        m.changeLabel([3], to: "不存在")
        #expect(m.downloadInfo(3)?.label == "B")
        m.renameLabel(from: "A", to: "C")
        #expect(m.downloadInfoList(label: "C").count == 2)
        m.moveLabel(from: 0, to: 1)
        #expect(m.labelList.map(\.label) == ["B", "C"])
        m.deleteLabel("B")
        #expect(m.downloadInfo(3)?.label == nil)
        #expect(m.labelCount(nil) == 1)
        #expect(m.labelCount("C") == 2)

        // 从数据库重建
        let m2 = DownloadManager(database: f.db, registry: f.registry,
                                 location: DownloadLocation(root: f.dirs.download, database: f.db))
        #expect(m2.labelList.map(\.label) == ["C"])
        #expect(m2.downloadInfo(1)?.label == "C")
        #expect(m2.downloadInfo(3)?.label == nil)
        #expect(m2.order == m.order)
    }

    @Test func moveDownloadReordersByTime() throws {
        let f = try Fixture([])
        defer { f.dirs.cleanup() }
        let m = f.manager
        for g in 1 ... 4 { m.addDownload(galleryInfo(Int64(g)), label: nil) }
        #expect(m.order == [4, 3, 2, 1])
        m.moveDownload(label: nil, from: 0, to: 2)
        #expect(m.order == [3, 2, 4, 1])
        let m2 = DownloadManager(database: f.db, registry: f.registry,
                                 location: DownloadLocation(root: f.dirs.download, database: f.db))
        #expect(m2.order == [3, 2, 4, 1])
    }

    @Test func restoresPendingOnLaunch() async throws {
        let db = try EhDatabase.inMemory()
        try db.putDownloadInfo(DownloadInfo(galleryInfo(31), state: DownloadInfo.stateDownload, time: 10))
        try db.putDownloadInfo(DownloadInfo(galleryInfo(32), state: DownloadInfo.stateWait, time: 5))
        try db.putDownloadInfo(DownloadInfo(galleryInfo(33), state: DownloadInfo.stateFinish, time: 1))
        // 默认与 Android 一致：重置为 NONE
        let plain = try Fixture([FakeProvider(gid: 31, pages: 1), FakeProvider(gid: 32, pages: 1)], db: db)
        defer { plain.dirs.cleanup() }
        #expect(plain.manager.downloadState(31) == DownloadInfo.stateNone)
        #expect(plain.manager.isIdle)

        let f = try Fixture([FakeProvider(gid: 31, pages: 1), FakeProvider(gid: 32, pages: 1)],
                            restorePending: true, db: db)
        defer { f.dirs.cleanup() }
        #expect(f.manager.currentGid == 31)
        #expect(f.manager.waitList == [32])
        #expect(await eventually { f.manager.downloadState(32) == DownloadInfo.stateFinish })
        #expect(f.manager.downloadState(33) == DownloadInfo.stateFinish)
    }

    @Test func backgroundSuspendAndResume() async throws {
        let a = FakeProvider(gid: 41, pages: 3)
        let gate = AsyncGate()
        a.gate = gate
        let f = try Fixture([a])
        defer { f.dirs.cleanup() }
        let m = f.manager
        m.startDownload(galleryInfo(41), label: nil)
        #expect(m.enterBackground())
        m.backgroundTimeWillExpire()
        #expect(m.isSuspended)
        #expect(m.currentGid == nil)
        #expect(m.waitList == [41])
        #expect(m.downloadState(41) == DownloadInfo.stateWait)
        #expect(try f.db.downloadInfo(gid: 41)?.state == DownloadInfo.stateWait)
        await gate.release()
        m.enterForeground()
        #expect(!m.isSuspended)
        #expect(await eventually { m.downloadState(41) == DownloadInfo.stateFinish })
    }

    @Test func speedIsReported() async throws {
        let a = FakeProvider(gid: 51, pages: 20)
        a.imageDelay = .milliseconds(30)
        let f = try Fixture([a])
        defer { f.dirs.cleanup() }
        let m = f.manager
        let events = m.events
        m.startDownload(galleryInfo(51), label: nil)
        var sawProgress = false
        for await e in events {
            if case let .progress(info) = e, info.speed > 0 { sawProgress = true }
            if case .finished = e { break }
        }
        #expect(sawProgress)
    }
}
