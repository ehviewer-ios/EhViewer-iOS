import Foundation
import Testing
@testable import EhSpider

@Suite struct GalleryLoaderTests {
    func makeLoader(_ provider: FakeProvider, _ dirs: TestDirs, settings: LoaderSettings = LoaderSettings(),
                    database: EhDatabase? = nil) -> GalleryLoader {
        GalleryLoader(galleryInfo: galleryInfo(provider.gid), environment: dirs.environment(provider, database: database,
                                                                                               settings: settings))
    }

    @Test func loadsPageCountAndImage() async throws {
        let dirs = TestDirs()
        defer { dirs.cleanup() }
        let provider = FakeProvider(pages: 5)
        let loader = makeLoader(provider, dirs, settings: LoaderSettings(workerCount: 1, preloadCount: 0))
        let events = loader.events
        await loader.start()
        await loader.request(0)
        let got = await collect(events) { e, _ in
            if case .pageLoaded(0, _, _) = e { return true }
            return false
        }
        #expect(got != nil)
        #expect(got?.contains(.pageCount(5)) == true)
        #expect(await loader.pageCount == 5)
        let state = await loader.state(of: 0)
        let url = try #require(state.fileURL)
        #expect(try Data(contentsOf: url) == FakeProvider.imageData(0))
        #expect(url.path.hasPrefix(dirs.cache.path))
        // 第 0 页的 pToken 在首个预览页中，只请求一次
        #expect(provider.with { $0.previewCalls } == [0])
        // 第一次走 HTML 拿 showKey
        #expect(provider.with { $0.htmlURLs.count } == 1)
        // spider_info 缓存已写
        #expect(SpiderInfoCache(directory: dirs.spiderInfo).read(gid: provider.gid)?.pages == 5)
        await loader.stop()
    }

    @Test func concurrencyLimitAndPreload() async throws {
        let dirs = TestDirs()
        defer { dirs.cleanup() }
        let provider = FakeProvider(pages: 30)
        provider.imageDelay = .milliseconds(40)
        let loader = makeLoader(provider, dirs, settings: LoaderSettings(workerCount: 2, preloadCount: 5))
        let events = loader.events
        await loader.start()
        await loader.request(10)
        let got = await collect(events) { _, all in loadedCount(all) >= 6 }
        #expect(got != nil)
        try await Task.sleep(for: .milliseconds(150))
        let downloads = Set(provider.with { $0.downloads })
        // 请求页 + 其后 5 页预加载，不多不少
        #expect(downloads == Set(10 ... 15))
        #expect(provider.with { $0.maxConcurrent } == 2)
        #expect(await loader.state(of: 16) == .none)
        // 其余页走 showpage API
        #expect(provider.with { $0.apiCalls.count } >= 4)
        await loader.stop()
    }

    @Test func workerCountClamped() async throws {
        let dirs = TestDirs()
        defer { dirs.cleanup() }
        let provider = FakeProvider(pages: 40)
        provider.imageDelay = .milliseconds(30)
        let loader = makeLoader(provider, dirs, settings: LoaderSettings(workerCount: 50, preloadCount: 30))
        let events = loader.events
        await loader.start()
        await loader.request(0)
        _ = await collect(events) { _, all in loadedCount(all) >= 31 }
        #expect(provider.with { $0.maxConcurrent } <= 10)
        #expect(provider.with { $0.maxConcurrent } >= 2)
        await loader.stop()
    }

    @Test func pTokenFetchedByPreviewPage() async throws {
        let dirs = TestDirs()
        defer { dirs.cleanup() }
        let provider = FakeProvider(pages: 50, perPage: 20)
        let loader = makeLoader(provider, dirs, settings: LoaderSettings(workerCount: 1, preloadCount: 0))
        let events = loader.events
        await loader.start()
        await loader.request(45)
        _ = await collect(events) { e, _ in
            if case .pageLoaded(45, _, _) = e { return true }
            return false
        }
        // 第 45 页在第 2 个预览页；第 44 页（previousPToken）同页，不再请求
        #expect(provider.with { $0.previewCalls } == [0, 2])
        let events2 = loader.events
        await loader.request(25)
        _ = await collect(events2) { e, _ in
            if case .pageLoaded(25, _, _) = e { return true }
            return false
        }
        #expect(provider.with { $0.previewCalls } == [0, 2, 1])
        let info = try #require(await loader.currentSpiderInfo)
        #expect(info.previewPerPage == 20)
        #expect(info.pTokenMap[45] == FakeProvider.pToken(45))
        await loader.stop()
    }

    @Test func detects509() async throws {
        let dirs = TestDirs()
        defer { dirs.cleanup() }
        let provider = FakeProvider(pages: 5)
        provider.fail509 = [0]
        let loader = makeLoader(provider, dirs, settings: LoaderSettings(workerCount: 1, preloadCount: 0))
        let events = loader.events
        await loader.start()
        await loader.request(0)
        let got = try #require(await collect(events) { e, _ in
            if case .pageFailed(0, _, _) = e { return true }
            return false
        })
        #expect(got.contains(.got509(index: 0)))
        #expect(await loader.state(of: 0) == .failed(SpiderMessages.error509))
        // 失败后普通请求会重置失败状态重新排队（ignoreError）
        provider.with { $0.fail509 = [] }
        let events2 = loader.events
        await loader.request(0)
        let ok = await collect(events2) { e, _ in
            if case .pageLoaded(0, _, _) = e { return true }
            return false
        }
        #expect(ok != nil)
    }

    @Test func retriesWithNlKeyAfterDownloadFailure() async throws {
        let dirs = TestDirs()
        defer { dirs.cleanup() }
        let provider = FakeProvider(pages: 5)
        provider.downloadFailures = [0: 2]
        let loader = makeLoader(provider, dirs, settings: LoaderSettings(workerCount: 1, preloadCount: 0))
        let events = loader.events
        await loader.start()
        await loader.request(0)
        let got = await collect(events) { e, _ in
            if case .pageLoaded(0, _, _) = e { return true }
            if case .pageFailed = e { return true }
            return false
        }
        #expect(got?.last.map { if case .pageLoaded = $0 { return true } else { return false } } == true)
        let urls = provider.with { $0.htmlURLs }
        // 失败后强制走 HTML，并带上上一次的 nl key 换节点
        #expect(urls.count == 3)
        #expect(urls[1].hasSuffix("?nl=nlkey1"))
        #expect(urls[2].hasSuffix("?nl=nlkey1&nl=nlkey2"))
        #expect(provider.with { $0.downloads }.count == 3)
    }

    @Test func givesUpAfterMaxAttempts() async throws {
        let dirs = TestDirs()
        defer { dirs.cleanup() }
        let provider = FakeProvider(pages: 3)
        provider.downloadFailures = [1: 100]
        let loader = makeLoader(provider, dirs, settings: LoaderSettings(workerCount: 1, preloadCount: 0))
        let events = loader.events
        await loader.start()
        await loader.request(1)
        let got = await collect(events) { e, _ in
            if case .pageFailed(1, _, _) = e { return true }
            return false
        }
        #expect(got != nil)
        #expect(provider.with { $0.downloads }.count == GalleryLoader.maxAttempts)
        #expect(await loader.state(of: 1) == .failed(SpiderMessages.socket))
    }

    /// 测试用：缩短重试、限流冷却与补下轮次的等待
    static func fastRetry(_ settings: LoaderSettings) -> LoaderSettings {
        var s = settings
        s.transientRetryDelay = .milliseconds(1)
        s.throttleDelay = .milliseconds(30)
        s.retryRoundDelays = [.milliseconds(10), .milliseconds(10)]
        return s
    }

    private static func isLoaded(_ e: LoaderEvent?, _ index: Int) -> Bool {
        if case let .pageLoaded(i, _, _)? = e { return i == index }
        return false
    }

    /// 图片页请求遇到网络错误、解析失败：等待后用同一地址重试，而不是直接让这一页失败（Android 会直接失败）
    @Test func retriesPageFetchAfterTransientError() async throws {
        let dirs = TestDirs()
        defer { dirs.cleanup() }
        let provider = FakeProvider(pages: 3)
        provider.pageErrors = [0: [EhError.network("connection reset"), EhError.parse("bad page", body: nil)]]
        let loader = makeLoader(provider, dirs, settings: Self.fastRetry(LoaderSettings(workerCount: 1, preloadCount: 0)))
        let events = loader.events
        await loader.start()
        await loader.request(0)
        let got = await collect(events) { e, _ in
            if case .pageLoaded(0, _, _) = e { return true }
            if case .pageFailed = e { return true }
            return false
        }
        #expect(Self.isLoaded(got?.last, 0))
        let urls = provider.with { $0.htmlURLs }
        #expect(urls.count == 3)
        #expect(Set(urls).count == 1)
    }

    /// 传输层的取消（loader 没有被停止，如连接被系统取消）按网络错误重试，不让 worker 退出
    @Test func transportCancellationIsRetried() async throws {
        let dirs = TestDirs()
        defer { dirs.cleanup() }
        let provider = FakeProvider(pages: 3)
        provider.pageErrors = [0: [EhError.cancelled]]
        let loader = makeLoader(provider, dirs, settings: Self.fastRetry(LoaderSettings(workerCount: 1, preloadCount: 0)))
        let events = loader.events
        await loader.start()
        await loader.request(0)
        let got = await collect(events) { e, _ in
            if case .pageLoaded(0, _, _) = e { return true }
            if case .pageFailed = e { return true }
            return false
        }
        #expect(Self.isLoaded(got?.last, 0))
        #expect(provider.with { $0.htmlURLs }.count == 2)
    }

    /// 被限流（Cloudflare 质询）：暂停 throttleDelay 后重试
    @Test func throttledPageWaitsAndRetries() async throws {
        let dirs = TestDirs()
        defer { dirs.cleanup() }
        let provider = FakeProvider(pages: 3)
        provider.pageErrors = [0: [EhError.cloudflareChallenge("e-hentai.org")]]
        let loader = makeLoader(provider, dirs, settings: Self.fastRetry(LoaderSettings(workerCount: 1, preloadCount: 0)))
        let events = loader.events
        await loader.start()
        let start = ContinuousClock.now
        await loader.request(0)
        let got = await collect(events) { e, _ in
            if case .pageLoaded(0, _, _) = e { return true }
            if case .pageFailed = e { return true }
            return false
        }
        #expect(Self.isLoaded(got?.last, 0))
        #expect(ContinuousClock.now - start >= .milliseconds(30))
    }

    /// showpage API 被限流（429）：冷却后改走 HTML 页
    @Test func throttledApiFallsBackToHtml() async throws {
        let dirs = TestDirs()
        defer { dirs.cleanup() }
        let provider = FakeProvider(pages: 3)
        provider.apiErrors = [1: [EhError.http(status: 429)]]
        let loader = makeLoader(provider, dirs, settings: Self.fastRetry(LoaderSettings(workerCount: 1, preloadCount: 0)))
        let events = loader.events
        await loader.start()
        await loader.request(0)
        _ = await collect(events) { e, _ in
            if case .pageLoaded(0, _, _) = e { return true }
            return false
        }
        await loader.request(1)
        let got = await collect(events) { e, _ in
            if case .pageLoaded(1, _, _) = e { return true }
            if case .pageFailed = e { return true }
            return false
        }
        #expect(Self.isLoaded(got?.last, 1))
        #expect(provider.with { $0.apiCalls } == [1])
        #expect(provider.with { $0.htmlURLs }.count == 2)
    }

    /// 封禁等错误重试也不会成功：直接失败
    @Test func fatalPageErrorIsNotRetried() async throws {
        let dirs = TestDirs()
        defer { dirs.cleanup() }
        let provider = FakeProvider(pages: 3)
        provider.pageErrors = [0: [EhError.banned("banned"), EhError.banned("banned")]]
        let loader = makeLoader(provider, dirs, settings: Self.fastRetry(LoaderSettings(workerCount: 1, preloadCount: 0)))
        let events = loader.events
        await loader.start()
        await loader.request(0)
        let got = await collect(events) { e, _ in
            if case .pageFailed(0, _, _) = e { return true }
            return false
        }
        #expect(got != nil)
        #expect(provider.with { $0.htmlURLs }.count == 1)
    }

    /// 下载模式：第一遍用完全部尝试仍失败的页，在补下轮次中重新下载，整本最终完成
    @Test func downloadRetriesFailedPagesInLaterRound() async throws {
        let dirs = TestDirs()
        defer { dirs.cleanup() }
        let db = try EhDatabase.inMemory()
        let provider = FakeProvider(pages: 5, perPage: 5)
        provider.downloadFailures = [2: GalleryLoader.maxAttempts]
        let registry = GalleryLoaderRegistry(environment: dirs.environment(
            provider, database: db, settings: Self.fastRetry(LoaderSettings(workerCount: 2))))
        let (loader, events) = await registry.obtainWithEvents(galleryInfo(provider.gid), mode: .download)
        let got = try #require(await collect(events) { e, _ in
            if case .finished(_, true) = e { return true }
            return false
        })
        guard case let .finished(progress, _) = got.last! else { Issue.record("no finish"); return }
        #expect(progress == LoaderProgress(finished: 5, downloaded: 5, total: 5))
        #expect(got.contains { if case .pageFailed(2, _, _) = $0 { return true } else { return false } })
        #expect(provider.with { $0.downloads }.filter { $0 == 2 }.count == GalleryLoader.maxAttempts + 1)
        await registry.release(loader, mode: .download)
    }

    /// 下载模式：509 等不可重试的失败不进入补下轮次
    @Test func downloadDoesNotRetry509() async throws {
        let dirs = TestDirs()
        defer { dirs.cleanup() }
        let db = try EhDatabase.inMemory()
        let provider = FakeProvider(pages: 4, perPage: 4)
        provider.fail509 = [1]
        let registry = GalleryLoaderRegistry(environment: dirs.environment(
            provider, database: db, settings: Self.fastRetry(LoaderSettings(workerCount: 2))))
        let (loader, events) = await registry.obtainWithEvents(galleryInfo(provider.gid), mode: .download)
        let got = try #require(await collect(events) { e, _ in
            if case .finished(_, true) = e { return true }
            return false
        })
        guard case let .finished(progress, _) = got.last! else { Issue.record("no finish"); return }
        #expect(progress == LoaderProgress(finished: 3, downloaded: 4, total: 4))
        // 第 2 页（index 1）只请求过一次（HTML 或 API，取决于哪个 worker 先拿到 showkey），没有补下
        let requests = provider.with { p in p.htmlURLs.filter { $0.hasSuffix("-2") }.count + p.apiCalls.filter { $0 == 1 }.count }
        #expect(requests == 1)
        await registry.release(loader, mode: .download)
    }

    @Test func keyMismatchRefetchesShowKey() async throws {
        let dirs = TestDirs()
        defer { dirs.cleanup() }
        let provider = FakeProvider(pages: 5)
        provider.keyMismatchOnce = true
        let loader = makeLoader(provider, dirs, settings: LoaderSettings(workerCount: 1, preloadCount: 0))
        let events = loader.events
        await loader.start()
        await loader.request(0)
        _ = await collect(events) { e, _ in
            if case .pageLoaded(0, _, _) = e { return true }
            return false
        }
        let events2 = loader.events
        await loader.request(1)
        let got = await collect(events2) { e, _ in
            if case .pageLoaded(1, _, _) = e { return true }
            return false
        }
        #expect(got != nil)
        // 第 1 页：API → Key mismatch → HTML
        #expect(provider.with { $0.apiCalls } == [1])
        #expect(provider.with { $0.htmlURLs.count } == 2)
    }

    @Test func cancelRemovesQueuedRequest() async throws {
        let dirs = TestDirs()
        defer { dirs.cleanup() }
        let provider = FakeProvider(pages: 10)
        let gate = AsyncGate()
        provider.gate = gate
        let loader = makeLoader(provider, dirs, settings: LoaderSettings(workerCount: 1, preloadCount: 0))
        let events = loader.events
        await loader.start()
        #expect(await eventuallyAsync { await loader.pageCount == 10 })
        await loader.request(0, force: true)
        await loader.request(1, force: false)
        await loader.request(2, force: false)
        await loader.cancel(2)
        await gate.release()
        _ = await collect(events) { e, _ in
            if case .pageLoaded(1, _, _) = e { return true }
            return false
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(provider.with { $0.downloads } == [0, 1])
        #expect(await loader.state(of: 2) == .none)
    }

    @Test func forceRequestRedownloads() async throws {
        let dirs = TestDirs()
        defer { dirs.cleanup() }
        let provider = FakeProvider(pages: 3)
        let loader = makeLoader(provider, dirs, settings: LoaderSettings(workerCount: 1, preloadCount: 0))
        let events = loader.events
        await loader.start()
        await loader.request(0)
        _ = await collect(events) { e, _ in
            if case .pageLoaded(0, _, _) = e { return true }
            return false
        }
        // 已完成的普通请求直接返回文件，不再下载
        #expect(await loader.request(0).isLoaded)
        let events2 = loader.events
        await loader.request(0, force: true)
        _ = await collect(events2) { e, _ in
            if case .pageLoaded(0, _, _) = e { return true }
            return false
        }
        #expect(provider.with { $0.downloads } == [0, 0])
    }

    @Test func spiderInfoFailureReportsError() async throws {
        let dirs = TestDirs()
        defer { dirs.cleanup() }
        let provider = FakeProvider(pages: 3)
        provider.previewFailures = 1
        let loader = makeLoader(provider, dirs)
        let events = loader.events
        await loader.start()
        let got = try #require(await collect(events) { e, _ in
            if case .finished = e { return true }
            return false
        })
        #expect(got.contains { if case .error = $0 { return true } else { return false } })
        #expect(await loader.loadError != nil)
        #expect(await loader.pageCount == nil)
        // 重试成功
        let events2 = loader.events
        await loader.retry()
        #expect(await collect(events2) { e, _ in e == .pageCount(3) } != nil)
        #expect(await loader.loadError == nil)
    }

    @Test func usesLocalSpiderInfoWithoutNetwork() async throws {
        let dirs = TestDirs()
        defer { dirs.cleanup() }
        let provider = FakeProvider(pages: 4)
        var info = SpiderInfo(startPage: 3, gid: provider.gid, token: "tok\(provider.gid)", pages: 4,
                              previewPages: 1, previewPerPage: 20)
        for i in 0 ..< 4 { info.pTokenMap[i] = FakeProvider.pToken(i) }
        SpiderInfoCache(directory: dirs.spiderInfo).write(info)
        let loader = makeLoader(provider, dirs, settings: LoaderSettings(workerCount: 1, preloadCount: 0))
        let events = loader.events
        await loader.start()
        #expect(await loader.startPage() == 3)
        await loader.request(2)
        _ = await collect(events) { e, _ in
            if case .pageLoaded(2, _, _) = e { return true }
            return false
        }
        #expect(provider.with { $0.previewCalls }.isEmpty)
        await loader.putStartPage(2)
        #expect(SpiderInfoCache(directory: dirs.spiderInfo).read(gid: provider.gid)?.startPage == 2)
    }

    @Test func cacheEvictionTriggersRedownload() async throws {
        let dirs = TestDirs()
        defer { dirs.cleanup() }
        let provider = FakeProvider(pages: 3)
        let loader = makeLoader(provider, dirs, settings: LoaderSettings(workerCount: 1, preloadCount: 0))
        let events = loader.events
        await loader.start()
        await loader.request(0)
        _ = await collect(events) { e, _ in
            if case .pageLoaded(0, _, _) = e { return true }
            return false
        }
        loader.den.cache?.clear()
        #expect(await loader.state(of: 0) == .none)
        let events2 = loader.events
        #expect(await loader.request(0) == .none)
        _ = await collect(events2) { e, _ in
            if case .pageLoaded(0, _, _) = e { return true }
            return false
        }
        #expect(provider.with { $0.downloads } == [0, 0])
    }
}

@Suite struct GalleryLoaderRegistryTests {
    @Test func sharesAndReferenceCounts() async throws {
        let dirs = TestDirs()
        defer { dirs.cleanup() }
        let provider = FakeProvider(pages: 3)
        let registry = GalleryLoaderRegistry(environment: dirs.environment(provider))
        let info = galleryInfo(provider.gid)
        let a = await registry.obtain(info, mode: .read)
        let b = await registry.obtain(info, mode: .read)
        #expect(a === b)
        #expect(await registry.activeCount == 1)
        await a.close()
        #expect(await registry.activeCount == 1)
        #expect(await a.isStopped == false)

        let (c, _) = await registry.obtainWithEvents(info, mode: .download)
        #expect(c === a)
        #expect(await c.mode == .download)
        await b.close()
        #expect(await registry.activeCount == 1)
        #expect(await c.mode == .download)
        await registry.release(c, mode: .download)
        #expect(await registry.activeCount == 0)
        #expect(await c.isStopped)
        // 重复释放无副作用
        await registry.release(c, mode: .download)

        let d = await registry.obtain(info, mode: .read)
        #expect(d !== a)
        await d.close()
    }

    @Test func downloadModeWritesDownloadDirectory() async throws {
        let dirs = TestDirs()
        defer { dirs.cleanup() }
        let db = try EhDatabase.inMemory()
        let provider = FakeProvider(pages: 6, perPage: 4)
        let registry = GalleryLoaderRegistry(environment: dirs.environment(provider, database: db,
                                                                            settings: LoaderSettings(workerCount: 3)))
        let info = galleryInfo(provider.gid, title: "下载 / 测试")
        let (loader, events) = await registry.obtainWithEvents(info, mode: .download)
        let got = try #require(await collect(events) { e, _ in
            if case .finished(_, true) = e { return true }
            return false
        })
        guard case let .finished(progress, _) = got.last! else { Issue.record("no finish"); return }
        #expect(progress == LoaderProgress(finished: 6, downloaded: 6, total: 6))

        let dirname = try #require(try db.downloadDirname(gid: provider.gid))
        #expect(dirname == "\(provider.gid)-下载  测试")
        let dir = dirs.download.appendingPathComponent(dirname)
        for i in 0 ..< 6 {
            let f = dir.appendingPathComponent(SpiderNaming.imageFilename(index: i, extension: ".jpg"))
            #expect(try Data(contentsOf: f) == FakeProvider.imageData(i))
        }
        let spider = try #require(SpiderInfo.read(contentsOf: dir.appendingPathComponent(".ehviewer")))
        #expect(spider.pages == 6)
        #expect(spider.pTokenMap.count == 6)
        #expect(provider.with { $0.previewCalls } == [0, 1])
        await registry.release(loader, mode: .download)

        // 再次以阅读模式打开：优先读取下载目录，不再联网
        let reader = await registry.obtain(info, mode: .read)
        let ev = reader.events
        #expect(await eventuallyAsync { await reader.pageCount == 6 })
        await reader.request(3)
        _ = await collect(ev) { e, _ in
            if case .pageLoaded(3, _, _) = e { return true }
            return false
        }
        let url = try #require(await reader.state(of: 3).fileURL)
        #expect(url.deletingLastPathComponent().lastPathComponent == dirname)
        #expect(provider.with { $0.downloads }.count == 6)
        await reader.close()
    }

    @Test func downloadCopiesFromReadCache() async throws {
        let dirs = TestDirs()
        defer { dirs.cleanup() }
        let db = try EhDatabase.inMemory()
        let provider = FakeProvider(pages: 3)
        let registry = GalleryLoaderRegistry(environment: dirs.environment(
            provider, database: db, settings: LoaderSettings(workerCount: 1, preloadCount: 2)))
        let info = galleryInfo(provider.gid)
        let reader = await registry.obtain(info, mode: .read)
        let ev = reader.events
        await reader.request(0)
        _ = await collect(ev) { _, all in loadedCount(all) >= 3 }
        #expect(provider.with { $0.downloads }.count == 3)
        // 阅读时没有创建下载目录
        #expect(try db.downloadDirname(gid: provider.gid) == nil)

        let (loader, events) = await registry.obtainWithEvents(info, mode: .download)
        _ = await collect(events) { e, _ in
            if case .finished(_, true) = e { return true }
            return false
        }
        // 下载模式从缓存复制，不再下载
        #expect(provider.with { $0.downloads }.count == 3)
        let dir = try #require(await loader.den.downloadDir)
        #expect(SpiderNaming.findImageFile(in: dir, index: 2) != nil)
        await registry.release(loader, mode: .download)
        await reader.close()
        #expect(await registry.activeCount == 0)
    }
}

@Suite struct ImageDiskCacheTests {
    @Test func lruTrim() throws {
        let dirs = TestDirs()
        defer { dirs.cleanup() }
        let cache = ImageDiskCache(directory: dirs.cache, maxBytes: 250)
        func put(_ key: String) throws {
            let f = dirs.root.appendingPathComponent(UUID().uuidString)
            try Data(repeating: 1, count: 100).write(to: f)
            try cache.put(key, movingFileAt: f)
        }
        try put("a")
        try put("b")
        Thread.sleep(forTimeInterval: 0.01)
        _ = cache.get("a")
        try put("c")
        #expect(cache.contains("a"))
        #expect(!cache.contains("b"))
        #expect(cache.contains("c"))
        #expect(cache.size == 200)
        // 重新打开时扫描已有文件
        let reopened = ImageDiskCache(directory: dirs.cache, maxBytes: 1000)
        #expect(reopened.size == 200)
    }
}
