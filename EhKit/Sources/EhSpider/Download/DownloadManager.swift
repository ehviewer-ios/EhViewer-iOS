import EhStorage
import Foundation
import Observation

/// 下载事件（供 App 层发通知）。对应 Android `DownloadManager.DownloadListener`
public enum DownloadEvent: Sendable, Hashable {
    case started(DownloadInfo)
    /// 速度 / 剩余时间更新（每 2 秒）
    case progress(DownloadInfo)
    /// 有页面完成
    case pageFinished(DownloadInfo)
    /// 画廊下载结束（state 为 FINISH 或 FAILED）
    case finished(DownloadInfo)
    case cancelled(DownloadInfo)
    case got509
}

/// 下载管理。对应 Android `download/DownloadManager.java`（+ `DownloadService` 的动作分发）。
///
/// - 状态数值与 `DownloadInfo.state*` 一致（NONE=0 / WAIT=1 / DOWNLOAD=2 / FINISH=3 / FAILED=4），直接持久化到 `EhDatabase`
/// - 同一时间只下载一个画廊（与 Android 一致），其余在等待队列
/// - 每个画廊通过 `GalleryLoaderRegistry` 以下载模式获取 `GalleryLoader`（可与阅读器共享）
/// - iOS 后台：App 层在进入后台 / 后台时间将尽 / 回到前台时调用 `enterBackground()` / `backgroundTimeWillExpire()` / `enterForeground()`
@MainActor
@Observable
public final class DownloadManager {
    public nonisolated static let defaultArchiverLabel = "档案"

    @ObservationIgnored public let database: EhDatabase
    @ObservationIgnored public let registry: GalleryLoaderRegistry
    @ObservationIgnored public var location: DownloadLocation
    @ObservationIgnored public var spiderInfoCache: SpiderInfoCache?
    /// 对应 `Settings.getDownloadOrder()`：true 时批量开始按列表顺序入队
    @ObservationIgnored public var downloadOrderAsc: Bool
    /// 速度统计周期（Android 为 2 秒）
    @ObservationIgnored public var speedInterval: Duration = .seconds(2)
    @ObservationIgnored let now: @Sendable () -> Int64

    // MARK: 可观察状态

    /// gid → 下载项
    public private(set) var infos: [Int64: DownloadInfo] = [:]
    /// 全部下载项的顺序（对应 mAllInfoList，默认 TIME 降序）
    public private(set) var order: [Int64] = []
    /// 标签（TIME 升序）。不含默认标签（nil）
    public private(set) var labelList: [DownloadLabel] = []
    /// 等待队列（gid）
    public private(set) var waitList: [Int64] = []
    /// 当前下载的 gid
    public private(set) var currentGid: Int64?
    /// 因后台时间耗尽而暂停（回到前台后自动继续）
    public private(set) var isSuspended = false
    public private(set) var isInBackground = false

    // MARK: 内部

    /// 当前任务获取加载器的 Task（释放时等待它完成后再 release，保证与后续 obtain 的顺序）
    @ObservationIgnored private var currentObtain: Task<(GalleryLoader, AsyncStream<LoaderEvent>), Never>?
    @ObservationIgnored private var currentGeneration: UUID?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var registryChain: Task<Void, Never>?
    @ObservationIgnored private var speedTask: Task<Void, Never>?
    @ObservationIgnored private let speed = SpeedReminder()
    @ObservationIgnored private let broadcaster = EventBroadcaster<DownloadEvent>()

    /// - Parameters:
    ///   - restorePending: 为 true 时把数据库中处于 WAIT / DOWNLOAD 的项重新排队（用于 App 被系统终止后恢复）。
    ///     Android 启动时一律重置为 NONE（默认行为）
    public init(database: EhDatabase, registry: GalleryLoaderRegistry, location: DownloadLocation,
                spiderInfoCache: SpiderInfoCache? = nil, downloadOrderAsc: Bool = true, restorePending: Bool = false,
                now: @escaping @Sendable () -> Int64 = EhDatabase.currentTimeMillis) {
        self.database = database
        self.registry = registry
        self.location = location
        self.spiderInfoCache = spiderInfoCache
        self.downloadOrderAsc = downloadOrderAsc
        self.now = now
        reloadFromDatabase(restorePending: restorePending)
    }

    /// 从数据库重新加载（对应构造函数逻辑）
    public func reloadFromDatabase(restorePending: Bool = false) {
        var labels = (try? database.allDownloadLabels()) ?? []
        let all = (try? database.allDownloadInfo()) ?? []
        var map: [Int64: DownloadInfo] = [:]
        var ids: [Int64] = []
        var pending: [Int64] = []
        for var info in all {
            if let label = info.label, !labels.contains(where: { $0.label == label }) {
                if let added = try? database.addDownloadLabel(label) { labels.append(added) }
            }
            if restorePending, let raw = try? database.downloadInfo(gid: info.gid),
               raw.state == DownloadInfo.stateWait || raw.state == DownloadInfo.stateDownload {
                info.state = DownloadInfo.stateWait
                pending.append(info.gid)
            }
            if map[info.gid] == nil { ids.append(info.gid) }
            map[info.gid] = info
        }
        labelList = labels
        infos = map
        order = ids
        waitList = pending
        if !pending.isEmpty { ensureDownload() }
    }

    /// 订阅下载事件（每次访问一个新订阅）
    public nonisolated var events: AsyncStream<DownloadEvent> { broadcaster.subscribe() }

    // MARK: - 查询

    /// 全部下载项（顺序同 Android mAllInfoList）
    public var allInfoList: [DownloadInfo] { order.compactMap { infos[$0] } }

    /// 某标签的下载项；nil 为默认标签（对应 getDefaultDownloadInfoList / getLabelDownloadInfoList）
    public func downloadInfoList(label: String?) -> [DownloadInfo] {
        order.compactMap { infos[$0] }.filter { $0.label == label }
    }

    public func labelCount(_ label: String?) -> Int {
        infos.values.reduce(0) { $0 + ($1.label == label ? 1 : 0) }
    }

    public func containLabel(_ label: String?) -> Bool {
        guard let label else { return false }
        return labelList.contains { $0.label == label }
    }

    public func containDownloadInfo(_ gid: Int64) -> Bool { infos[gid] != nil }
    public func downloadInfo(_ gid: Int64) -> DownloadInfo? { infos[gid] }

    /// 对应 `getDownloadState`：不存在时为 INVALID
    public func downloadState(_ gid: Int64) -> Int { infos[gid]?.state ?? DownloadInfo.stateInvalid }

    /// 对应 `isIdle`
    public var isIdle: Bool { currentGid == nil && waitList.isEmpty }

    /// 有下载在进行或排队（App 据此决定是否申请后台时间）
    public var hasActiveDownloads: Bool { !isIdle }

    /// 已存在的下载目录（不创建）
    public func downloadDirectory(for gid: Int64) -> URL? {
        guard let dir = location.existingGalleryDownloadDir(gid: gid), ImageFiles.isDirectory(dir) else { return nil }
        return dir
    }

    // MARK: - 内部工具

    private func persist(_ gid: Int64) {
        guard let info = infos[gid] else { return }
        try? database.putDownloadInfo(info)
    }

    private func update(_ gid: Int64, persist shouldPersist: Bool = false, _ body: (inout DownloadInfo) -> Void) {
        guard var info = infos[gid] else { return }
        body(&info)
        infos[gid] = info
        if shouldPersist { try? database.putDownloadInfo(info) }
    }

    private func sortOrderByTimeDesc() {
        // 稳定排序：TIME 降序
        let indexed = order.enumerated().map { ($0.offset, $0.element) }
        order = indexed.sorted { a, b in
            let ta = infos[a.1]?.time ?? 0, tb = infos[b.1]?.time ?? 0
            return ta != tb ? ta > tb : a.0 < b.0
        }.map(\.1)
    }

    private func ensureLabelExists(_ label: String?) {
        guard let label, !containLabel(label) else { return }
        if let raw = try? database.addDownloadLabel(label) { labelList.append(raw) }
    }

    /// 串行执行注册表操作，保证 obtain / release 的先后顺序
    private func enqueueRegistryOp(_ op: @escaping @Sendable () async -> Void) {
        let previous = registryChain
        registryChain = Task {
            await previous?.value
            await op()
        }
    }

    // MARK: - 调度（对应 ensureDownload）

    private func ensureDownload() {
        guard currentGid == nil, !isSuspended else { return }
        while !waitList.isEmpty {
            let gid = waitList.removeFirst()
            guard infos[gid] != nil else { continue }
            startCurrent(gid)
            return
        }
    }

    private func startCurrent(_ gid: Int64) {
        update(gid, persist: true) { info in
            info.state = DownloadInfo.stateDownload
            info.speed = -1
            info.remaining = -1
            info.total = -1
            info.finished = 0
            info.downloaded = 0
            info.legacy = -1
        }
        guard let info = infos[gid] else { return }
        currentGid = gid
        let generation = UUID()
        currentGeneration = generation
        startSpeedReminder()
        broadcaster.yield(.started(info))

        let galleryInfo = info.galleryInfo
        let registry = registry
        // obtain 也走串行链；await Task.value 不受取消影响，保证拿到的加载器一定会被释放
        let previous = registryChain
        let obtainTask = Task {
            await previous?.value
            return await registry.obtainWithEvents(galleryInfo, mode: .download)
        }
        registryChain = Task { _ = await obtainTask.value }
        currentObtain = obtainTask
        eventTask = Task { [weak self] in
            let (_, events) = await obtainTask.value
            guard let self, self.currentGeneration == generation, !Task.isCancelled else { return }
            for await event in events {
                guard self.currentGeneration == generation else { break }
                self.handle(event, gid: gid)
            }
        }
    }

    /// 释放当前任务的加载器（release 排在串行链上，位于之后任何 obtain 之前）
    private func releaseCurrentLoader() {
        currentGeneration = nil
        eventTask?.cancel()
        eventTask = nil
        if let obtain = currentObtain {
            let registry = registry
            enqueueRegistryOp {
                let (loader, _) = await obtain.value
                await registry.release(loader, mode: .download)
            }
        }
        currentObtain = nil
    }

    private func handle(_ event: LoaderEvent, gid: Int64) {
        switch event {
        case let .pageCount(pages):
            update(gid) { $0.total = pages }
        case let .pageProgress(index, received, total):
            speed.onDownload(index: index, contentLength: total ?? -1, receivedSize: received)
        case let .pageLoaded(index, _, progress):
            speed.onDone(index: index)
            update(gid) {
                $0.finished = progress.finished
                $0.downloaded = progress.downloaded
                $0.total = progress.total
            }
            if let info = infos[gid] { broadcaster.yield(.pageFinished(info)) }
        case let .pageFailed(index, _, progress):
            speed.onDone(index: index)
            update(gid) {
                $0.finished = progress.finished
                $0.downloaded = progress.downloaded
                $0.total = progress.total
            }
        case .got509:
            broadcaster.yield(.got509)
        case let .finished(progress, downloadMode):
            guard downloadMode else { return }
            finishCurrent(gid, progress: progress)
        case .error:
            break
        }
    }

    /// 对应 NotifyTask TYPE_ON_FINISH
    private func finishCurrent(_ gid: Int64, progress: LoaderProgress) {
        guard currentGid == gid else { return }
        speed.onFinish()
        releaseCurrentLoader()
        currentGid = nil
        stopSpeedReminder()
        update(gid, persist: true) { info in
            info.finished = progress.finished
            info.downloaded = progress.downloaded
            info.total = progress.total
            info.legacy = progress.total - progress.finished
            info.state = info.legacy == 0 ? DownloadInfo.stateFinish : DownloadInfo.stateFailed
        }
        if let info = infos[gid] { broadcaster.yield(.finished(info)) }
        ensureDownload()
    }

    // MARK: - 开始

    /// 对应 `startDownload(GalleryInfo, label)`
    public func startDownload(_ galleryInfo: GalleryInfo, label: String?) {
        if currentGid == galleryInfo.gid { return }
        if let info = infos[galleryInfo.gid] {
            if info.archiveUri != nil { return }
            if info.state != DownloadInfo.stateWait {
                update(info.gid, persist: true) { $0.state = DownloadInfo.stateWait }
                waitList.append(info.gid)
                ensureDownload()
            }
            return
        }
        // 与 Android 不同：标签不存在时自动创建（Android 静默放弃）
        ensureLabelExists(label)
        let info = DownloadInfo(galleryInfo, state: DownloadInfo.stateWait, time: now(), label: label)
        infos[info.gid] = info
        order.insert(info.gid, at: 0)
        waitList.append(info.gid)
        try? database.putDownloadInfo(info)
        ensureDownload()
        try? database.putHistoryInfo(galleryInfo)
    }

    /// 对应 `startRangeDownload`：NONE / FAILED / FINISH 的项入队
    public func startRangeDownload(_ gids: [Int64]) {
        var changed = false
        let seq: [Int64] = downloadOrderAsc ? gids : gids.reversed()
        for gid in seq {
            guard let info = infos[gid], info.archiveUri == nil else { continue }
            if info.state == DownloadInfo.stateNone || info.state == DownloadInfo.stateFailed
                || info.state == DownloadInfo.stateFinish {
                changed = true
                update(gid, persist: true) { $0.state = DownloadInfo.stateWait }
                waitList.append(gid)
            }
        }
        if changed { ensureDownload() }
    }

    /// 对应 `startAllDownload`：NONE / FAILED 的项入队
    public func startAllDownload() {
        var changed = false
        for gid in order {
            guard let info = infos[gid], info.archiveUri == nil else { continue }
            if info.state == DownloadInfo.stateNone || info.state == DownloadInfo.stateFailed {
                changed = true
                update(gid, persist: true) { $0.state = DownloadInfo.stateWait }
                if downloadOrderAsc { waitList.append(gid) } else { waitList.insert(gid, at: 0) }
            }
        }
        if changed { ensureDownload() }
    }

    // MARK: - 添加（不下载）

    /// 对应 `addDownload(List<DownloadInfo>)`（导入 / 数据迁移）
    public func addDownload(_ list: [DownloadInfo]) {
        for var info in list where infos[info.gid] == nil {
            if info.state == DownloadInfo.stateWait || info.state == DownloadInfo.stateDownload {
                info.state = DownloadInfo.stateNone
            }
            ensureLabelExists(info.label)
            infos[info.gid] = info
            order.append(info.gid)
            try? database.putDownloadInfo(info)
        }
        sortOrderByTimeDesc()
    }

    /// 对应 `addDownloadLabel(List<DownloadLabel>)`
    public func addDownloadLabels(_ labels: [DownloadLabel]) {
        for raw in labels {
            guard let l = raw.label, !containLabel(l) else { continue }
            if let added = try? database.addDownloadLabel(raw) { labelList.append(added) }
        }
    }

    /// 对应 `addDownload(GalleryInfo, label, state)`
    public func addDownload(_ galleryInfo: GalleryInfo, label: String?, state: Int = DownloadInfo.stateNone) {
        guard infos[galleryInfo.gid] == nil else { return }
        ensureLabelExists(label)
        var info = DownloadInfo(galleryInfo, state: state, time: now(), label: label)
        if state == DownloadInfo.stateWait || state == DownloadInfo.stateDownload { info.state = DownloadInfo.stateNone }
        infos[info.gid] = info
        order.insert(info.gid, at: 0)
        try? database.putDownloadInfo(info)
    }

    /// 标记为已完成（归档导入等）
    func markFinished(_ gid: Int64, pages: Int) {
        waitList.removeAll { $0 == gid }
        update(gid, persist: true) {
            $0.state = DownloadInfo.stateFinish
            $0.legacy = 0
            $0.total = pages
            $0.finished = pages
            $0.downloaded = pages
        }
    }

    /// 更新已存在下载项的元数据（标题、封面等），保留状态与标签
    public func updateGalleryInfo(_ galleryInfo: GalleryInfo) {
        update(galleryInfo.gid, persist: true) { $0.copyGalleryInfo(galleryInfo) }
    }

    // MARK: - 停止

    /// 对应 `stopDownloadInternal`（不调 ensureDownload）
    @discardableResult
    private func stopDownloadInternal(_ gid: Int64) -> DownloadInfo? {
        if currentGid == gid { return stopCurrentDownloadInternal() }
        if let i = waitList.firstIndex(of: gid) {
            waitList.remove(at: i)
            update(gid, persist: true) { $0.state = DownloadInfo.stateNone }
            return infos[gid]
        }
        return nil
    }

    /// 对应 `stopCurrentDownloadInternal`
    @discardableResult
    private func stopCurrentDownloadInternal(newState: Int = DownloadInfo.stateNone) -> DownloadInfo? {
        let gid = currentGid
        releaseCurrentLoader()
        currentGid = nil
        stopSpeedReminder()
        guard let gid else { return nil }
        update(gid, persist: true) { $0.state = newState }
        if let info = infos[gid] { broadcaster.yield(.cancelled(info)) }
        return infos[gid]
    }

    public func stopDownload(_ gid: Int64) {
        if stopDownloadInternal(gid) != nil { ensureDownload() }
    }

    public func stopCurrentDownload() {
        if stopCurrentDownloadInternal() != nil { ensureDownload() }
    }

    public func stopRangeDownload(_ gids: [Int64]) {
        let set = Set(gids)
        if let c = currentGid, set.contains(c) { stopCurrentDownloadInternal() }
        let stopped = waitList.filter { set.contains($0) }
        waitList.removeAll { set.contains($0) }
        for gid in stopped { update(gid, persist: true) { $0.state = DownloadInfo.stateNone } }
        ensureDownload()
    }

    /// 对应 `stopAllDownload`
    public func stopAllDownload() {
        for gid in waitList { update(gid, persist: true) { $0.state = DownloadInfo.stateNone } }
        waitList.removeAll()
        stopCurrentDownloadInternal()
        isSuspended = false
    }

    // MARK: - 删除

    /// 对应 `deleteDownload`。deleteFiles 为 true 时同时删除下载目录、目录名记录与阅读进度缓存
    public func deleteDownload(_ gid: Int64, deleteFiles: Bool = false) {
        stopDownloadInternal(gid)
        guard let info = infos[gid] else { return }
        removeEntry(info, deleteFiles: deleteFiles)
        ensureDownload()
    }

    public func deleteRangeDownload(_ gids: [Int64], deleteFiles: Bool = false) {
        let set = Set(gids)
        if let c = currentGid, set.contains(c) { stopCurrentDownloadInternal() }
        waitList.removeAll { set.contains($0) }
        for gid in gids {
            guard let info = infos[gid] else { continue }
            removeEntry(info, deleteFiles: deleteFiles)
        }
        ensureDownload()
    }

    private func removeEntry(_ info: DownloadInfo, deleteFiles: Bool) {
        try? database.removeDownloadInfo(gid: info.gid)
        infos.removeValue(forKey: info.gid)
        order.removeAll { $0 == info.gid }
        guard deleteFiles else { return }
        if let dir = location.existingGalleryDownloadDir(gid: info.gid) {
            try? FileManager.default.removeItem(at: dir)
        }
        try? database.removeDownloadDirname(gid: info.gid)
        spiderInfoCache?.remove(gid: info.gid)
        // 导入时复制进 App 的压缩包一并删除
        if let s = info.archiveUri, let u = URL(string: s), u.isFileURL, let root = location.root,
           u.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path) {
            try? FileManager.default.removeItem(at: u)
        }
    }

    // MARK: - 标签

    /// 对应 `changeLabel`（label 必须已存在；nil 为默认）
    public func changeLabel(_ gids: [Int64], to label: String?) {
        if let label, !containLabel(label) { return }
        for gid in gids {
            guard let info = infos[gid], info.label != label else { continue }
            update(gid, persist: true) { $0.label = label }
        }
    }

    public func addLabel(_ label: String?) {
        ensureLabelExists(label)
    }

    /// 对应 `moveLabel`
    public func moveLabel(from: Int, to: Int) {
        guard from != to, labelList.indices.contains(from), labelList.indices.contains(to) else { return }
        try? database.moveDownloadLabel(from: from, to: to)
        labelList = (try? database.allDownloadLabels()) ?? labelList
    }

    /// 对应 `renameLabel`
    public func renameLabel(from: String, to: String) {
        guard let i = labelList.firstIndex(where: { $0.label == from }) else { return }
        labelList[i].label = to
        try? database.updateDownloadLabel(labelList[i])
        for gid in order where infos[gid]?.label == from {
            update(gid, persist: true) { $0.label = to }
        }
    }

    /// 对应 `deleteLabel`：该标签下的项移到默认标签
    public func deleteLabel(_ label: String) {
        guard let i = labelList.firstIndex(where: { $0.label == label }) else { return }
        let raw = labelList.remove(at: i)
        try? database.removeDownloadLabel(raw)
        for gid in order where infos[gid]?.label == label {
            update(gid, persist: true) { $0.label = nil }
        }
    }

    // MARK: - 排序

    /// 拖动重排：在某标签（nil 为默认；allLabels 为 true 时在全部列表）内把 from 移到 to。
    /// 对应 `DownloadAdapter.onMoveItem` → `EhDB.moveDownloadInfo`（轮换 TIME）
    public func moveDownload(label: String?, allLabels: Bool = false, from: Int, to: Int) {
        var list = allLabels ? allInfoList : downloadInfoList(label: label)
        guard from != to, list.indices.contains(from), list.indices.contains(to) else { return }
        try? database.moveDownloadInfo(&list, from: from, to: to)
        for item in list {
            update(item.gid) { $0.time = item.time }
        }
        sortOrderByTimeDesc()
    }

    // MARK: - 阅读进度

    /// 对应 `resetAllReadingProgress`：内存中的加载器与下载目录 / 缓存中的 `.ehviewer` 一起重置
    public func resetAllReadingProgress() async {
        let gids = order
        for gid in gids { await registry.resetReadingProgress(gid: gid) }
        let location = location
        let cache = spiderInfoCache
        await Task.detached {
            for gid in gids {
                guard let dir = location.existingGalleryDownloadDir(gid: gid) else { continue }
                let file = dir.appendingPathComponent(SpiderNaming.spiderInfoFilename)
                guard var info = SpiderInfo.read(contentsOf: file) else { continue }
                info.startPage = 0
                try? info.write(to: file)
                cache?.write(info)
            }
        }.value
    }

    // MARK: - 速度（对应 SpeedReminder）

    private func startSpeedReminder() {
        speed.reset()
        speedTask?.cancel()
        let interval = speedInterval
        speedTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                self.tickSpeed(interval: interval)
            }
        }
    }

    private func stopSpeedReminder() {
        speedTask?.cancel()
        speedTask = nil
        speed.reset()
    }

    private func tickSpeed(interval: Duration) {
        guard let gid = currentGid, let info = infos[gid] else { return }
        let seconds = max(Double(interval.components.seconds) + Double(interval.components.attoseconds) / 1e18, 0.001)
        let (newSpeed, remaining) = speed.tick(seconds: seconds, total: info.total, downloaded: info.downloaded)
        update(gid) {
            $0.speed = newSpeed
            $0.remaining = remaining
        }
        if let info = infos[gid] { broadcaster.yield(.progress(info)) }
    }

    // MARK: - iOS 后台

    /// App 进入后台时调用。保存当前进度；返回是否有下载需要后台时间（App 据此 `beginBackgroundTask`）
    @discardableResult
    public func enterBackground() -> Bool {
        isInBackground = true
        if let gid = currentGid { persist(gid) }
        return hasActiveDownloads
    }

    /// 后台时间即将耗尽时调用：暂停当前下载并放回队首（状态保持 WAIT），回到前台后自动继续
    public func backgroundTimeWillExpire() {
        guard let gid = currentGid else {
            if !waitList.isEmpty { isSuspended = true }
            return
        }
        isSuspended = true
        stopCurrentDownloadInternal(newState: DownloadInfo.stateWait)
        waitList.insert(gid, at: 0)
    }

    /// 回到前台时调用：恢复因后台暂停的下载
    public func enterForeground() {
        isInBackground = false
        if isSuspended {
            isSuspended = false
            ensureDownload()
        }
    }
}

/// 速度与剩余时间估算。对应 `DownloadManager.SpeedReminder`
final class SpeedReminder {
    private var bytesRead: Int64 = 0
    private var oldSpeed: Int64 = -1
    private var contentLength: [Int: Int64] = [:]
    private var receivedSize: [Int: Int64] = [:]

    func reset() {
        bytesRead = 0
        oldSpeed = -1
        contentLength.removeAll()
        receivedSize.removeAll()
    }

    func onDownload(index: Int, contentLength length: Int64, receivedSize received: Int64) {
        let last = receivedSize[index] ?? 0
        bytesRead += received >= last ? received - last : received
        contentLength[index] = length
        receivedSize[index] = received
    }

    func onDone(index: Int) {
        contentLength.removeValue(forKey: index)
        receivedSize.removeValue(forKey: index)
    }

    func onFinish() {
        contentLength.removeAll()
        receivedSize.removeAll()
    }

    /// 返回 (速度 B/s, 剩余毫秒；-1 未知)
    func tick(seconds: Double, total: Int, downloaded: Int) -> (Int64, Int64) {
        var newSpeed = Int64(Double(bytesRead) / seconds)
        if oldSpeed != -1 {
            newSpeed = Int64(Double(oldSpeed) + (Double(newSpeed) - Double(oldSpeed)) * 0.75)
        }
        oldSpeed = newSpeed
        bytesRead = 0

        var remaining: Int64 = -1
        if total <= 0 {
            remaining = -1
        } else if newSpeed == 0 {
            remaining = 300 * 24 * 60 * 60 * 1000
        } else {
            var downloadingCount: Int64 = 0
            var lengthSum: Int64 = 0
            var totalSize: Int64 = 0
            for (index, length) in contentLength {
                let received = receivedSize[index] ?? 0
                downloadingCount += 1
                lengthSum += length
                totalSize += length - received
            }
            if downloadingCount != 0 {
                totalSize += lengthSum * (Int64(total) - Int64(downloaded) - downloadingCount) / downloadingCount
                remaining = totalSize / newSpeed * 1000
            }
        }
        return (newSpeed, remaining)
    }
}
