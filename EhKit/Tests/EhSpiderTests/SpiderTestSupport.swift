import Foundation
import Testing
@testable import EhSpider

/// 可控的假网络：按预览页每页 perPage 张生成 pToken，图片内容为 JPEG 头 + 页号
final class FakeProvider: GalleryPageProvider, @unchecked Sendable {
    let lock = NSLock()
    let gid: Int64
    var pages: Int
    var perPage: Int
    /// 单张图片下载耗时
    var imageDelay: Duration = .milliseconds(0)
    /// 返回 509 图片地址的页
    var fail509: Set<Int> = []
    /// 某页下载失败（网络错误）的剩余次数
    var downloadFailures: [Int: Int] = [:]
    /// showpage API 第一次返回 Key mismatch
    var keyMismatchOnce = false
    /// fetchPreviewPage 失败的剩余次数
    var previewFailures = 0
    /// 图片页 HTML 请求依次抛出的错误（按页）
    var pageErrors: [Int: [Error]] = [:]
    /// showpage API 依次抛出的错误（按页）
    var apiErrors: [Int: [Error]] = [:]
    /// 下载前等待的闸门（用于取消测试）
    var gate: AsyncGate?

    // 统计
    private(set) var previewCalls: [Int] = []
    private(set) var htmlURLs: [String] = []
    private(set) var apiCalls: [Int] = []
    private(set) var downloads: [Int] = []
    private(set) var concurrent = 0
    private(set) var maxConcurrent = 0
    private var htmlCounter = 0

    init(gid: Int64 = 100, pages: Int = 10, perPage: Int = 20) {
        self.gid = gid
        self.pages = pages
        self.perPage = perPage
    }

    func with<R>(_ body: (FakeProvider) -> R) -> R { lock.withLock { body(self) } }

    static func pToken(_ index: Int) -> String { String(format: "%010x", 0xA0000 + index) }

    static func imageData(_ index: Int) -> Data {
        var d = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x80, 0x90])
        d.append(Data("page-\(index)".utf8))
        return d
    }

    func fetchPreviewPage(gid: Int64, token: String, previewIndex: Int) async throws -> PreviewPageResult {
        let (fail, pages, perPage): (Bool, Int, Int) = lock.withLock {
            previewCalls.append(previewIndex)
            if previewFailures > 0 {
                previewFailures -= 1
                return (true, 0, 0)
            }
            return (false, self.pages, self.perPage)
        }
        if fail { throw EhError.network("preview failed") }
        var set = PreviewSet(isLarge: true)
        let start = previewIndex * perPage
        for i in start ..< min(start + perPage, pages) {
            set.addLargeItem(position: i, imageUrl: "https://ehgt.org/t/\(i).jpg",
                             pageUrl: "https://e-hentai.org/s/\(Self.pToken(i))/\(gid)-\(i + 1)")
        }
        let previewPages = (pages + perPage - 1) / perPage
        return PreviewPageResult(pages: pages, previewPages: previewPages, previewSet: set)
    }

    func imageURL(_ index: Int) -> String {
        fail509.contains(index) ? "https://img.example/509.gif" : "https://img.example/\(gid)/\(index).jpg"
    }

    func fetchPage(pageURL: String, gid: Int64, token: String) async throws -> GalleryPageParser.Result {
        guard let r = GalleryPageUrlParser.parse(pageURL) else { throw EhError.other("bad url \(pageURL)") }
        let (n, failure): (Int, Error?) = lock.withLock {
            htmlURLs.append(pageURL)
            htmlCounter += 1
            if var errors = pageErrors[r.page], !errors.isEmpty {
                let e = errors.removeFirst()
                pageErrors[r.page] = errors
                return (htmlCounter, e)
            }
            return (htmlCounter, nil)
        }
        if let failure { throw failure }
        return GalleryPageParser.Result(imageUrl: imageURL(r.page), skipHathKey: "nlkey\(n)",
                                        originImageUrl: nil, showKey: "showkey1")
    }

    func fetchPageAPI(gid: Int64, index: Int, pToken: String, showKey: String,
                      previousPToken: String?) async throws -> GalleryPageApiParser.Result {
        let (mismatch, failure): (Bool, Error?) = lock.withLock {
            apiCalls.append(index)
            if keyMismatchOnce {
                keyMismatchOnce = false
                return (true, nil)
            }
            if var errors = apiErrors[index], !errors.isEmpty {
                let e = errors.removeFirst()
                apiErrors[index] = errors
                return (false, e)
            }
            return (false, nil)
        }
        if mismatch { throw EhError.parse("Key mismatch", body: nil) }
        if let failure { throw failure }
        return GalleryPageApiParser.Result(imageUrl: imageURL(index), skipHathKey: "apikey\(index)")
    }

    func resolveOriginImageURL(_ url: String, referer: String) async throws -> String? { nil }

    func downloadImage(_ url: String, referer: String, to fileURL: URL, timeout: TimeInterval?,
                       progress: EhDownloadProgress?) async throws -> ImageDownloadResult {
        let index = Int(URL(string: url)!.deletingPathExtension().lastPathComponent) ?? -1
        let (shouldFail, delay, gate): (Bool, Duration, AsyncGate?) = lock.withLock {
            concurrent += 1
            maxConcurrent = max(maxConcurrent, concurrent)
            downloads.append(index)
            if let n = downloadFailures[index], n > 0 {
                downloadFailures[index] = n - 1
                return (true, imageDelay, gate)
            }
            return (false, imageDelay, gate)
        }
        defer { lock.withLock { concurrent -= 1 } }
        if let gate { await gate.wait() }
        if delay > .zero { try await Task.sleep(for: delay) }
        try Task.checkCancellation()
        if shouldFail { throw EhError.network("socket") }
        let data = Self.imageData(index)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL)
        progress?(Int64(data.count / 2), Int64(data.count))
        progress?(Int64(data.count), Int64(data.count))
        return ImageDownloadResult(finalURL: url, statusCode: 200, mimeType: "image/jpeg",
                                   contentLength: Int64(data.count), receivedBytes: Int64(data.count))
    }
}

/// 一次性闸门
actor AsyncGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        open = true
        for w in waiters { w.resume() }
        waiters.removeAll()
    }
}

struct TestDirs {
    let root: URL
    var download: URL { root.appendingPathComponent("download") }
    var cache: URL { root.appendingPathComponent("cache/image") }
    var spiderInfo: URL { root.appendingPathComponent("cache/spider_info") }
    var temp: URL { root.appendingPathComponent("temp") }

    init() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ehspider-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("download"), withIntermediateDirectories: true)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    func environment(_ provider: any GalleryPageProvider, database: EhDatabase? = nil,
                     settings: LoaderSettings = LoaderSettings()) -> SpiderEnvironment {
        SpiderEnvironment(site: .e, provider: provider,
                          location: DownloadLocation(root: download, database: database),
                          imageCache: ImageDiskCache(directory: cache, maxBytes: 64 * 1024 * 1024),
                          spiderInfoCache: SpiderInfoCache(directory: spiderInfo), tempDirectory: temp,
                          settings: settings)
    }
}

func galleryInfo(_ gid: Int64 = 100, title: String = "Test Gallery") -> GalleryInfo {
    GalleryInfo(gid: gid, token: "tok\(gid)", title: title, category: .manga, pages: 0)
}

/// 收集事件直到 done 返回 true；超时返回 nil
func collect(_ stream: AsyncStream<LoaderEvent>, timeout: Duration = .seconds(10),
             until done: @escaping @Sendable (LoaderEvent, [LoaderEvent]) -> Bool) async -> [LoaderEvent]? {
    await withTaskGroup(of: [LoaderEvent]?.self) { group in
        group.addTask {
            var out: [LoaderEvent] = []
            for await e in stream {
                out.append(e)
                if done(e, out) { return out }
            }
            return nil
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

func loadedCount(_ events: [LoaderEvent]) -> Int {
    Set(events.compactMap { if case let .pageLoaded(i, _, _) = $0 { return i } else { return nil } }).count
}

/// 轮询直到条件成立
@MainActor
func eventually(timeout: Duration = .seconds(10), _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

func eventuallyAsync(timeout: Duration = .seconds(10), _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}
