import UIKit
import BackgroundTasks
import EhStorage
import EhSpider

/// 下载的后台续跑。
///
/// - iOS 26+：有下载时申请“持续处理任务”（`BGContinuedProcessingTask`）。切到后台后系统允许继续运行，
///   并在系统界面显示进度（可由用户取消）。下载逻辑原样运行，域前置、DoH、代理照常生效。
///   任务在 App 位于前台时提交：开始下载时，以及即将离开 App 时（如果还没有任务）。
/// - 没有持续处理任务时（iOS 17–25、设置关闭、系统拒绝或提前结束）：进入后台申请有限的后台时间；
///   时间耗尽时暂停并登记 BGProcessingTask，系统在合适时机（通常是充电 + 联网）唤醒后继续，回到前台也会继续。
@MainActor
enum BackgroundDownloads {
    private static let bundleID = Bundle.main.bundleIdentifier ?? "EhViewer"
    /// 后台处理任务的标识，Info.plist 中声明为 `$(PRODUCT_BUNDLE_IDENTIFIER).download`。
    /// 从 Info.plist 读取，签名工具改了 Bundle ID（Info.plist 中的标识不会跟着改）后也与声明一致
    static let taskIdentifier: String = {
        let permitted = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String]
        return permitted?.first { $0.hasSuffix(".download") } ?? "\(bundleID).download"
    }()
    /// 持续处理任务的标识前缀，Info.plist 中声明为 `$(PRODUCT_BUNDLE_IDENTIFIER).continuedDownload.*`。
    /// 系统要求以 Bundle ID 开头，所以签名工具改了 Bundle ID 后无法使用（注册失败，退回有限的后台时间）
    static let continuedIdentifierPrefix = "\(bundleID).continuedDownload"
    /// 设置：切到后台后继续下载（UserDefaults，默认开启）
    static let continuedEnabledKey = "download_continue_in_background"

    private static var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private static weak var model: AppModel?

    static var isContinuedEnabled: Bool {
        UserDefaults.standard.object(forKey: continuedEnabledKey) as? Bool ?? true
    }

    /// 必须在 App 启动完成前调用（App.init 中）
    static func register(model: AppModel) {
        Self.model = model
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            guard let task = task as? BGProcessingTask else { task.setTaskCompleted(success: false); return }
            Task { @MainActor in handle(task) }
        }
        observeDownloads()
    }

    // MARK: 持续处理任务

    /// 持续处理任务是否正在运行（运行时不需要后台时间，也不能在 30 秒后暂停下载）
    static var isContinuedRunning: Bool {
        if #available(iOS 26, *) { return ContinuedDownloadSession.current != nil }
        return false
    }

    /// 下载从无到有时（开始下载、恢复下载）申请持续处理任务
    private static func observeDownloads() {
        guard let model else { return }
        withObservationTracking {
            _ = model.downloads.hasActiveDownloads
        } onChange: {
            Task { @MainActor in
                if model.downloads.hasActiveDownloads, UIApplication.shared.applicationState == .active {
                    requestContinuedProcessing(reason: "downloads")
                }
                observeDownloads()
            }
        }
    }

    /// 即将离开 App（scenePhase 变为 inactive）：还有下载而没有任务时补交
    static func willResignActive() {
        requestContinuedProcessing(reason: "resign")
    }

    private static func requestContinuedProcessing(reason: String) {
        guard isContinuedEnabled, let model else { return }
        if #available(iOS 26, *) {
            ContinuedDownloadSession.submitIfNeeded(model: model, reason: reason)
        }
    }

    /// 设置关闭时结束正在运行的任务
    static func stopContinuedProcessing() {
        if #available(iOS 26, *) { ContinuedDownloadSession.current?.stop() }
    }

    // MARK: 前后台

    static func didEnterBackground() {
        guard let model else { return }
        let needsTime = model.downloads.enterBackground()
        log("进入后台：\(needsTime ? "有下载" : "无下载")\(isContinuedRunning ? "，持续处理任务运行中" : "")")
        guard needsTime, backgroundTask == .invalid, !isContinuedRunning else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "download") {
            // 期间持续处理任务开始运行了：不暂停
            if isContinuedRunning {
                endBackgroundTask()
                return
            }
            log("后台时间耗尽，暂停下载并登记后台处理任务")
            model.downloads.backgroundTimeWillExpire()
            schedule()
            endBackgroundTask()
        }
    }

    static func willEnterForeground() {
        endBackgroundTask()
        if let model { log("回到前台：\(model.downloads.isSuspended ? "恢复暂停的下载" : "继续")") }
        model?.downloads.enterForeground()
    }

    private static func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    static func schedule() {
        let request = BGProcessingTaskRequest(identifier: taskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handle(_ task: BGProcessingTask) {
        guard let model else { task.setTaskCompleted(success: false); return }
        let downloads = model.downloads
        log("后台处理任务开始")
        // 以“前台”语义恢复队列，期间每隔几秒检查是否下载完
        downloads.enterForeground()
        let watcher = Task { @MainActor in
            while !Task.isCancelled, downloads.hasActiveDownloads {
                try? await Task.sleep(for: .seconds(5))
            }
            if !Task.isCancelled {
                log("后台处理任务完成")
                task.setTaskCompleted(success: true)
            }
        }
        task.expirationHandler = {
            Task { @MainActor in
                watcher.cancel()
                log("后台处理任务到期")
                downloads.backgroundTimeWillExpire()
                if downloads.hasActiveDownloads || !downloads.waitList.isEmpty { schedule() }
                task.setTaskCompleted(success: false)
            }
        }
    }

    static func log(_ message: String) {
        DownloadLog.write(message)
    }
}

/// 一次持续处理任务（iOS 26+）：覆盖从提交时起加入的全部下载（画廊与归档），全部完成后结束。
/// 每秒向系统汇报进度（每个画廊 / 归档各占 1000 份），系统据此判断任务没有停滞。
@available(iOS 26, *)
@MainActor
final class ContinuedDownloadSession {
    private(set) static var current: ContinuedDownloadSession?
    /// 已提交、尚未开始运行的任务
    private static var pendingIdentifier: String?

    private let task: BGContinuedProcessingTask
    private let model: AppModel
    private var gids: [Int64] = []
    private var gidSet: Set<Int64> = []
    private var archives: [Int64] = []
    private var archiveSet: Set<Int64> = []
    private var monitor: Task<Void, Never>?
    private var lastSubtitle = ""
    private var lastTitle = ""
    private var lastBackgroundLog = Date.distantPast

    private init(task: BGContinuedProcessingTask, model: AppModel) {
        self.task = task
        self.model = model
    }

    static func submitIfNeeded(model: AppModel, reason: String) {
        guard current == nil, pendingIdentifier == nil, model.downloads.hasActiveDownloads else { return }
        guard UIApplication.shared.applicationState != .background else { return }
        // 每次提交使用新的标识（同一标识只能注册一次）
        let identifier = "\(BackgroundDownloads.continuedIdentifierPrefix).\(UUID().uuidString)"
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            MainActor.assumeIsolated {
                guard let task = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                start(task, model: model, identifier: identifier)
            }
        }
        guard registered else {
            BackgroundDownloads.log("持续处理任务：注册失败（Info.plist 未声明标识）")
            return
        }
        let (title, subtitle) = describe(model)
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
        request.strategy = .queue
        do {
            try BGTaskScheduler.shared.submit(request)
            pendingIdentifier = identifier
            BackgroundDownloads.log("持续处理任务：已提交（\(reason)）")
        } catch {
            BackgroundDownloads.log("持续处理任务：提交失败（\(reason)）\(error)")
        }
    }

    private static func start(_ task: BGContinuedProcessingTask, model: AppModel, identifier: String) {
        if pendingIdentifier == identifier { pendingIdentifier = nil }
        guard current == nil else {
            task.setTaskCompleted(success: true)
            return
        }
        let session = ContinuedDownloadSession(task: task, model: model)
        current = session
        BackgroundDownloads.log("持续处理任务：开始运行")
        session.run()
    }

    private func run() {
        task.expirationHandler = { [weak self] in
            DispatchQueue.main.async { self?.expire() }
        }
        monitor = Task { [weak self] in
            while let self, !Task.isCancelled {
                guard await self.tick() else {
                    self.finish()
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// 更新进度与标题；返回是否还有下载
    private func tick() async -> Bool {
        let dm = model.downloads
        let active = [dm.currentGid].compactMap { $0 } + dm.waitList
        for gid in active where gidSet.insert(gid).inserted { gids.append(gid) }
        let activeArchives = await model.archiver.activeGids
        for gid in activeArchives where archiveSet.insert(gid).inserted { archives.append(gid) }

        let activeSet = Set(active)
        var done: Int64 = 0
        for gid in gids {
            // 已离开队列（完成、失败、暂停、删除）的按完成计
            guard activeSet.contains(gid), let info = dm.downloadInfo(gid) else { done += 1000; continue }
            if info.total > 0 { done += Int64(1000 * min(info.finished, info.total) / info.total) }
        }
        let activeArchiveSet = Set(activeArchives)
        for gid in archives {
            guard activeArchiveSet.contains(gid) else { done += 1000; continue }
            if let p = await model.archiver.progress(gid: gid), p.total > 0 {
                done += 1000 * min(p.downloaded, p.total) / p.total
            }
        }
        let total = Int64(gids.count + archives.count) * 1000
        task.progress.totalUnitCount = max(total, 1)
        task.progress.completedUnitCount = min(done, total)

        let (title, subtitle) = Self.describe(model, archives: activeArchives.count)
        if title != lastTitle || subtitle != lastSubtitle {
            task.updateTitle(title, subtitle: subtitle)
            lastTitle = title
            lastSubtitle = subtitle
        }
        if UIApplication.shared.applicationState == .background, Date().timeIntervalSince(lastBackgroundLog) >= 30 {
            lastBackgroundLog = Date()
            BackgroundDownloads.log("后台下载中：\(subtitle)，总进度 \(done * 100 / max(total, 1))%")
        }
        return dm.hasActiveDownloads || !activeArchives.isEmpty
    }

    /// 系统界面中显示的标题与副标题
    private static func describe(_ model: AppModel, archives: Int = 0) -> (String, String) {
        let dm = model.downloads
        let remaining = (dm.currentGid == nil ? 0 : 1) + dm.waitList.count
        let title: String
        if remaining > 1 {
            title = "正在下载 \(remaining) 个画廊"
        } else if remaining == 0, archives > 0 {
            title = "正在下载归档"
        } else {
            title = "正在下载"
        }
        guard let gid = dm.currentGid, let info = dm.downloadInfo(gid) else {
            return (title, remaining > 0 ? "等待中" : "")
        }
        let progress = info.total > 0 ? " · \(info.finished)/\(info.total)" : ""
        return (title, model.title(of: info.galleryInfo) + progress)
    }

    /// 系统要求结束（资源紧张、用户在系统界面中取消）
    private func expire() {
        guard Self.current === self else { return }
        monitor?.cancel()
        let inBackground = UIApplication.shared.applicationState == .background
        BackgroundDownloads.log("持续处理任务：被系统结束（\(inBackground ? "后台" : "前台")），\(lastSubtitle)")
        if inBackground {
            // 与后台时间耗尽相同：暂停并放回队首，回到前台或后台处理任务时继续
            model.downloads.backgroundTimeWillExpire()
            BackgroundDownloads.schedule()
        }
        task.setTaskCompleted(success: false)
        Self.current = nil
    }

    private func finish() {
        guard Self.current === self else { return }
        BackgroundDownloads.log("持续处理任务：下载全部结束")
        task.setTaskCompleted(success: true)
        Self.current = nil
    }

    /// 用户在设置中关闭
    func stop() {
        guard Self.current === self else { return }
        monitor?.cancel()
        BackgroundDownloads.log("持续处理任务：设置关闭")
        task.setTaskCompleted(success: true)
        Self.current = nil
    }
}
