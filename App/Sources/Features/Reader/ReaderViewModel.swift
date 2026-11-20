import SwiftUI
import Photos
import UniformTypeIdentifiers
import EhCore
import EhStorage
import EhSpider

/// 阅读器配置快照（从 EhSettings 读取；变化时由 SwiftUI 推送给 VM / VC）
struct ReaderConfig: Equatable {
    var direction: EhSettings.ReadingDirection
    var scaling: EhSettings.PageScaling
    var startPosition: EhSettings.StartPosition
    var showPageInterval: Bool
    var volumePage: Bool
    var reverseVolumePage: Bool
    var keepScreenOn: Bool
    var fullscreen: Bool
    var customLightness: Bool
    /// 0...200（>100 提高屏幕亮度，≤100 叠加黑色遮罩，与 Android 一致）
    var lightness: Int
    /// 自动翻页间隔（秒）
    var autoInterval: Int
    var rotation: EhSettings.ScreenRotation
    var showClock: Bool
    var showProgress: Bool
    var showBattery: Bool

    @MainActor
    init(model: AppModel) {
        direction = model.setting(\.readingDirection)
        scaling = model.setting(\.pageScaling)
        startPosition = model.setting(\.startPosition)
        showPageInterval = model.setting(\.showPageInterval)
        volumePage = model.setting(\.volumePage)
        reverseVolumePage = model.setting(\.reverseVolumePage)
        keepScreenOn = model.setting(\.keepScreenOn)
        fullscreen = model.setting(\.readingFullscreen)
        customLightness = model.setting(\.customScreenLightness)
        lightness = model.setting(\.screenLightness)
        autoInterval = model.setting(\.startTransferTime)
        rotation = model.setting(\.screenRotation)
        showClock = model.setting(\.showClock)
        showProgress = model.setting(\.showProgress)
        showBattery = model.setting(\.showBattery)
    }

    var isRTL: Bool { direction == .rightToLeft }
}

/// 阅读器状态与业务逻辑。对应 Android `GalleryActivity` 中与 UI 无关的部分（provider 生命周期、进度、保存/分享、亮度、常亮、自动翻页）
@MainActor @Observable
final class ReaderViewModel {
    let request: ReaderRequest
    private(set) var title: String
    private(set) var pageCount = 0
    private(set) var currentPage = 0
    private(set) var isPreparing = true
    private(set) var loadError: String?
    /// 工具栏。VoiceOver 运行时默认显示（读屏用户无法感知点按区域）
    var showChrome = UIAccessibility.isVoiceOverRunning
    private(set) var isAutoPaging = false
    /// 自定义亮度 ≤ 100 时的黑色遮罩不透明度
    private(set) var dimming: Double = 0
    /// 下滑关闭进度（0…1）：背景与工具栏随之渐隐
    var dismissProgress: Double = 0
    /// 相册权限被拒绝（显示“前往设置”提示）
    var showPhotoPermissionAlert = false

    // MARK: 非观察状态
    @ObservationIgnored private(set) var states: [PageState] = []
    @ObservationIgnored weak var controller: ReaderViewController?
    @ObservationIgnored private var model: AppModel?
    @ObservationIgnored private var source: (any ReaderPageSource)?
    @ObservationIgnored private var galleryLoader: GalleryLoader?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var autoTask: Task<Void, Never>?
    @ObservationIgnored private var progressTask: Task<Void, Never>?
    @ObservationIgnored private var initialPage = 0
    @ObservationIgnored private var started = false
    @ObservationIgnored private var closed = false
    @ObservationIgnored private(set) var config: ReaderConfig?
    @ObservationIgnored private var originalBrightness: CGFloat?
    @ObservationIgnored private var originalIdleTimerDisabled = false
    @ObservationIgnored private var originalBatteryMonitoring = false
    @ObservationIgnored private var forcedRotation = false
    @ObservationIgnored private var securityScopedURL: URL?
    @ObservationIgnored private var notified509 = false
    @ObservationIgnored private var isActive = true
    /// 关闭阅读器（由 ReaderView 提供：保存进度并 dismiss）
    @ObservationIgnored var closeAction: (() -> Void)?
    /// 工具栏“更多”按钮在窗口中的位置（iPad 分享弹出框锚点）
    @ObservationIgnored var moreButtonFrame: CGRect?

    init(request: ReaderRequest) {
        self.request = request
        switch request.source {
        case let .gallery(info): title = info.title ?? info.titleJpn ?? "\(info.gid)"
        case let .directory(_, title), let .archive(_, title): self.title = title
        }
    }

    var isGallery: Bool { galleryLoader != nil }

    func state(of page: Int) -> PageState {
        page >= 0 && page < states.count ? states[page] : .none
    }

    // MARK: - 生命周期

    func start(model: AppModel) async {
        guard !started, !closed else { return }
        started = true
        self.model = model
        originalIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
        originalBatteryMonitoring = UIDevice.current.isBatteryMonitoringEnabled
        UIDevice.current.isBatteryMonitoringEnabled = true
        if let config { applySystem(config) }

        let src: any ReaderPageSource
        let stream: AsyncStream<LoaderEvent>
        switch request.source {
        case let .gallery(info):
            title = model.title(of: info)
            try? model.database.putHistoryInfo(info)
            let (loader, events) = await model.loaderRegistry.obtainWithEvents(info, mode: .read)
            if closed {
                await model.loaderRegistry.release(loader, mode: .read)
                return
            }
            galleryLoader = loader
            src = loader
            stream = events
        case let .directory(url, _):
            if url.startAccessingSecurityScopedResource() { securityScopedURL = url }
            let s = LocalDirectorySource(directory: url)
            stream = s.events
            src = s
        case let .archive(url, _):
            if url.startAccessingSecurityScopedResource() { securityScopedURL = url }
            let s = ArchiveSource(archiveURL: url)
            stream = s.events
            src = s
        }
        source = src
        await src.start()
        // 先确定起始页再消费事件（事件流有缓冲，不会丢），避免 pageCount 事件先到时用错起始页
        if let page = request.startPage {
            initialPage = page
        } else {
            initialPage = await src.startPage()
        }
        if closed { return }
        eventTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                self.handle(event)
            }
        }
        if let n = await src.pageCount {
            setPageCount(n)
        } else if let error = await src.loadError {
            loadError = error
            isPreparing = false
        }
    }

    /// 关闭阅读器：保存进度、释放阅读源、恢复系统状态（幂等）
    func close() {
        guard !closed else { return }
        closed = true
        eventTask?.cancel()
        autoTask?.cancel()
        progressTask?.cancel()
        isAutoPaging = false
        restoreSystem()
        let src = source
        let loader = galleryLoader
        let registry = model?.loaderRegistry
        let page = currentPage
        let hasPages = pageCount > 0
        let scoped = securityScopedURL
        source = nil
        galleryLoader = nil
        Task {
            if let src, hasPages { await src.putStartPage(page) }
            if let loader, let registry {
                await registry.release(loader, mode: .read)
            } else {
                await src?.close()
            }
            scoped?.stopAccessingSecurityScopedResource()
        }
    }

    /// 整体加载失败后重试（仅在线画廊）
    func retryLoad() {
        guard let loader = galleryLoader else { return }
        loadError = nil
        isPreparing = true
        Task {
            await loader.retry()
            if let n = await loader.pageCount { setPageCount(n) }
        }
    }

    // MARK: - 事件

    private func handle(_ event: LoaderEvent) {
        guard !closed else { return }
        switch event {
        case let .pageCount(n):
            setPageCount(n)
        case let .pageProgress(index, received, total):
            var p: Float?
            if let total, total > 0 { p = min(Float(Double(received) / Double(total)), 1) }
            if !state(of: index).isLoaded { setState(index, .loading(progress: p)) }
        case let .pageLoaded(index, url, _):
            setState(index, .loaded(url))
        case let .pageFailed(index, error, _):
            setState(index, .failed(error))
        case .got509:
            if !notified509 {
                notified509 = true
                model?.toast.show("509：图片配额已用尽，请稍后再试", systemImage: "exclamationmark.octagon")
            }
        case let .error(message):
            if pageCount == 0 {
                loadError = message
                isPreparing = false
            } else {
                model?.toast.show(message, systemImage: "exclamationmark.circle")
            }
        case .finished:
            break
        }
    }

    private func setPageCount(_ n: Int) {
        isPreparing = false
        guard n != pageCount || states.count != n else { return }
        loadError = nil
        var newStates = Array(repeating: PageState.none, count: n)
        for i in 0..<min(n, states.count) { newStates[i] = states[i] }
        states = newStates
        let hadPages = pageCount > 0
        pageCount = n
        if !hadPages {
            currentPage = n > 0 ? min(max(initialPage, 0), n - 1) : 0
        } else {
            currentPage = min(currentPage, max(n - 1, 0))
        }
        controller?.reloadPages()
        if n > 0 { requestAround(currentPage) }
    }

    private func setState(_ index: Int, _ state: PageState) {
        guard index >= 0, index < states.count else { return }
        guard states[index] != state else { return }
        states[index] = state
        controller?.pageStateChanged(index)
    }

    // MARK: - 请求

    /// cell 将要显示 / 预取
    func pageNeeded(_ page: Int) {
        guard page >= 0, page < states.count else { return }
        if case .none = states[page] { request(page, force: false) }
    }

    func request(_ page: Int, force: Bool) {
        guard let source, page >= 0, page < pageCount else { return }
        if force {
            states[page] = .none
            controller?.pageStateChanged(page)
        }
        Task {
            let result = await source.request(page, force: force)
            guard !closed else { return }
            mergeRequestResult(page, result)
        }
    }

    /// request 返回的是请求时的快照，可能比事件旧：只接受“更进一步”的状态
    private func mergeRequestResult(_ page: Int, _ result: PageState) {
        let current = state(of: page)
        switch result {
        case .loaded:
            setState(page, result)
        case .failed:
            if !current.isLoaded { setState(page, result) }
        case .loading:
            if case .none = current { setState(page, result) }
        case .none:
            break
        }
    }

    /// 重试失败页（对应 `onTapErrorText` → `forceRequest`）
    func retry(_ page: Int) { request(page, force: true) }

    /// 当前页附近的请求。在线画廊每次都请求当前页（加载器顺带预加载后续页）；本地源自己预读两页
    private func requestAround(_ page: Int) {
        guard page >= 0, page < pageCount else { return }
        if galleryLoader != nil {
            request(page, force: false)
        } else {
            for p in page...min(page + 2, pageCount - 1) { pageNeeded(p) }
        }
    }

    /// VC 报告当前页变化
    func currentPageChanged(_ page: Int) {
        guard page != currentPage, page >= 0, page < pageCount else { return }
        currentPage = page
        requestAround(page)
        scheduleProgressSave()
    }

    /// 对应 `onUpdateCurrentIndex → putStartPage`，合并频繁写入
    private func scheduleProgressSave() {
        progressTask?.cancel()
        progressTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled, let self, let source = self.source else { return }
            await source.putStartPage(self.currentPage)
        }
    }

    // MARK: - 跳转 / 翻页

    func jump(to page: Int) {
        guard page >= 0, page < pageCount else { return }
        controller?.scrollToPage(page, animated: false)
        currentPageChanged(page)
    }

    func toggleChrome() {
        withAnimation(.easeInOut(duration: 0.2)) { showChrome.toggle() }
    }

    /// 关闭阅读器（下滑关闭、读屏“返回”手势）
    func requestClose() {
        closeAction?()
    }

    func toggleAutoPaging() {
        isAutoPaging ? stopAutoPaging() : startAutoPaging()
    }

    /// 自动翻页（间隔 = startTransferTime 秒）。到最后一页停止
    func startAutoPaging() {
        guard !isAutoPaging, pageCount > 0 else { return }
        isAutoPaging = true
        updateIdleTimer()
        autoTask?.cancel()
        autoTask = Task { [weak self] in
            while !Task.isCancelled {
                let seconds = max(self?.config?.autoInterval ?? 2, 1)
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled, let self else { return }
                if !(self.controller?.turnNext(animated: true) ?? false) {
                    self.stopAutoPaging()
                    self.model?.toast.show("已经是最后一页", systemImage: "checkmark.circle")
                    return
                }
            }
        }
    }

    func stopAutoPaging() {
        autoTask?.cancel()
        autoTask = nil
        isAutoPaging = false
        updateIdleTimer()
    }

    // MARK: - 系统状态（亮度 / 常亮 / 方向）

    /// 设置变化（含首次）
    func apply(_ config: ReaderConfig) {
        let old = self.config
        self.config = config
        guard started, !closed else { return }
        applySystem(config, old: old)
    }

    private func applySystem(_ config: ReaderConfig, old: ReaderConfig? = nil) {
        updateIdleTimer()
        if isActive { applyBrightness(config) }
        if old == nil || old?.rotation != config.rotation { applyRotation(config.rotation) }
    }

    private func updateIdleTimer() {
        guard !closed else { return }
        UIApplication.shared.isIdleTimerDisabled = (config?.keepScreenOn ?? false) || isAutoPaging || originalIdleTimerDisabled
    }

    private var screen: UIScreen? {
        if let s = controller?.view.window?.windowScene?.screen { return s }
        return windowScene?.screen
    }

    private var windowScene: UIWindowScene? {
        if let s = controller?.view.window?.windowScene { return s }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }

    /// 对应 `setScreenLightness`：>100 调高屏幕亮度；≤100 只叠加黑色遮罩，不改动系统亮度
    private func applyBrightness(_ config: ReaderConfig) {
        guard let screen else { return }
        if config.customLightness {
            let v = min(max(config.lightness, 0), 200)
            if v > 100 {
                if originalBrightness == nil { originalBrightness = screen.brightness }
                dimming = 0
                let base = originalBrightness ?? screen.brightness
                // 101…200：在原亮度与最高亮度之间线性提高
                screen.brightness = base + (1 - base) * CGFloat(v - 100) / 100
            } else {
                dimming = Double(0xde) / 255 * (1 - Double(v) / 100)
                if let b = originalBrightness {
                    screen.brightness = b
                    originalBrightness = nil
                }
            }
        } else {
            dimming = 0
            if let b = originalBrightness {
                screen.brightness = b
                originalBrightness = nil
            }
        }
    }

    private func restoreBrightness() {
        dimming = 0
        if let b = originalBrightness, let screen {
            screen.brightness = b
        }
        originalBrightness = nil
    }

    /// 对应 `setRequestedOrientation`。iOS 只能请求一次几何更新，无法像 Android 那样锁定
    private func applyRotation(_ rotation: EhSettings.ScreenRotation) {
        guard let scene = windowScene else { return }
        let mask: UIInterfaceOrientationMask
        switch rotation {
        case .default:
            guard forcedRotation else { return }
            forcedRotation = false
            mask = .all
        case .portrait:
            forcedRotation = true
            mask = .portrait
        case .landscape:
            forcedRotation = true
            mask = .landscape
        case .sensor:
            mask = .all
        }
        AppDelegate.orientationMask = mask
        controller?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
    }

    private func restoreSystem() {
        restoreBrightness()
        UIApplication.shared.isIdleTimerDisabled = originalIdleTimerDisabled
        UIDevice.current.isBatteryMonitoringEnabled = originalBatteryMonitoring
        AppDelegate.orientationMask = .all
        if forcedRotation, config?.rotation == .landscape, UIDevice.current.userInterfaceIdiom == .phone,
           let scene = windowScene {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { _ in }
        }
        forcedRotation = false
    }

    /// 进入后台时恢复系统亮度，回到前台再应用
    func scenePhaseChanged(active: Bool) {
        guard started, !closed, active != isActive else { return }
        isActive = active
        if active {
            if let config { applyBrightness(config) }
        } else {
            restoreBrightness()
            stopAutoPaging()
        }
    }

    // MARK: - 图片操作（保存 / 分享 / 复制 / 刷新）

    private func loadedURL(_ page: Int) -> URL? {
        guard let url = state(of: page).fileURL else {
            model?.toast.show("图片尚未加载完成", systemImage: "hourglass")
            return nil
        }
        return url
    }

    private func filename(for page: Int, url: URL) async -> String {
        let base = await source?.imageFilename(at: page) ?? "\(page + 1)"
        let ext = ReaderImageDecoder.imageType(of: url)?.preferredFilenameExtension ?? (url.pathExtension.isEmpty ? "jpg" : url.pathExtension)
        return base + "." + ext
    }

    /// 刷新页（对应页面菜单「刷新」：removeCache + forceRequest）
    func refresh(_ page: Int) {
        request(page, force: true)
    }

    /// 保存到相册（仅请求「添加照片」权限）
    func saveToPhotos(_ page: Int) {
        guard let url = loadedURL(page) else { return }
        Task {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                Haptics.error()
                showPhotoPermissionAlert = true
                return
            }
            let name = await filename(for: page, url: url)
            do {
                let data = try Data(contentsOf: url)
                try await PHPhotoLibrary.shared().performChanges {
                    let req = PHAssetCreationRequest.forAsset()
                    let options = PHAssetResourceCreationOptions()
                    options.originalFilename = name
                    req.addResource(with: .photo, data: data, options: options)
                }
                Haptics.success()
                model?.toast.show("已保存到相册", systemImage: "checkmark.circle")
            } catch {
                Haptics.error()
                model?.toast.show("保存失败：\(error.localizedDescription)", systemImage: "xmark.circle")
            }
        }
    }

    /// 分享图片（复制到临时目录并以画廊文件名命名，对应 `shareImage`）。
    /// sourceRect：触发位置（窗口坐标），iPad 弹出框以此为锚点
    func share(_ page: Int, sourceRect: CGRect? = nil) {
        guard let url = loadedURL(page) else { return }
        Task {
            let name = await filename(for: page, url: url)
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("reader-share", isDirectory: true)
            let dst = dir.appendingPathComponent(name)
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: dst)
                try FileManager.default.copyItem(at: url, to: dst)
                controller?.presentShareSheet(for: dst, sourceRect: sourceRect)
            } catch {
                model?.toast.show("无法分享图片", systemImage: "xmark.circle")
            }
        }
    }

    /// 复制图片到剪贴板（保留原格式，GIF 仍为动图）
    func copyImage(_ page: Int) {
        guard let url = loadedURL(page) else { return }
        guard let data = try? Data(contentsOf: url) else {
            model?.toast.show("读取图片失败", systemImage: "xmark.circle")
            return
        }
        let type = ReaderImageDecoder.imageType(of: url) ?? .jpeg
        UIPasteboard.general.setData(data, forPasteboardType: type.identifier)
        model?.toast.show("已复制图片", systemImage: "doc.on.doc")
    }

    /// 滑块气泡缩略图
    func thumbnail(for page: Int) async -> UIImage? {
        guard let url = state(of: page).fileURL else { return nil }
        return await Task.detached(priority: .userInitiated) {
            ReaderImageDecoder.thumbnail(at: url, maxPixel: 360)
        }.value
    }
}
