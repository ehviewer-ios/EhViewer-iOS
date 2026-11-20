import Foundation

// MARK: - 数据存取接口

/// 迁移数据的读写接口。EhTransfer 中由 `EhDatabaseTransferStore`（EhDatabase + 下载目录）实现；
/// 测试中可用内存实现。方法可能在任意线程被调用。
public protocol TransferStore: Sendable {
    // 发送端读取（顺序与 Android 一致）
    /// `EhDB.getAllQuickSearch`（time 升序）
    func quickSearches() throws -> [TransferQuickSearch]
    /// `EhDB.getAllLocalFavorites`（time 降序）
    func localFavorites() throws -> [GalleryInfo]
    /// `EhDB.getAllDownloadLabelList`（time 升序）
    func downloadLabels() throws -> [String]
    /// `EhDB.getAllDownloadInfo`（time 降序）
    func downloadItems() throws -> [TransferDownloadItem]
    /// iOS 扩展：浏览历史（time 降序）
    func historyItems() throws -> [TransferHistoryItem]

    // 接收端写入（合并规则见各实现）
    /// `EhDB.takeOverQuickSearchList`
    func takeOverQuickSearches(_ list: [TransferQuickSearch]) throws
    /// `EhDB.putLocalFavorite` × N
    func putLocalFavorites(_ list: [GalleryInfo]) throws
    /// `DownloadManager.addLabelInSyncThread` × N
    func addDownloadLabels(_ labels: [String]) throws
    /// `DownloadManager.addDownloadInfo(info, info.label)` × N
    func addDownloadItems(_ items: [TransferDownloadItem]) throws
    /// iOS 扩展
    func putHistoryItems(_ items: [TransferHistoryItem]) throws
    /// `EhDB.putDownloadDirname`
    func putDownloadDirname(gid: Int64, dirname: String) throws
    func downloadDirname(gid: Int64) throws -> String?

    /// 下载根目录；nil 表示未设置（对应 Android `getDownloadRoot() == null`）
    var downloadRoot: URL? { get }
}

// MARK: - 事件

/// 传输进度
public struct TransferProgress: Sendable, Hashable {
    public enum Direction: Sendable, Hashable { case sending, receiving }

    public var direction: Direction
    public var kind: TransferDataKind
    /// 当前页 / 当前目录（1 起）
    public var current: Int
    /// 总页数 / 目录总数（接收端来自对端的 pageSize）
    public var total: Int
    /// 本页记录数（数据页）或本目录文件数
    public var itemCount: Int = 0
    /// 当前目录名（下载目录迁移）
    public var dirname: String?
    /// 当前文件（相对路径）
    public var fileName: String?
    /// 当前目录中已完成 / 需要传输的文件数
    public var fileIndex: Int = 0
    public var fileCount: Int = 0
    /// 当前目录中跳过（对端已有且 MD5 相同）的文件数
    public var skippedFiles: Int = 0
    /// 本次累计传输的文件字节数
    public var bytes: Int64 = 0

    public init(direction: Direction, kind: TransferDataKind, current: Int, total: Int) {
        self.direction = direction; self.kind = kind; self.current = current; self.total = total
    }
}

/// 传输事件（服务端 / 客户端 `events` 流的元素）
public enum TransferEvent: Sendable, Hashable {
    /// 服务端开始监听
    case listening(TransferServerInfo)
    /// 建立连接（对端地址描述）。对应 `DEVICE_CONNECTED`
    case connected(peer: String)
    /// 连接断开。对应 `DEVICE_DISCONNECTED`
    case disconnected(reason: String?)
    case progress(TransferProgress)
    /// 发送端：一种数据发送完成。对应 `wifi_send_done`
    case sendFinished(TransferDataKind, TransferSendSummary)
    /// 发送端：发送失败 / 中断。对应 `SEND_MSG_ERROR`
    case sendFailed(TransferDataKind, String)
    /// 接收端：收到未知 dataType（已回 RECEIVED）。对应 `wifi_server_receive_message_unknown`
    case unknownDataType(Int)
    /// 接收端：文件 MD5 校验失败，已删除。对应 `wifi_download_dir_file_failed`
    case fileChecksumFailed(gid: Int64, name: String)
    /// 接收端：下载目录未设置。对应 `wifi_download_dir_no_location`
    case downloadLocationUnavailable
    /// 接收端：一个画廊目录接收完成
    case directoryCompleted(gid: Int64, dirname: String)
    /// 接收端：目录中没有有效的 `.ehviewer`（缺失、无法解析或 gid 不符）
    case spiderInfoInvalid(gid: Int64, dirname: String)
    /// 其他非致命错误（写库失败、写文件失败等）
    case error(String)
}

/// 一次发送的统计
public struct TransferSendSummary: Sendable, Hashable {
    /// 发送的数据页 / 目录清单数
    public var pages = 0
    /// 发送的记录数（数据页中的条目）
    public var items = 0
    /// 下载目录迁移：发送的文件数与字节数
    public var files = 0
    public var bytes: Int64 = 0
    /// 下载目录迁移：对端已有而跳过的文件数
    public var skippedFiles = 0

    public init() {}
}

/// 发送失败原因
public enum TransferError: Error, Sendable, Equatable, LocalizedError {
    /// 未连接。对应 `wifi_server_connect_unable`
    case notConnected
    /// 连接断开
    case disconnected(String?)
    /// 正在发送另一种数据
    case busy
    /// 已取消（“停止迁移”）
    case cancelled
    /// 没有可迁移的下载目录。对应 `wifi_download_dir_empty`
    case downloadDirEmpty
    /// 本机下载目录未设置
    case noDownloadLocation
    case store(String)
    case invalidAddress(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected: return "连接不存在"
        case let .disconnected(r): return "连接已断开" + (r.map { "：\($0)" } ?? "")
        case .busy: return "正在迁移中"
        case .cancelled: return "已停止迁移"
        case .downloadDirEmpty: return "没有可迁移的下载目录"
        case .noDownloadLocation: return "本机未设置下载目录"
        case let .store(m): return "读取数据失败：\(m)"
        case let .invalidAddress(s): return "无效的地址：\(s)"
        }
    }
}

// MARK: - 协议引擎

/// WiFi 互传的协议状态机（与传输层无关）。合并了 Android 的
/// `WiFiServerActivity`（发送：分页、发送队列、等待应答、目录清单 / 文件块）与
/// `WiFiClientActivity`（接收：写库、目录应答、文件块落盘、MD5 校验）中的流程逻辑。
///
/// 角色按帧的 messageType 分派：收到 SEND 帧走接收逻辑，收到 RECEIVED 帧唤醒发送逻辑。
/// 因此 iOS ↔ iOS 双方都可以发送；与 Android 互通时，Android 服务端只发、Android 客户端只收。
///
/// 发送流程（每种数据一次 `send(_:)`）：
/// 1. 数据页：每页 10 条，SEND 帧（JSON），等待对端任一 RECEIVED（非 ACK）帧后发下一页
/// 2. 下载：先发一帧全部标签（DOWNLOAD_LABEL，part=1,totalSize=1），再分页发下载项
/// 3. 下载目录：逐个目录发清单（MANIFEST，part=序号,totalSize=目录数），等 ACK，
///    再把 ACK 中列出的文件按 256 KiB 分块连续发送（不等应答），然后发下一个目录
public actor TransferEngine {
    public typealias FrameSender = @Sendable (WiFiFrame) async throws -> Void
    public typealias EventHandler = @Sendable (TransferEvent) -> Void

    /// 对应 Android 每页 10 条
    public static let defaultPageSize = 10

    public let store: any TransferStore
    public let pageSize: Int
    public let chunkSize: Int

    private var frameSender: FrameSender?
    private var connectionGeneration = 0
    private var eventHandler: EventHandler?

    // 发送端状态
    private var sendingKind: TransferDataKind?
    private var sendCancelled = false
    private var replyInbox: [WiFiFrame] = []
    private var replyWaiter: CheckedContinuation<WiFiFrame, Error>?

    // 接收端状态（对应 WiFiClientActivity 字段）
    private var fileWriteState = WiFiDownloadMigration.FileWriteState()
    private var galleryDirCache: [String: URL] = [:]
    private var dirnameByGid: [Int64: String] = [:]
    private var pendingFiles: [String: Set<String>] = [:]
    private var dirFilesCompleted = 0
    private var dirFilesNeeded = 0
    private var currentDirProgress: TransferProgress?
    private var receivedBytes: Int64 = 0

    public init(store: any TransferStore, pageSize: Int = TransferEngine.defaultPageSize,
                chunkSize: Int = WiFiDownloadMigration.fileChunkSize) {
        self.store = store
        self.pageSize = max(pageSize, 1)
        self.chunkSize = max(chunkSize, 1)
    }

    /// 设置事件回调
    public func setEventHandler(_ handler: EventHandler?) {
        eventHandler = handler
    }

    /// 绑定到一条新连接，返回连接代号（断开时传回 `connectionClosed`）。
    /// 对应 Android 新连接到来时替换旧的 ConnectThread
    @discardableResult
    public func attach(sender: @escaping FrameSender) -> Int {
        connectionGeneration += 1
        frameSender = sender
        failWaiter(TransferError.disconnected("replaced by new connection"))
        replyInbox.removeAll()
        resetReceiverState()
        return connectionGeneration
    }

    /// 连接断开（只处理当前连接）
    public func connectionClosed(generation: Int, reason: String?) {
        guard generation == connectionGeneration else { return }
        frameSender = nil
        failWaiter(TransferError.disconnected(reason))
        emit(.disconnected(reason: reason))
    }

    public var isConnected: Bool { frameSender != nil }
    public var isSending: Bool { sendingKind != nil }

    /// 停止当前发送。对应“停止迁移”（`stopMigration`）
    public func cancelSending() {
        guard sendingKind != nil else { return }
        sendCancelled = true
        failWaiter(TransferError.cancelled)
    }

    // MARK: 收帧

    /// 处理一帧。传输层应按到达顺序逐帧 await 调用（文件块在此同步落盘，形成背压，
    /// 对应 Android `FileChunkReceiver` 在读线程同步写盘）
    public func handle(_ frame: WiFiFrame) async {
        switch frame.messageType {
        case WiFiDataHand.received:
            if sendingKind != nil {
                if let w = replyWaiter {
                    replyWaiter = nil
                    w.resume(returning: frame)
                } else {
                    replyInbox.append(frame)
                }
            }
        case WiFiDataHand.send:
            await receive(frame)
        default:
            break
        }
    }

    // MARK: - 发送

    /// 发送一种数据，完成后返回统计。对应选择数据类型后点“开始迁移”。
    /// 期间收到的 RECEIVED / ACK 帧驱动下一步；连接断开或 `cancelSending()` 时抛错。
    @discardableResult
    public func send(_ kind: TransferDataKind) async throws -> TransferSendSummary {
        guard frameSender != nil else { throw TransferError.notConnected }
        guard sendingKind == nil else { throw TransferError.busy }
        sendingKind = kind
        sendCancelled = false
        replyInbox.removeAll()
        defer {
            sendingKind = nil
            sendCancelled = false
            replyInbox.removeAll()
        }
        do {
            let summary = try await withTaskCancellationHandler {
                try await performSend(kind)
            } onCancel: {
                Task { await self.cancelSending() }
            }
            emit(.sendFinished(kind, summary))
            return summary
        } catch {
            emit(.sendFailed(kind, (error as? LocalizedError)?.errorDescription ?? String(describing: error)))
            throw error
        }
    }

    private func performSend(_ kind: TransferDataKind) async throws -> TransferSendSummary {
        var summary = TransferSendSummary()
        func load<T>(_ f: () throws -> T) throws -> T {
            do { return try f() } catch { throw TransferError.store(String(describing: error)) }
        }
        switch kind {
        case .quickSearch:
            let items = try load { try store.quickSearches() }.map { TransferJSON.object($0.transferJSON) }
            try await sendPages(items, kind: kind, dataType: TransferDataType.quickSearch,
                                key: TransferDataType.quickSearchKey, summary: &summary)
        case .favorite:
            let items = try load { try store.localFavorites() }.map { TransferJSON.object($0.transferJSON) }
            try await sendPages(items, kind: kind, dataType: TransferDataType.favoriteInfo,
                                key: TransferDataType.favoriteInfoKey, summary: &summary)
        case .history:
            let items = try load { try store.historyItems() }.map { TransferJSON.object($0.transferJSON) }
            try await sendPages(items, kind: kind, dataType: TransferDataType.historyInfo,
                                key: TransferDataType.historyInfoKey, summary: &summary)
        case .download:
            // createDownloadData：标签帧（pageIndex/pageSize 保持默认 1）
            let labels = try load { try store.downloadLabels() }
            var hand = WiFiDataHand(messageType: WiFiDataHand.send, dataType: TransferDataType.downloadLabel)
            hand.addData(TransferDataType.downloadLabelKey, .array(labels.map(TransferJSON.string)))
            try await sendHandAndWait(hand)
            summary.pages += 1
            summary.items += labels.count
            let items = try load { try store.downloadItems() }.map { item -> TransferJSON in
                var i = item
                i.archiveUri = nil
                return .object(i.transferJSON)
            }
            try await sendPages(items, kind: kind, dataType: TransferDataType.downloadInfo,
                                key: TransferDataType.downloadInfoKey, summary: &summary)
        case .downloadDir:
            try await sendDownloadDirs(&summary)
        }
        return summary
    }

    /// 对应 `totalPage`
    public static func pageCount(_ count: Int, pageSize: Int) -> Int {
        (count + pageSize - 1) / pageSize
    }

    private func sendPages(_ items: [TransferJSON], kind: TransferDataKind, dataType: Int, key: String,
                           summary: inout TransferSendSummary) async throws {
        let count = Self.pageCount(items.count, pageSize: pageSize)
        for i in 0..<count {
            let page = Array(items[(i * pageSize)..<min((i + 1) * pageSize, items.count)])
            var hand = WiFiDataHand(messageType: WiFiDataHand.send, dataType: dataType,
                                    pageIndex: Int64(i + 1), pageSize: Int64(count))
            hand.addData(key, .array(page))
            try await sendHandAndWait(hand)
            summary.pages += 1
            summary.items += page.count
            var p = TransferProgress(direction: .sending, kind: kind, current: i + 1, total: count)
            p.itemCount = page.count
            emit(.progress(p))
        }
    }

    private func sendHandAndWait(_ hand: WiFiDataHand) async throws {
        try await sendFrame(WiFiFrameCodec.encode(hand))
        // 等待任一非 ACK 的 RECEIVED（Android 收到 SEND_MSG_SUCCESS 即发下一页，不校验内容）
        while true {
            let reply = try await nextReply()
            if reply.dataType != TransferDataType.downloadDirAck { return }
        }
    }

    private func sendDownloadDirs(_ summary: inout TransferSendSummary) async throws {
        guard let root = store.downloadRoot else { throw TransferError.noDownloadLocation }
        let entries = WiFiDownloadMigration.scanGalleryDirs(root: root)
        if entries.isEmpty { throw TransferError.downloadDirEmpty }
        let total = entries.count
        for (i, entry) in entries.enumerated() {
            try checkCancelled()
            // Android 先扫描全部目录再发送；这里逐个目录扫描，线上内容相同
            let files = WiFiDownloadMigration.scanGalleryDir(entry.url)
            let metaMap = Dictionary(files.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
            let manifest = try WiFiFrameCodec.encodeManifest(
                gid: entry.gid, dirname: entry.dirname, files: files,
                pageIndex: Int32(clamping: i + 1), pageSize: Int32(clamping: total))
            try await sendFrame(manifest)
            summary.pages += 1
            let ack = try await waitAck(gid: entry.gid, dirname: entry.dirname)

            var progress = TransferProgress(direction: .sending, kind: .downloadDir, current: i + 1, total: total)
            progress.dirname = entry.dirname
            progress.itemCount = files.count
            let needed = ack.filesNeeded.compactMap { metaMap[$0] }
            progress.fileCount = needed.count
            progress.skippedFiles = max(files.count - needed.count, 0)
            progress.bytes = summary.bytes
            summary.skippedFiles += progress.skippedFiles
            emit(.progress(progress))

            for (fi, meta) in needed.enumerated() {
                try checkCancelled()
                progress.fileIndex = fi + 1
                progress.fileName = meta.name
                emit(.progress(progress))
                // 单个文件失败（被删除 / 读失败）时跳过，与 Android 一致
                if let sent = try await sendFileChunks(entry: entry, meta: meta) {
                    summary.files += 1
                    summary.bytes += sent
                    progress.bytes = summary.bytes
                }
            }
        }
    }

    /// 对应 `sendFileChunks`：返回发送的字节数；文件不可读返回 nil
    private func sendFileChunks(entry: WiFiDownloadMigration.GalleryDirEntry,
                                meta: WiFiDownloadMigration.FileMeta) async throws -> Int64? {
        guard let url = WiFiDownloadMigration.resolveFileInGallery(entry.url, meta.name),
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let fileLen = meta.size > 0 ? meta.size : WiFiDownloadMigration.fileSize(url, .default)
        let chunkTotal = WiFiDownloadMigration.chunkCount(fileSize: fileLen, chunkSize: chunkSize)
        var chunkIndex: Int32 = 0
        var sent: Int64 = 0
        while true {
            try checkCancelled()
            let data: Data
            do {
                guard let d = try handle.read(upToCount: chunkSize), !d.isEmpty else { break }
                data = d
            } catch {
                return chunkIndex == 0 ? nil : sent
            }
            let last = chunkIndex + 1 >= chunkTotal
            try await sendFrame(WiFiFrameCodec.encodeFileChunk(
                gid: entry.gid, name: meta.name, fileMd5: meta.md5, chunkIndex: chunkIndex,
                chunkTotal: chunkTotal, data: data, lastChunk: last))
            chunkIndex += 1
            sent += Int64(data.count)
        }
        if chunkIndex == 0 {
            try await sendFrame(WiFiFrameCodec.encodeFileChunk(
                gid: entry.gid, name: meta.name, fileMd5: meta.md5, chunkIndex: 0, chunkTotal: 1,
                data: Data(), lastChunk: true))
        }
        return sent
    }

    private func waitAck(gid: Int64, dirname: String) async throws -> WiFiDownloadMigration.DirAck {
        while true {
            let reply = try await nextReply()
            guard reply.dataType == TransferDataType.downloadDirAck,
                  let ack = WiFiFrameCodec.decodeAck(reply) else { continue }
            if ack.gid == gid, ack.dirname == dirname { return ack }
        }
    }

    private func checkCancelled() throws {
        if sendCancelled || Task.isCancelled { throw TransferError.cancelled }
        if frameSender == nil { throw TransferError.notConnected }
    }

    private func sendFrame(_ frame: WiFiFrame) async throws {
        try checkCancelled()
        guard let sender = frameSender else { throw TransferError.notConnected }
        try await sender(frame)
    }

    private func nextReply() async throws -> WiFiFrame {
        try checkCancelled()
        if !replyInbox.isEmpty { return replyInbox.removeFirst() }
        return try await withCheckedThrowingContinuation { c in
            replyWaiter = c
        }
    }

    private func failWaiter(_ error: Error) {
        if let w = replyWaiter {
            replyWaiter = nil
            w.resume(throwing: error)
        }
    }

    // MARK: - 接收

    private func resetReceiverState() {
        fileWriteState = .init()
        galleryDirCache.removeAll()
        dirnameByGid.removeAll()
        pendingFiles.removeAll()
        dirFilesCompleted = 0
        dirFilesNeeded = 0
        currentDirProgress = nil
        receivedBytes = 0
    }

    private func receive(_ frame: WiFiFrame) async {
        switch frame.dataType {
        case TransferDataType.downloadDirFile:
            if let chunk = WiFiFrameCodec.decodeFileChunk(frame) { applyFileChunk(chunk) }
        case TransferDataType.downloadDirManifest:
            if let manifest = WiFiFrameCodec.decodeManifest(frame) { await processManifest(manifest) }
        default:
            await processDataHand(WiFiFrameCodec.decodeDataHand(frame))
        }
    }

    /// 对应 `onReceiveMsg` + `dealWithXxx` + `dataProcessed`
    private func processDataHand(_ hand: WiFiDataHand) async {
        let data = hand.data ?? [:]
        func list(_ key: String) -> [[String: TransferJSON]] {
            (data[key]?.arrayValue ?? []).compactMap(\.objectValue)
        }
        var count = 0
        do {
            switch hand.dataType {
            case TransferDataType.quickSearch:
                let items = list(TransferDataType.quickSearchKey).map(TransferQuickSearch.init(transferJSON:))
                count = items.count
                try store.takeOverQuickSearches(items)
            case TransferDataType.favoriteInfo:
                let items = list(TransferDataType.favoriteInfoKey).map(GalleryInfo.init(transferJSON:))
                count = items.count
                try store.putLocalFavorites(items)
            case TransferDataType.downloadLabel:
                let labels = (data[TransferDataType.downloadLabelKey]?.arrayValue ?? []).compactMap(\.stringValue)
                count = labels.count
                try store.addDownloadLabels(labels)
            case TransferDataType.downloadInfo:
                let items = list(TransferDataType.downloadInfoKey).map(TransferDownloadItem.init(transferJSON:))
                count = items.count
                try store.addDownloadItems(items)
            case TransferDataType.historyInfo:
                let items = list(TransferDataType.historyInfoKey).map(TransferHistoryItem.init(transferJSON:))
                count = items.count
                try store.putHistoryItems(items)
            default:
                emit(.unknownDataType(hand.dataType))
            }
        } catch {
            // Android 写库异常会导致不回应答、发送端卡住；这里报告错误后照常应答
            emit(.error("写入数据失败：\(error)"))
        }
        if let kind = TransferDataKind(dataType: hand.dataType) {
            var p = TransferProgress(direction: .receiving, kind: kind, current: Int(hand.pageIndex),
                                     total: Int(hand.pageSize))
            p.itemCount = count
            emit(.progress(p))
        }
        try? await reply(WiFiFrameCodec.encode(hand.processedReply()))
    }

    private static func dirKey(_ gid: Int64, _ dirname: String) -> String { "\(gid):\(dirname)" }

    /// 对应 `processDownloadDirManifest`
    private func processManifest(_ manifest: WiFiDownloadMigration.DirManifest) async {
        let key = Self.dirKey(manifest.gid, manifest.dirname)
        guard let root = store.downloadRoot else {
            emit(.downloadLocationUnavailable)
            await sendAck(manifest, needed: [])
            return
        }
        guard let ensured = WiFiDownloadMigration.ensureGalleryDir(root: root, dirname: manifest.dirname) else {
            emit(.error("无法创建目录：\(manifest.dirname)"))
            await sendAck(manifest, needed: [])
            return
        }
        // Android 仅在新建目录时写 DownloadDirname；这里额外在库中没有该 gid 的记录时也写入
        do {
            let hasRecord = ensured.created ? false : try store.downloadDirname(gid: manifest.gid) != nil
            if !hasRecord {
                try store.putDownloadDirname(gid: manifest.gid, dirname: manifest.dirname)
            }
        } catch {
            emit(.error("写入下载目录名失败：\(error)"))
        }
        dirnameByGid[manifest.gid] = manifest.dirname
        galleryDirCache[key] = ensured.url
        if manifest.pageIndex == 1 {
            dirFilesCompleted = 0
            receivedBytes = 0
        }
        let needed = WiFiDownloadMigration.filterFilesNeeded(ensured.url, remoteFiles: manifest.files)
        pendingFiles[key] = Set(needed)
        dirFilesNeeded = needed.count

        var p = TransferProgress(direction: .receiving, kind: .downloadDir, current: Int(manifest.pageIndex),
                                 total: Int(manifest.pageSize))
        p.dirname = manifest.dirname
        p.itemCount = manifest.files.count
        p.fileCount = needed.count
        p.skippedFiles = manifest.files.count - needed.count
        p.bytes = receivedBytes
        currentDirProgress = p
        emit(.progress(p))

        await sendAck(manifest, needed: needed)
        if needed.isEmpty { finishDirectory(gid: manifest.gid, dirname: manifest.dirname, dir: ensured.url) }
    }

    private func sendAck(_ manifest: WiFiDownloadMigration.DirManifest, needed: [String]) async {
        guard let frame = try? WiFiFrameCodec.encodeAck(gid: manifest.gid, dirname: manifest.dirname,
                                                        filesNeeded: needed) else { return }
        try? await reply(frame)
    }

    /// 对应 `applyFileChunk`
    private func applyFileChunk(_ chunk: WiFiDownloadMigration.FileChunk) {
        guard let dirname = dirnameByGid[chunk.gid] else { return }
        let key = Self.dirKey(chunk.gid, dirname)
        var galleryDir = galleryDirCache[key]
        if galleryDir == nil {
            guard let root = store.downloadRoot,
                  let ensured = WiFiDownloadMigration.ensureGalleryDir(root: root, dirname: dirname) else { return }
            galleryDir = ensured.url
            galleryDirCache[key] = ensured.url
        }
        guard let dir = galleryDir, let target = WiFiDownloadMigration.resolveFileInGallery(dir, chunk.name)
        else { return }
        let fileKey = key + "/" + chunk.name
        do {
            var offset = fileWriteState.offset(fileKey)
            if chunk.chunkIndex == 0 {
                offset = 0
                fileWriteState.clear(fileKey)
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir), !isDir.boolValue {
                    try? FileManager.default.removeItem(at: target)
                }
            }
            if !chunk.data.isEmpty || chunk.chunkIndex == 0 {
                // 空文件也要创建（Android 空数据不写，文件不存在会导致 MD5 校验失败）
                try WiFiDownloadMigration.writeChunk(dir, relPath: chunk.name, data: chunk.data, offset: offset)
                fileWriteState.addWritten(fileKey, chunk.data.count)
                receivedBytes += Int64(chunk.data.count)
            }
            if chunk.lastChunk {
                if !WiFiDownloadMigration.verifyFileMd5(target, expected: chunk.fileMd5) {
                    try? FileManager.default.removeItem(at: target)
                    emit(.fileChecksumFailed(gid: chunk.gid, name: chunk.name))
                }
                fileWriteState.clear(fileKey)
                dirFilesCompleted += 1
                if var p = currentDirProgress, p.dirname == dirname {
                    p.fileIndex += 1
                    p.fileName = chunk.name
                    p.bytes = receivedBytes
                    currentDirProgress = p
                    emit(.progress(p))
                }
                if var pending = pendingFiles[key] {
                    pending.remove(chunk.name)
                    pendingFiles[key] = pending
                    if pending.isEmpty { finishDirectory(gid: chunk.gid, dirname: dirname, dir: dir) }
                }
            }
        } catch {
            emit(.error("写入文件失败：\(chunk.name)：\(error)"))
        }
    }

    /// 目录接收完成：用 `SpiderInfo` 校验随目录传来的 `.ehviewer`（Android 把它当普通文件传输）。
    /// 缺失 / 无法解析 / gid 不符时报告 `.spiderInfoInvalid`，不伪造（页数未知，写出的文件无效；
    /// 阅读 / 继续下载时 Spider 会按下载项的 token 重新获取并写入）
    private func finishDirectory(gid: Int64, dirname: String, dir: URL) {
        pendingFiles[Self.dirKey(gid, dirname)] = nil
        let infoURL = dir.appendingPathComponent(SpiderNaming.spiderInfoFilename)
        if let info = SpiderInfo.read(contentsOf: infoURL, includePTokens: false), info.gid == gid {
            // 有效
        } else {
            emit(.spiderInfoInvalid(gid: gid, dirname: dirname))
        }
        emit(.directoryCompleted(gid: gid, dirname: dirname))
    }

    private func reply(_ frame: WiFiFrame) async throws {
        guard let sender = frameSender else { throw TransferError.notConnected }
        try await sender(frame)
    }

    private func emit(_ event: TransferEvent) {
        eventHandler?(event)
    }
}
