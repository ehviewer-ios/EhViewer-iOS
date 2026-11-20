import EhNetwork
import EhStorage
import Foundation

/// 加载器设置。对应 SpiderQueen 构造时读取的 `Settings.*`
public struct LoaderSettings: Sendable, Hashable {
    /// 并发 worker 数（`getMultiThreadDownload`，clamp 1...10）
    public var workerCount: Int
    /// 预加载页数（`getPreloadImage`，clamp 0...100）
    public var preloadCount: Int
    /// 每页下载完成后的延迟（毫秒，`getDownloadDelay`）
    public var downloadDelay: Int
    /// 图片下载超时（秒，`getDownloadTimeout`；0 表示使用默认图片超时）
    public var downloadTimeout: Int
    /// 下载原图（`getDownloadOriginImage`）
    public var downloadOriginImage: Bool
    /// 阅读时同步写入下载目录（`getSyncDownloadWhileReading`）
    public var syncDownloadWhileReading: Bool
    /// 图片页请求遇到临时错误（网络错误、5xx 等）后，第 n 次重试前等待 n × 此值
    public var transientRetryDelay: Duration = .seconds(2)
    /// 被限流（Cloudflare 质询、429 / 503）时所有 worker 暂停的时长，连续被限流时翻倍（最多 4 倍）
    public var throttleDelay: Duration = .seconds(15)
    /// 下载模式下所有页处理完后，可重试的失败页再补下几轮、每轮之前等待多久
    public var retryRoundDelays: [Duration] = [.seconds(10), .seconds(30)]

    public init(workerCount: Int = 3, preloadCount: Int = 5, downloadDelay: Int = 0, downloadTimeout: Int = 0,
                downloadOriginImage: Bool = false, syncDownloadWhileReading: Bool = false) {
        self.workerCount = workerCount
        self.preloadCount = preloadCount
        self.downloadDelay = downloadDelay
        self.downloadTimeout = downloadTimeout
        self.downloadOriginImage = downloadOriginImage
        self.syncDownloadWhileReading = syncDownloadWhileReading
    }

    /// 从 `EhSettings` 读取
    public init(settings: EhSettings) {
        self.init(workerCount: settings.multiThreadDownload, preloadCount: settings.preloadImage,
                  downloadDelay: settings.downloadDelay, downloadTimeout: settings.downloadTimeout,
                  downloadOriginImage: settings.downloadOriginImage,
                  syncDownloadWhileReading: settings.syncDownloadWhileReading)
    }
}

/// 加载器依赖（网络、目录、缓存、设置）
public struct SpiderEnvironment: Sendable {
    public var site: EhSite
    public var provider: any GalleryPageProvider
    public var location: DownloadLocation
    public var imageCache: ImageDiskCache?
    public var spiderInfoCache: SpiderInfoCache?
    /// 下载临时文件目录；nil 时使用缓存目录下的 .tmp
    public var tempDirectory: URL?
    public var settings: LoaderSettings
    /// 诊断日志（页最终失败、限流暂停、补下轮次等）。App 写入下载日志
    public var diagnostics: (@Sendable (String) -> Void)?

    public init(site: EhSite, provider: any GalleryPageProvider, location: DownloadLocation,
                imageCache: ImageDiskCache?, spiderInfoCache: SpiderInfoCache?, tempDirectory: URL? = nil,
                settings: LoaderSettings = LoaderSettings()) {
        self.site = site
        self.provider = provider
        self.location = location
        self.imageCache = imageCache
        self.spiderInfoCache = spiderInfoCache
        self.tempDirectory = tempDirectory
        self.settings = settings
    }

    /// 以 App 标准目录构造
    public init(site: EhSite, provider: any GalleryPageProvider, directories: AppDirectories, database: EhDatabase?,
                downloadRoot: URL?, settings: EhSettings) {
        let cache = directories.imageCacheDir.map { ImageDiskCache(directory: $0, readCacheSizeMB: settings.readCacheSize) }
        self.init(site: site, provider: provider,
                  location: DownloadLocation(root: downloadRoot ?? directories.defaultDownloadDir, database: database,
                                             preferJapaneseTitle: settings.showJpnTitle),
                  imageCache: cache, spiderInfoCache: directories.spiderInfoCacheDir.map(SpiderInfoCache.init),
                  tempDirectory: directories.tempDir, settings: LoaderSettings(settings: settings))
    }
}

/// 加载器错误文案（对应 Android `R.string.error_*`）
public enum SpiderMessages {
    public static let unknown = "奇怪的错误"
    public static let error509 = "509"
    public static let getPTokenError = "获取 pToken 错误"
    public static let writeFailed = "写入失败"
    public static let readingFailed = "读取失败"
    public static let socket = "网络错误"
    public static let interrupted = "Interrupted"
    public static let showKeyError = "ShowKey error"
    public static let insufficientGP = "GP不足/Insufficient GP"
    public static let hijacked = "链接疑似被劫持\nThe link is suspected to be hijacked"
    public static let incomplete = "Incomplete"
    public static let outOfRange = "超出范围"
    public static let notFolder = "不是有效的文件夹"
    public static let noImages = "没有图片"

    static func readable(_ error: Error) -> String {
        if let e = error as? LocalizedError, let d = e.errorDescription { return d }
        return String(describing: error)
    }
}

/// 在线 / 已下载画廊的分页加载器。对应 Android `spider/SpiderQueen.java`（+ `EhGalleryProvider`）。
///
/// 一个画廊一个实例，由 `GalleryLoaderRegistry` 按 gid 共享并引用计数（多个阅读器 + 至多一个下载）。
/// - 启动后先读本地 `.ehviewer`（下载目录 / spider_info 缓存），没有则请求详情页拿页数与第一批 pToken
/// - 最多 `workerCount` 个 worker 并发：强制请求 > 普通请求 > 预加载 > 下载模式的顺序页
/// - pToken 缺失时按预览页批量获取（串行化，避免重复请求同一预览页）
/// - 单页：HTML 页拿 showKey，之后走 showpage API；509 识别；`nl` 换节点重试（最多 5 次）；可选原图
public actor GalleryLoader: ReaderPageSource {
    /// 内部页状态（对应 STATE_NONE / DOWNLOADING / FINISHED / FAILED）
    enum RawState: Int {
        case none = 0, downloading = 1, finished = 2, failed = 3
        var isDone: Bool { self == .finished || self == .failed }
    }

    static let url509Suffixes = ["/509.gif", "/509s.gif"]
    static let maxAttempts = 5

    public nonisolated let galleryInfo: GalleryInfo
    public nonisolated var gid: Int64 { galleryInfo.gid }
    public nonisolated let den: SpiderDen
    let env: SpiderEnvironment
    private let broadcaster = EventBroadcaster<LoaderEvent>()
    weak var registry: GalleryLoaderRegistry?

    // 引用计数
    private(set) var readReference = 0
    private(set) var downloadReference = 0
    public private(set) var mode: LoaderMode = .read

    // 生命周期
    private var started = false
    public private(set) var isStopped = false
    private var mainTask: Task<Void, Never>?
    private var workerTasks: [Int: Task<Void, Never>] = [:]
    private var nextWorkerID = 0
    private(set) var workerCount = 0
    private let workerMaxCount: Int
    private var preloadNumber: Int

    // SpiderInfo
    private var spiderInfo: SpiderInfo?
    private var _loadError: String?

    // 页状态
    private var pageStates: [RawState]?
    private var pageErrors: [Int: String] = [:]
    private let pagePercents = LockedBox<[Int: Float]>([:])
    private var downloadedPages = 0
    private var finishedPages = 0

    // 请求队列（下标可能越界，worker 取出时再检查）
    private var requestQueue: [Int] = []
    private var preloadQueue: [Int] = []
    private var forceRequestQueue: [Int] = []
    private var downloadPage = -1

    // 限流与重试
    /// 限流冷却截止时间：期间所有 worker 暂停请求图片页
    private var cooldownUntil: ContinuousClock.Instant?
    private var consecutiveThrottles = 0
    /// 失败但可以在补下轮次中重试的页
    private var retryablePages: Set<Int> = []
    private var retryRound = 0

    // showKey 与 pToken 获取的串行化
    private var showKey: String?
    private let showKeyMutex = AsyncMutex()
    private let pTokenMutex = AsyncMutex()

    /// 统计：网络请求次数（测试 / 调试用）
    public private(set) var previewPageRequests = 0

    public init(galleryInfo: GalleryInfo, environment: SpiderEnvironment) {
        self.init(galleryInfo: galleryInfo, environment: environment, registry: nil)
    }

    init(galleryInfo: GalleryInfo, environment: SpiderEnvironment, registry: GalleryLoaderRegistry?) {
        self.registry = registry
        self.galleryInfo = galleryInfo
        env = environment
        den = SpiderDen(galleryInfo: galleryInfo, location: environment.location, cache: environment.imageCache,
                        tempDirectory: environment.tempDirectory,
                        syncDownloadWhileReading: environment.settings.syncDownloadWhileReading)
        workerMaxCount = min(max(environment.settings.workerCount, 1), 10)
        preloadNumber = min(max(environment.settings.preloadCount, 0), 100)
    }

    // MARK: - ReaderPageSource

    public nonisolated var events: AsyncStream<LoaderEvent> { broadcaster.subscribe() }

    /// 开始加载（幂等）。由注册表创建时自动调用
    public func start() {
        guard !started, !isStopped else { return }
        started = true
        mainTask = Task { await self.runQueen() }
    }

    /// 获取页数失败后重试（对应重新打开阅读器）。下载模式进入时也会自动重试
    public func retry() {
        guard !isStopped, _loadError != nil else { return }
        _loadError = nil
        started = true
        mainTask = Task { await self.runQueen() }
    }

    /// 阅读器关闭：释放一个读引用（由注册表管理时）；独立使用时直接停止
    public func close() async {
        if let registry {
            await registry.release(self, mode: .read)
        } else {
            stop()
        }
    }

    /// 对应 `size()`：nil 表示等待中或失败
    public var pageCount: Int? { pageStates?.count }

    /// 对应 `getError()`
    public var loadError: String? { _loadError ?? (isStopped && pageStates == nil ? "Error" : nil) }

    public var progress: LoaderProgress {
        LoaderProgress(finished: finishedPages, downloaded: downloadedPages, total: pageStates?.count ?? -1)
    }

    public func state(of index: Int) -> PageState {
        switch rawState(index) {
        case .none: return .none
        case .downloading: return .loading(progress: pagePercents.withLock { $0[index] })
        case .failed: return .failed(pageErrors[index] ?? SpiderMessages.unknown)
        case .finished:
            if let url = den.fileURL(for: index) { return .loaded(url) }
            return .none
        }
    }

    /// 对应 `request(index)` / `forceRequest(index)`
    @discardableResult
    public func request(_ index: Int, force: Bool) -> PageState {
        request(index, ignoreError: true, force: force, addNeighbor: !force)
    }

    /// 对应 `cancelRequest`
    public func cancel(_ index: Int) {
        guard !isStopped else { return }
        requestQueue.removeAll { $0 == index }
    }

    public func setPreloadCount(_ count: Int) {
        preloadNumber = min(max(count, 0), 100)
    }

    public var preloadCount: Int { preloadNumber }

    /// 对应 `getStartPage`
    public func startPage() -> Int {
        if let info = spiderInfo ?? readSpiderInfoFromLocal() {
            if spiderInfo == nil { spiderInfo = info }
            return info.startPage
        }
        return 0
    }

    /// 对应 `putStartPage`
    public func putStartPage(_ page: Int) {
        if spiderInfo == nil { spiderInfo = readSpiderInfoFromLocal() }
        guard spiderInfo != nil else { return }
        spiderInfo?.startPage = page
        writeSpiderInfoToLocal()
    }

    /// 对应 `SpiderQueen.resetReadingProgress`（只改内存）
    public func resetReadingProgress() {
        spiderInfo?.startPage = 0
    }

    /// 对应 `EhGalleryProvider.getImageFilename`："gid-token-%08d"
    public nonisolated func imageFilename(at index: Int) -> String {
        "\(galleryInfo.gid)-\(galleryInfo.token)-" + String(format: "%08d", index + 1)
    }

    /// 当前 SpiderInfo 快照
    public var currentSpiderInfo: SpiderInfo? { spiderInfo }

    // MARK: - 模式与引用计数（对应 setMode / clearMode / updateMode）

    func retain(_ mode: LoaderMode) {
        switch mode {
        case .read: readReference += 1
        case .download: downloadReference += 1
        }
        // Android 此处抛 IllegalStateException；这里收敛为 1，避免崩溃
        assert(downloadReference <= 1, "downloadReference 不能超过 1")
        downloadReference = min(downloadReference, 1)
        updateMode()
    }

    /// 返回是否已无引用
    func release(_ mode: LoaderMode) -> Bool {
        switch mode {
        case .read: readReference = max(readReference - 1, 0)
        case .download: downloadReference = max(downloadReference - 1, 0)
        }
        updateMode()
        return readReference == 0 && downloadReference == 0
    }

    var referenceCount: (read: Int, download: Int) { (readReference, downloadReference) }

    private func updateMode() {
        let newMode: LoaderMode = downloadReference > 0 ? .download : .read
        den.mode = newMode
        mode = newMode

        var intoDownloadMode = false
        if newMode == .download {
            if downloadPage < 0 {
                downloadPage = 0
                intoDownloadMode = true
            }
        } else {
            downloadPage = -1
        }

        if intoDownloadMode, _loadError != nil {
            // 之前获取页数失败（例如离线打开过阅读器）：重新获取，否则下载永远不会结束
            retry()
        }
        if intoDownloadMode {
            den.prepareDownloadStorage()
            if spiderInfo != nil, den.downloadDir != nil { writeSpiderInfoToLocal() }
        }
        if intoDownloadMode, var states = pageStates {
            // 清除非下载中的状态，重新统计
            for i in states.indices where states[i] != .downloading {
                states[i] = .none
            }
            pageStates = states
            downloadedPages = 0
            finishedPages = 0
            pageErrors.removeAll()
            retryablePages.removeAll()
            retryRound = 0
            pagePercents.withLock { $0.removeAll() }
            ensureWorkers()
        }
    }

    /// 停止：取消全部任务并结束事件流。对应 `stop()`
    public func stop() {
        guard !isStopped else { return }
        isStopped = true
        mainTask?.cancel()
        for t in workerTasks.values { t.cancel() }
        workerTasks.removeAll()
        broadcaster.finish()
    }

    // MARK: - 请求

    private func rawState(_ index: Int) -> RawState {
        guard let states = pageStates, index >= 0, index < states.count else { return .none }
        return states[index]
    }

    private func request(_ index: Int, ignoreError: Bool, force: Bool, addNeighbor: Bool) -> PageState {
        if isStopped || _loadError != nil { return .none }

        var state = rawState(index)
        if (force && state.isDone) || (ignoreError && state == .failed) {
            updatePageState(index, .none)
            state = .none
        }

        var result: PageState
        switch state {
        case .none: result = .none
        case .downloading: result = .loading(progress: pagePercents.withLock { $0[index] })
        case .failed: result = .failed(pageErrors[index] ?? SpiderMessages.unknown)
        case .finished:
            if let url = den.fileURL(for: index) {
                result = .loaded(url)
            } else {
                // 文件已被缓存淘汰：重置并重新请求（对应 SpiderDecoder 的处理）
                updatePageState(index, .none)
                state = .none
                result = .none
            }
        }

        if state == .none {
            if force { forceRequestQueue.append(index) } else { requestQueue.append(index) }
        }

        if addNeighbor {
            preloadQueue.removeAll()
            let size = pageStates?.count ?? Int.max
            var i = index + 1
            let end = index + 1 + preloadNumber
            while i < end, i < size {
                if rawState(i) == .none { preloadQueue.append(i) }
                i += 1
            }
        }

        tryToEnsureWorkers()
        return result
    }

    private func tryToEnsureWorkers() {
        guard let states = pageStates else { return }
        if !forceRequestQueue.isEmpty || !requestQueue.isEmpty || !preloadQueue.isEmpty
            || (downloadPage >= 0 && downloadPage < states.count) {
            ensureWorkers()
        }
    }

    private func ensureWorkers() {
        guard !isStopped else { return }
        while workerCount < workerMaxCount {
            workerCount += 1
            let id = nextWorkerID
            nextWorkerID += 1
            workerTasks[id] = Task { await self.workerLoop(id) }
        }
    }

    // MARK: - 页状态

    private func updatePageState(_ index: Int, _ state: RawState, error: String? = nil, url: URL? = nil) {
        guard var states = pageStates, index >= 0, index < states.count else { return }
        let oldState = states[index]
        states[index] = state
        pageStates = states

        if !oldState.isDone, state.isDone {
            downloadedPages += 1
        } else if oldState.isDone, !state.isDone {
            downloadedPages -= 1
        }
        if oldState != .finished, state == .finished {
            finishedPages += 1
        } else if oldState == .finished, state != .finished {
            finishedPages -= 1
        }

        if state != .failed { retryablePages.remove(index) }
        if state == .downloading {
            pageErrors.removeValue(forKey: index)
        } else if state.isDone {
            _ = pagePercents.withLock { $0.removeValue(forKey: index) }
        }

        switch state {
        case .failed:
            let msg = error ?? SpiderMessages.unknown
            pageErrors[index] = msg
            broadcaster.yield(.pageFailed(index: index, error: msg, progress: progress))
        case .finished:
            if let fileURL = url ?? den.fileURL(for: index) {
                broadcaster.yield(.pageLoaded(index: index, url: fileURL, progress: progress))
            }
        default:
            break
        }
    }

    private func notifyFinish() {
        if mode == .download, spiderInfo != nil {
            // 下载完成后把 pToken 等写入下载目录 `.ehviewer`
            writeSpiderInfoToLocal()
        }
        if mode == .download, let states = pageStates, finishedPages < states.count {
            let failed = states.indices.filter { states[$0] == .failed }
            let detail = failed.prefix(20).map { "\($0 + 1)（\(pageErrors[$0] ?? SpiderMessages.unknown)）" }
            log("下载结束：\(finishedPages)/\(states.count)，失败 \(failed.count) 页：\(detail.joined(separator: "，"))")
        }
        broadcaster.yield(.finished(progress: progress, downloadMode: mode == .download))
    }

    // MARK: - Queen（对应 runInternal）

    private func runQueen() async {
        var info = readSpiderInfoFromLocal()
        if Task.isCancelled { return }

        var errorMessage: String?
        if info == nil {
            do {
                info = try await readSpiderInfoFromInternet()
            } catch {
                errorMessage = SpiderMessages.readable(error)
            }
        }
        if Task.isCancelled || isStopped { return }

        guard var info else {
            let msg = errorMessage ?? SpiderMessages.unknown
            _loadError = msg
            broadcaster.yield(.error(msg))
            notifyFinish()
            return
        }
        // startPage 可能已被 putStartPage 修改
        if let existing = spiderInfo { info.startPage = existing.startPage }
        spiderInfo = info
        writeSpiderInfoToLocal()

        pageStates = Array(repeating: .none, count: info.pages)
        broadcaster.yield(.pageCount(info.pages))
        tryToEnsureWorkers()
    }

    private func isValid(_ info: SpiderInfo?) -> Bool {
        guard let info else { return false }
        return info.gid == galleryInfo.gid && info.token == galleryInfo.token
    }

    /// 对应 `readSpiderInfoFromLocal`：下载目录与缓存都有时取下载目录的，startPage 取较大值
    private func readSpiderInfoFromLocal() -> SpiderInfo? {
        if let spiderInfo { return spiderInfo }
        var fromDownload: SpiderInfo?
        if let dir = den.downloadDir {
            let read = SpiderInfo.read(contentsOf: dir.appendingPathComponent(SpiderNaming.spiderInfoFilename))
            if isValid(read) { fromDownload = read }
        }
        var fromCache = env.spiderInfoCache?.read(gid: gid)
        if !isValid(fromCache) { fromCache = nil }
        guard var fromDownload else { return fromCache }
        guard let fromCache else { return fromDownload }
        fromDownload.startPage = max(fromDownload.startPage, fromCache.startPage)
        return fromDownload
    }

    private func readSpiderInfoFromInternet() async throws -> SpiderInfo {
        var info = SpiderInfo(gid: galleryInfo.gid, token: galleryInfo.token)
        previewPageRequests += 1
        let result = try await env.provider.fetchPreviewPage(gid: gid, token: galleryInfo.token, previewIndex: 0)
        info.pages = result.pages
        Self.readPreviews(result, index: 0, into: &info)
        guard info.pages > 0 else { throw EhError.other("页数为 0") }
        return info
    }

    /// 对应 `readPreviews`
    static func readPreviews(_ result: PreviewPageResult, index: Int, into info: inout SpiderInfo) {
        info.pages = result.pages
        info.previewPages = result.previewPages
        let set = result.previewSet
        if !set.isEmpty {
            info.previewPerPage = index == 0 ? set.count : set.position(at: 0) / index
        }
        for (page, token) in result.pTokens { info.pTokenMap[page] = token }
    }

    /// 对应 `writeSpiderInfoToLocal`：写入已存在的下载目录（不创建）与缓存
    private func writeSpiderInfoToLocal() {
        guard let info = spiderInfo else { return }
        if let dir = den.downloadDir {
            try? info.write(to: dir.appendingPathComponent(SpiderNaming.spiderInfoFilename))
        }
        env.spiderInfoCache?.write(info)
    }

    // MARK: - pToken（对应 queen 线程处理 mRequestPTokenQueue）

    /// 获取 pToken；失败时为 "failed"；被取消 / 停止返回 nil
    private func obtainPToken(_ index: Int) async -> String? {
        if let t = spiderInfo?.pTokenMap[index] { return t }
        await pTokenMutex.acquire()
        defer { pTokenMutex.release() }
        if Task.isCancelled || isStopped { return nil }
        if let t = spiderInfo?.pTokenMap[index] { return t }

        var token = await pTokenFromInternet(index)
        if token == nil, !Task.isCancelled {
            // 预览页每页数量可能变化，重试一次
            token = await pTokenFromInternet(index)
        }
        if Task.isCancelled || isStopped { return token }
        if token == nil {
            spiderInfo?.pTokenMap[index] = SpiderInfo.tokenFailed
            return SpiderInfo.tokenFailed
        }
        return token
    }

    /// 对应 `getPTokenFromInternet`
    private func pTokenFromInternet(_ index: Int) async -> String? {
        await waitForCooldown()
        guard let info = spiderInfo, !Task.isCancelled, !isStopped else { return nil }
        var previewIndex = info.previewPerPage > 0 ? index / info.previewPerPage : 0
        if info.previewPages > 0 {
            previewIndex = min(previewIndex, info.previewPages - 1)
        }
        do {
            previewPageRequests += 1
            let result = try await env.provider.fetchPreviewPage(gid: gid, token: galleryInfo.token,
                                                                 previewIndex: previewIndex)
            guard var current = spiderInfo else { return nil }
            Self.readPreviews(result, index: previewIndex, into: &current)
            spiderInfo = current
            writeSpiderInfoToLocal()
            return current.pTokenMap[index]
        } catch {
            if Self.classify(error) == .throttled { noteThrottled("预览页", error) }
            log("获取第 \(index + 1) 页的 pToken 失败：\(SpiderMessages.readable(error))")
            return nil
        }
    }

    // MARK: - Worker（对应 SpiderWorker）

    private func workerLoop(_ id: Int) async {
        while !Task.isCancelled, !isStopped, den.prepareDownloadStorage(), den.isReady, await runWorkerOnce() {}
        workerTasks.removeValue(forKey: id)
        workerCount -= 1
        if workerCount < 0 { workerCount = 0 }
        if workerCount == 0, !isStopped {
            notifyFinish()
        }
    }

    /// false 表示 worker 应退出
    private func runWorkerOnce() async -> Bool {
        guard spiderInfo != nil, let states = pageStates else { return false }
        let size = states.count

        let index: Int
        var force = false
        if !forceRequestQueue.isEmpty {
            index = forceRequestQueue.removeFirst()
            force = true
        } else if !requestQueue.isEmpty {
            index = requestQueue.removeFirst()
        } else if !preloadQueue.isEmpty {
            index = preloadQueue.removeFirst()
        } else if downloadPage >= 0, downloadPage < size {
            index = downloadPage
            downloadPage += 1
        } else {
            return await scheduleRetryRound()
        }
        guard index >= 0, index < size else { return true }

        let state = states[index]
        if state == .downloading || (!force && state.isDone) { return true }
        updatePageState(index, .downloading)

        if !force, den.contains(index) {
            updatePageState(index, .finished)
            return true
        }

        if force, spiderInfo?.pTokenMap[index] == SpiderInfo.tokenFailed {
            spiderInfo?.pTokenMap.removeValue(forKey: index)
        }

        guard let pToken = await obtainPToken(index), !Task.isCancelled, !isStopped else {
            updatePageState(index, .failed, error: SpiderMessages.interrupted)
            return false
        }

        var previousPToken: String?
        if index > 0 {
            previousPToken = await obtainPToken(index - 1)
            if previousPToken == SpiderInfo.tokenFailed { previousPToken = nil }
        }

        if pToken == SpiderInfo.tokenFailed {
            updatePageState(index, .failed, error: SpiderMessages.getPTokenError)
            retryablePages.insert(index)
            return true
        }
        return await downloadImage(index: index, pToken: pToken, previousPToken: previousPToken)
    }

    private nonisolated func pageURL(index: Int, pToken: String, oldPageURL: String?, skipHathKey: String?) -> String {
        var url = oldPageURL ?? EhURL.page(env.site, gid: galleryInfo.gid, index: index, pToken: pToken)
        if let skipHathKey {
            url += (url.contains("?") ? "&nl=" : "?nl=") + skipHathKey
        }
        return url
    }

    private static func is509(_ url: String?) -> Bool {
        guard let url else { return false }
        return url509Suffixes.contains { url.hasSuffix($0) }
    }

    private struct Image509: Error {}

    private func fetchPageFromHtml(index: Int, pageURL: String) async throws -> GalleryPageParser.Result {
        let result: GalleryPageParser.Result
        do {
            result = try await env.provider.fetchPage(pageURL: pageURL, gid: gid, token: galleryInfo.token)
        } catch EhError.image509 {
            broadcaster.yield(.got509(index: index))
            throw Image509()
        }
        if Self.is509(result.imageUrl) {
            broadcaster.yield(.got509(index: index))
            throw Image509()
        }
        return result
    }

    private func fetchPageFromApi(index: Int, pToken: String, showKey: String,
                                  previousPToken: String?) async throws -> GalleryPageApiParser.Result {
        let result: GalleryPageApiParser.Result
        do {
            result = try await env.provider.fetchPageAPI(gid: gid, index: index, pToken: pToken, showKey: showKey,
                                                         previousPToken: previousPToken)
        } catch EhError.image509 {
            broadcaster.yield(.got509(index: index))
            throw Image509()
        }
        if Self.is509(result.imageUrl) {
            broadcaster.yield(.got509(index: index))
            throw Image509()
        }
        return result
    }

    private static func sameURL(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        return URL(string: a)?.absoluteString == b
    }

    // MARK: - 重试与限流

    /// 图片页 / API / 预览页请求错误的处理方式
    enum FailureKind: Equatable { case fatal, transient, throttled }

    /// - throttled：Cloudflare 质询、429 / 503（站点限流），所有 worker 一起暂停
    /// - transient：网络错误、5xx、返回内容无法解析（如临时的错误页）、未被停止时的取消（来自传输层）
    /// - fatal：封禁、配额、画廊被删除等，重试也不会成功
    static func classify(_ error: Error) -> FailureKind {
        guard let e = error as? EhError else { return .transient }
        switch e {
        case .cloudflareChallenge:
            return .throttled
        case let .http(status):
            if status == 429 || status == 503 { return .throttled }
            return status >= 500 || status == 408 ? .transient : .fatal
        case .network, .parse, .other, .cancelled:
            return .transient
        case .banned, .noHAtH, .notSignedIn, .image509, .server, .offensive, .pining, .quotaExceeded:
            return .fatal
        }
    }

    /// 等待限流冷却结束
    private func waitForCooldown() async {
        while let until = cooldownUntil, !Task.isCancelled, !isStopped {
            if ContinuousClock.now >= until {
                if cooldownUntil == until { cooldownUntil = nil }
                return
            }
            try? await Task.sleep(until: until, clock: .continuous)
        }
    }

    /// 被限流：暂停所有 worker（冷却中再次被限流不叠加；连续被限流时时长翻倍，最多 4 倍）
    private func noteThrottled(_ what: String, _ error: Error) {
        let now = ContinuousClock.now
        if let until = cooldownUntil, until > now { return }
        consecutiveThrottles += 1
        let delay = env.settings.throttleDelay * (1 << min(consecutiveThrottles - 1, 2))
        cooldownUntil = now + delay
        log("\(what)被限流（\(SpiderMessages.readable(error))），暂停 \(Self.seconds(delay)) 秒")
    }

    /// 下载模式下所有页都处理过后，可重试的失败页等待一会儿再补下（`retryRoundDelays`，默认两轮）。
    /// 由最后一个空闲的 worker 执行；还有页在下载时先退出，由最后结束的 worker 来安排
    private func scheduleRetryRound() async -> Bool {
        let delays = env.settings.retryRoundDelays
        guard mode == .download, retryRound < delays.count, !retryablePages.isEmpty, !isStopped,
              pageStates?.contains(.downloading) == false else { return false }
        let delay = delays[retryRound]
        retryRound += 1
        let pages = retryablePages.sorted()
        retryablePages.removeAll()
        log("第 \(retryRound) 轮补下 \(pages.count) 页（\(pages.prefix(20).map { "\($0 + 1)" }.joined(separator: ",") )），\(Self.seconds(delay)) 秒后开始")
        try? await Task.sleep(for: delay)
        guard !Task.isCancelled, !isStopped, mode == .download else { return false }
        for i in pages where rawState(i) == .failed {
            if spiderInfo?.pTokenMap[i] == SpiderInfo.tokenFailed { spiderInfo?.pTokenMap.removeValue(forKey: i) }
            updatePageState(i, .none)
            requestQueue.append(i)
        }
        ensureWorkers()
        return true
    }

    private static func seconds(_ d: Duration) -> String {
        let s = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        return s == s.rounded() ? "\(Int(s))" : String(format: "%.1f", s)
    }

    private nonisolated func log(_ message: String) {
        env.diagnostics?("[\(galleryInfo.gid)] \(message)")
    }

    /// 对应 `SpiderWorker.downloadImage`。返回 false 表示被中断（worker 退出）。
    ///
    /// 与 Android 不同：图片页 / API 请求遇到临时错误时不立即放弃，等待后重试（共 `maxAttempts` 次）；
    /// 被限流时所有 worker 一起暂停（`throttleDelay`）；传输层的取消（loader 未被停止）按临时错误处理。
    private func downloadImage(index: Int, pToken: String, previousPToken: String?) async -> Bool {
        var skipHathKey: String?
        var skipHathKeys: [String] = []
        var originImageUrl: String?
        var pageURLString: String?
        var error: String?
        /// 失败后能否在补下轮次中重试（509、GP 不足、封禁等不能）
        var retryable = true
        var forceHtml = false
        var interrupt = false
        var leakSkipHathKey = false
        let fm = FileManager.default
        let what = "第 \(index + 1) 页"

        /// 请求出错：被停止时中断；否则按类型决定重试或放弃。返回 true 表示进行下一次尝试
        func shouldRetry(_ e: Error, attempt: Int) async -> Bool {
            if Task.isCancelled || isStopped {
                error = SpiderMessages.interrupted
                interrupt = true
                return false
            }
            error = SpiderMessages.readable(e)
            switch Self.classify(e) {
            case .fatal:
                retryable = false
                return false
            case .throttled:
                noteThrottled(what, e)
                return true
            case .transient:
                try? await Task.sleep(for: env.settings.transientRetryDelay * (attempt + 1))
                return true
            }
        }

        attempts: for attempt in 0 ..< Self.maxAttempts {
            await waitForCooldown()
            if Task.isCancelled || isStopped {
                error = SpiderMessages.interrupted
                interrupt = true
                break attempts
            }
            var imageUrl: String?
            var localShowKey: String?

            // showKey：没有或需要强制走 HTML 时，串行获取图片页
            await showKeyMutex.acquire()
            localShowKey = showKey
            if localShowKey == nil || forceHtml {
                if leakSkipHathKey {
                    showKeyMutex.release()
                    break attempts
                }
                // 请求失败时不记下这个地址，重试时用同一个（不重复追加 nl）
                let url = pageURL(index: index, pToken: pToken, oldPageURL: pageURLString, skipHathKey: skipHathKey)
                do {
                    let result = try await fetchPageFromHtml(index: index, pageURL: url)
                    pageURLString = url
                    imageUrl = result.imageUrl
                    skipHathKey = result.skipHathKey
                    originImageUrl = result.originImageUrl
                    localShowKey = result.showKey
                    if let key = skipHathKey, !key.isEmpty {
                        if skipHathKeys.contains(key) {
                            leakSkipHathKey = true
                        } else {
                            skipHathKeys.append(key)
                        }
                    } else {
                        leakSkipHathKey = true
                    }
                    showKey = result.showKey
                    consecutiveThrottles = 0
                } catch is Image509 {
                    error = SpiderMessages.error509
                    retryable = false
                    showKeyMutex.release()
                    break attempts
                } catch let e {
                    showKeyMutex.release()
                    if await shouldRetry(e, attempt: attempt) { continue attempts }
                    break attempts
                }
                if Task.isCancelled || isStopped {
                    error = SpiderMessages.interrupted
                    interrupt = true
                    showKeyMutex.release()
                    break attempts
                }
            }
            showKeyMutex.release()

            if imageUrl == nil {
                guard let key = localShowKey else {
                    error = SpiderMessages.showKeyError
                    break attempts
                }
                do {
                    let result = try await fetchPageFromApi(index: index, pToken: pToken, showKey: key,
                                                            previousPToken: previousPToken)
                    imageUrl = result.imageUrl ?? result.otherImageUrl
                    skipHathKey = result.skipHathKey
                    originImageUrl = result.originImageUrl
                    consecutiveThrottles = 0
                } catch is Image509 {
                    error = SpiderMessages.error509
                    retryable = false
                    break attempts
                } catch let EhError.parse(message, _) where message == "Key mismatch" {
                    // showKey 失效：清掉后重新走 HTML
                    if showKey == key { showKey = nil }
                    continue attempts
                } catch let e {
                    if await shouldRetry(e, attempt: attempt) {
                        // API 返回异常：下次改走 HTML 页（同时刷新 showkey）
                        forceHtml = true
                        continue attempts
                    }
                    break attempts
                }
                if Task.isCancelled || isStopped {
                    error = SpiderMessages.interrupted
                    interrupt = true
                    break attempts
                }
            }

            let referer = EhURL.page(env.site, gid: gid, index: index, pToken: pToken)
            var targetImageUrl: String?
            if env.settings.downloadOriginImage, let origin = originImageUrl, !origin.isEmpty {
                let url = origin + (origin.contains("?") ? "&nl=" : "?nl=") + (skipHathKey ?? "null")
                do {
                    targetImageUrl = try await env.provider.resolveOriginImageURL(url, referer: referer)
                } catch let e {
                    if await shouldRetry(e, attempt: attempt) { continue attempts }
                    if !interrupt { error = SpiderMessages.insufficientGP }
                    break attempts
                }
            } else {
                targetImageUrl = imageUrl
            }
            guard let target = targetImageUrl else {
                error = SpiderMessages.insufficientGP
                retryable = false
                break attempts
            }

            // 下载到临时文件，校验后再放到最终位置
            let temp = den.makeTempFileURL()
            let percents = pagePercents
            let broadcaster = self.broadcaster
            let timeout: TimeInterval? = env.settings.downloadTimeout > 0 ? TimeInterval(env.settings.downloadTimeout) : nil
            do {
                let result = try await env.provider.downloadImage(target, referer: referer, to: temp, timeout: timeout) {
                    received, total in
                    if let total, total > 0 {
                        percents.withLock { $0[index] = Float(Double(received) / Double(total)) }
                    }
                    broadcaster.yield(.pageProgress(index: index, received: received, total: total))
                }
                if !Self.sameURL(target, result.finalURL) {
                    error = SpiderMessages.hijacked
                    forceHtml = true
                    try? fm.removeItem(at: temp)
                    continue attempts
                }
                if result.statusCode >= 400 {
                    error = "Bad code: \(result.statusCode)"
                    forceHtml = true
                    try? fm.removeItem(at: temp)
                    continue attempts
                }
                if let length = result.contentLength, length >= 0, result.receivedBytes < length {
                    error = SpiderMessages.incomplete
                    forceHtml = true
                    try? fm.removeItem(at: temp)
                    continue attempts
                }
                if ImageFiles.isPlainText(fileAt: temp) {
                    error = SpiderMessages.readingFailed
                    forceHtml = true
                    try? fm.removeItem(at: temp)
                    continue attempts
                }
                if Task.isCancelled || isStopped {
                    interrupt = true
                    error = SpiderMessages.interrupted
                    try? fm.removeItem(at: temp)
                    break attempts
                }
                let ext = SpiderNaming.imageExtension(forMimeType: result.mimeType)
                    ?? ImageFiles.sniffExtension(fileAt: temp) ?? SpiderNaming.supportImageExtensions[0]
                let finalURL: URL
                do {
                    finalURL = try den.commit(index, tempFile: temp, extension: ext)
                } catch _ {
                    try? fm.removeItem(at: temp)
                    error = SpiderMessages.writeFailed
                    break attempts
                }
                updatePageState(index, .finished, url: finalURL)
                if env.settings.downloadDelay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(env.settings.downloadDelay) * 1_000_000)
                }
                return true
            } catch _ {
                try? fm.removeItem(at: temp)
                // 只有 loader 被停止才算中断；传输层的取消（连接被系统取消等）按网络错误重试
                if Task.isCancelled || isStopped {
                    interrupt = true
                    error = SpiderMessages.interrupted
                    break attempts
                }
                error = SpiderMessages.socket
                forceHtml = true
            }
        }

        den.remove(index)
        updatePageState(index, .failed, error: error)
        if !interrupt {
            if retryable { retryablePages.insert(index) }
            log("\(what)失败：\(error ?? SpiderMessages.unknown)\(retryable ? "" : "（不再重试）")")
        }
        return !interrupt
    }
}
