import EhNetwork
import Foundation

/// 归档下载事件。对应 `ArchiverDownloader.Listener`
public enum ArchiverEvent: Sendable, Hashable {
    case progress(ArchiverProgress)
    case success(gid: Int64, taskId: Int64, zip: URL)
    /// 下载或导入失败
    case failure(gid: Int64, taskId: Int64, error: String)
    case cancelled(gid: Int64, taskId: Int64)
    /// 解压导入完成
    case imported(gid: Int64, taskId: Int64)
}

/// 对应 `ArchiverDownloader.Progress`
public struct ArchiverProgress: Sendable, Hashable {
    public var gid: Int64
    public var taskId: Int64
    public var downloaded: Int64
    /// 总字节；未知为 0
    public var total: Int64
    /// B/s
    public var speed: Int64
    public var paused: Bool
    /// 剩余毫秒；未知为 -1
    public var remaining: Int64
}

/// 归档 zip 下载器（应用内下载，支持暂停 / 断点续传 / 启动后恢复）。对应 Android `download/ArchiverDownloader.kt`
/// （+ `ArchiverDownloadService` 的进度状态；通知由 App 层根据事件发送）。
///
/// - zip 保存在 `directory/{fileName}.zip`；任务状态持久化在 `directory/pending.json`（对应 Settings 中的 archiver_* 键）
/// - 续传时发送 `Range: bytes=offset-`；206 追加、200 重新开始、416 且文件已完整视为成功
/// - 下载完成后调用 `completion`（App 中通常为 `DownloadManager.importDownloadedArchive`）
public actor ArchiverDownloader {
    /// 持久化的任务
    public struct TaskRecord: Codable, Sendable, Hashable {
        public var taskId: Int64
        public var galleryInfo: GalleryInfo
        public var url: String
        public var fileName: String
        public var paused: Bool
        public var total: Int64
    }

    public typealias Completion = @Sendable (_ zip: URL, _ info: GalleryInfo, _ taskId: Int64) async throws -> Void

    private final class ActiveTask {
        var record: TaskRecord
        var task: Task<Void, Never>?
        var downloaded: Int64 = 0
        var speed: Int64 = 0
        var lastNotifyAt: ContinuousClock.Instant?
        var lastSpeedAt = ContinuousClock.now
        var bytesSinceSpeed: Int64 = 0
        init(record: TaskRecord) { self.record = record }
    }

    static let notifyInterval: Duration = .milliseconds(500)

    public let provider: any ArchiveProvider
    public let directory: URL
    private let stateFile: URL
    private var completion: Completion?
    private var active: [Int64: ActiveTask] = [:]
    private var nextTaskId: Int64
    private let broadcaster = EventBroadcaster<ArchiverEvent>()

    public init(provider: any ArchiveProvider, directory: URL, completion: Completion? = nil) {
        self.provider = provider
        self.directory = directory
        stateFile = directory.appendingPathComponent("pending.json")
        self.completion = completion
        nextTaskId = Int64(Date().timeIntervalSince1970 * 1000)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public nonisolated var events: AsyncStream<ArchiverEvent> { broadcaster.subscribe() }

    public func setCompletion(_ completion: Completion?) {
        self.completion = completion
    }

    public func zipURL(fileName: String) -> URL { directory.appendingPathComponent(fileName + ".zip") }

    /// 对应 `getProgress`
    public func progress(gid: Int64) -> ArchiverProgress? {
        active[gid].map(makeProgress)
    }

    public var activeGids: [Int64] { Array(active.keys) }

    // MARK: - 持久化（对应 Settings.putArchiverDownload*）

    private func loadRecords() -> [TaskRecord] {
        guard let data = try? Data(contentsOf: stateFile),
              let list = try? JSONDecoder().decode([TaskRecord].self, from: data) else { return [] }
        return list
    }

    private func saveRecords() {
        let list = active.values.map(\.record).sorted { $0.taskId < $1.taskId }
        if list.isEmpty {
            try? FileManager.default.removeItem(at: stateFile)
            return
        }
        if let data = try? JSONEncoder().encode(list) { try? data.write(to: stateFile, options: .atomic) }
    }

    // MARK: - 控制

    /// 对应 `start`：开始新任务（同 gid 的旧任务先取消）。返回 taskId
    @discardableResult
    public func start(_ info: GalleryInfo, url: String, fileName: String? = nil) -> Int64 {
        cancel(gid: info.gid)
        nextTaskId += 1
        let name = fileName ?? ArchiveExtractor.createFileName(info.title, gid: info.gid)
        let record = TaskRecord(taskId: nextTaskId, galleryInfo: info, url: url, fileName: name, paused: false, total: 0)
        let t = ActiveTask(record: record)
        active[info.gid] = t
        saveRecords()
        run(t, resume: false)
        return record.taskId
    }

    /// 对应 `pause`
    public func pause(gid: Int64) {
        guard let t = active[gid], !t.record.paused else { return }
        t.record.paused = true
        t.speed = 0
        saveRecords()
        t.task?.cancel()
        publish(t, force: true)
    }

    /// 对应 `resume`
    public func resume(gid: Int64) {
        guard let t = active[gid], t.record.paused else { return }
        t.record.paused = false
        saveRecords()
        run(t, resume: true)
    }

    /// 对应 `cancel`：停止并删除 zip
    public func cancel(gid: Int64) {
        guard let t = active.removeValue(forKey: gid) else { return }
        t.task?.cancel()
        t.task = nil
        try? FileManager.default.removeItem(at: zipURL(fileName: t.record.fileName))
        saveRecords()
        broadcaster.yield(.cancelled(gid: gid, taskId: t.record.taskId))
    }

    /// 对应 `resumePending`：App 启动后恢复未完成任务（暂停的保持暂停）
    public func resumePending() async {
        for record in loadRecords() where active[record.galleryInfo.gid] == nil {
            let t = ActiveTask(record: record)
            let zip = zipURL(fileName: record.fileName)
            let size = ImageFiles.fileSize(zip)
            active[record.galleryInfo.gid] = t
            if FileManager.default.fileExists(atPath: zip.path), record.total > 0, size >= record.total {
                active.removeValue(forKey: record.galleryInfo.gid)
                saveRecords()
                await complete(record, zip: zip)
                continue
            }
            if record.url.isEmpty {
                active.removeValue(forKey: record.galleryInfo.gid)
                broadcaster.yield(.failure(gid: record.galleryInfo.gid, taskId: record.taskId, error: SpiderMessages.unknown))
                continue
            }
            if record.paused {
                t.downloaded = size
                publish(t, force: true)
                continue
            }
            run(t, resume: true)
        }
        saveRecords()
    }

    // MARK: - 下载

    private func makeProgress(_ t: ActiveTask) -> ArchiverProgress {
        var remaining: Int64 = -1
        if !t.record.paused, t.record.total > 0, t.speed > 0 {
            let left = t.record.total - t.downloaded
            remaining = left <= 0 ? 0 : left * 1000 / t.speed
        }
        return ArchiverProgress(gid: t.record.galleryInfo.gid, taskId: t.record.taskId, downloaded: t.downloaded,
                                total: t.record.total, speed: t.speed, paused: t.record.paused, remaining: remaining)
    }

    private func publish(_ t: ActiveTask, force: Bool) {
        let now = ContinuousClock.now
        if !force, let last = t.lastNotifyAt, now - last < Self.notifyInterval { return }
        let elapsed = now - t.lastSpeedAt
        let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        if ms > 0 { t.speed = t.record.paused ? 0 : Int64(Double(t.bytesSinceSpeed) * 1000 / ms) }
        t.bytesSinceSpeed = 0
        t.lastSpeedAt = now
        t.lastNotifyAt = now
        broadcaster.yield(.progress(makeProgress(t)))
    }

    private func onBytes(_ gid: Int64, taskId: Int64, downloaded: Int64) {
        guard let t = active[gid], t.record.taskId == taskId, downloaded > t.downloaded else { return }
        t.bytesSinceSpeed += downloaded - t.downloaded
        t.downloaded = downloaded
        publish(t, force: false)
    }

    /// 从 Content-Range（"bytes a-b/total"）或 offset + Content-Length 得到总大小。对应 `resolveTotal`
    static func resolveTotal(contentRange: String?, offset: Int64, contentLength: Int64?) -> Int64 {
        if let cr = contentRange, let slash = cr.lastIndex(of: "/") {
            let s = cr[cr.index(after: slash)...].trimmingCharacters(in: .whitespaces)
            if s != "*", let v = Int64(s), v > 0 { return v }
        }
        if let cl = contentLength, cl > 0 { return offset + cl }
        return 0
    }

    private func run(_ t: ActiveTask, resume: Bool) {
        // 等上一次请求（暂停时被取消）把已下载部分写回 zip 之后再计算续传位置
        let previous = t.task
        let gid = t.record.galleryInfo.gid, taskId = t.record.taskId
        t.task = Task {
            await previous?.value
            await self.begin(gid: gid, taskId: taskId, resume: resume)
        }
    }

    private func begin(gid: Int64, taskId: Int64, resume: Bool) async {
        guard let t = active[gid], t.record.taskId == taskId, !t.record.paused, !Task.isCancelled else { return }
        let zip = zipURL(fileName: t.record.fileName)
        let fm = FileManager.default
        if !resume { try? fm.removeItem(at: zip) }
        let offset = resume && fm.fileExists(atPath: zip.path) ? ImageFiles.fileSize(zip) : 0
        t.downloaded = offset
        t.speed = 0
        t.bytesSinceSpeed = 0
        t.lastSpeedAt = .now
        t.lastNotifyAt = nil
        await download(t.record, zip: zip, offset: offset)
    }

    /// 单次请求。响应体写入 chunk 文件；为了暂停时保留已下载部分，首次回调时给 chunk 建一个硬链接
    private func download(_ record: TaskRecord, zip: URL, offset: Int64) async {
        let gid = record.galleryInfo.gid
        let taskId = record.taskId
        let fm = FileManager.default
        let chunk = directory.appendingPathComponent(record.fileName + ".zip.part")
        let keep = directory.appendingPathComponent(record.fileName + ".zip.keep")
        try? fm.removeItem(at: chunk)
        try? fm.removeItem(at: keep)
        let linked = LockedBox(false)
        let chunkTotal = LockedBox<Int64?>(nil)

        var response: ArchiveDownloadResponse?
        var failure: Error?
        do {
            response = try await provider.downloadArchive(url: record.url, to: chunk, offset: offset) { received, total in
                let needLink = linked.withLock { done -> Bool in
                    if done { return false }
                    done = true
                    return true
                }
                if needLink { try? FileManager.default.linkItem(at: chunk, to: keep) }
                chunkTotal.withLock { $0 = total }
                Task { await self.onBytes(gid, taskId: taskId, downloaded: offset + received) }
            }
        } catch {
            failure = error
        }

        guard let t = active[gid], t.record.taskId == taskId else {
            try? fm.removeItem(at: chunk)
            try? fm.removeItem(at: keep)
            return
        }
        // 暂停 / 取消：保留已下载部分
        if failure != nil || Task.isCancelled {
            let partial = fm.fileExists(atPath: keep.path) ? keep : (fm.fileExists(atPath: chunk.path) ? chunk : nil)
            if let partial {
                let total = chunkTotal.get
                let known = t.record.total
                if offset == 0 || (known > 0 && total.map({ $0 + offset == known }) ?? false) {
                    Self.append(partial, to: zip, replace: offset == 0)
                } else if known > 0, total == known {
                    // 服务器忽略了 Range，返回了完整文件
                    Self.append(partial, to: zip, replace: true)
                }
            }
            try? fm.removeItem(at: chunk)
            try? fm.removeItem(at: keep)
            if t.record.paused {
                t.downloaded = ImageFiles.fileSize(zip)
                publish(t, force: true)
                return
            }
            if let failure, !(failure is CancellationError), (failure as? EhError) != .cancelled {
                fail(t, SpiderMessages.readable(failure))
            }
            return
        }
        try? fm.removeItem(at: keep)
        guard let response else { return }

        if response.statusCode == 416 {
            try? fm.removeItem(at: chunk)
            let total = t.record.total
            if fm.fileExists(atPath: zip.path), total > 0, ImageFiles.fileSize(zip) >= total {
                await succeed(t, zip: zip)
            } else {
                fail(t, "HTTP 416")
            }
            return
        }
        guard (200 ..< 300).contains(response.statusCode) else {
            try? fm.removeItem(at: chunk)
            fail(t, "HTTP \(response.statusCode)")
            return
        }
        // 200 且 offset > 0：服务器不支持续传，重新开始（Android 会 toast 提示）
        let restart = response.statusCode == 200 && offset > 0
        let writeOffset = restart ? 0 : offset
        let total = Self.resolveTotal(contentRange: response.contentRange, offset: writeOffset,
                                      contentLength: response.contentLength)
        if total > 0 { t.record.total = total }
        Self.append(chunk, to: zip, replace: writeOffset == 0)
        try? fm.removeItem(at: chunk)
        t.downloaded = ImageFiles.fileSize(zip)
        if t.record.total > 0, t.downloaded < t.record.total {
            fail(t, SpiderMessages.incomplete)
            return
        }
        await succeed(t, zip: zip)
    }

    /// 把 src 追加到 dst（replace 时直接替换）
    static func append(_ src: URL, to dst: URL, replace: Bool) {
        let fm = FileManager.default
        if replace || !fm.fileExists(atPath: dst.path) {
            try? fm.removeItem(at: dst)
            try? fm.copyItem(at: src, to: dst)
            return
        }
        guard let out = try? FileHandle(forWritingTo: dst), let input = try? FileHandle(forReadingFrom: src) else { return }
        defer {
            try? out.close()
            try? input.close()
        }
        _ = try? out.seekToEnd()
        while let data = try? input.read(upToCount: 1 << 20), !data.isEmpty {
            try? out.write(contentsOf: data)
        }
    }

    private func fail(_ t: ActiveTask, _ message: String) {
        let gid = t.record.galleryInfo.gid
        active.removeValue(forKey: gid)
        try? FileManager.default.removeItem(at: zipURL(fileName: t.record.fileName))
        saveRecords()
        broadcaster.yield(.failure(gid: gid, taskId: t.record.taskId, error: message))
    }

    private func succeed(_ t: ActiveTask, zip: URL) async {
        let gid = t.record.galleryInfo.gid
        active.removeValue(forKey: gid)
        saveRecords()
        publish(t, force: true)
        await complete(t.record, zip: zip)
    }

    private func complete(_ record: TaskRecord, zip: URL) async {
        let gid = record.galleryInfo.gid
        broadcaster.yield(.success(gid: gid, taskId: record.taskId, zip: zip))
        guard let completion else { return }
        do {
            try await completion(zip, record.galleryInfo, record.taskId)
            broadcaster.yield(.imported(gid: gid, taskId: record.taskId))
        } catch {
            broadcaster.yield(.failure(gid: gid, taskId: record.taskId, error: SpiderMessages.readable(error)))
        }
    }
}
