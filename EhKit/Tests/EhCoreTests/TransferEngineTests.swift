import Foundation
import Testing
@testable import EhCore

/// 内存版 TransferStore（合并规则简化为 Android 语义）
final class MemoryTransferStore: TransferStore, @unchecked Sendable {
    private let lock = NSLock()
    var quick: [TransferQuickSearch] = []
    var favorites: [GalleryInfo] = []
    var labels: [String] = []
    var downloads: [TransferDownloadItem] = []
    var history: [TransferHistoryItem] = []
    var dirnames: [Int64: String] = [:]
    let downloadRoot: URL?

    init(root: URL?) { downloadRoot = root }

    func sync<T>(_ f: () -> T) -> T { lock.withLock(f) }

    func quickSearches() throws -> [TransferQuickSearch] { sync { quick } }
    func localFavorites() throws -> [GalleryInfo] { sync { favorites } }
    func downloadLabels() throws -> [String] { sync { labels } }
    func downloadItems() throws -> [TransferDownloadItem] { sync { downloads } }
    func historyItems() throws -> [TransferHistoryItem] { sync { history } }

    func takeOverQuickSearches(_ list: [TransferQuickSearch]) throws {
        sync {
            let existing = quick
            for q in list where !existing.contains(where: { $0.keyword == q.keyword }) { quick.append(q) }
        }
    }

    func putLocalFavorites(_ list: [GalleryInfo]) throws {
        sync { for f in list where !favorites.contains(where: { $0.gid == f.gid }) { favorites.append(f) } }
    }

    func addDownloadLabels(_ list: [String]) throws {
        sync { for l in list where !labels.contains(l) { labels.append(l) } }
    }

    func addDownloadItems(_ items: [TransferDownloadItem]) throws {
        sync {
            for i in items where !downloads.contains(where: { $0.info.gid == i.info.gid }) {
                downloads.append(TransferDownloadItem(info: i.info, label: i.label, state: 0))
            }
        }
    }

    func putHistoryItems(_ items: [TransferHistoryItem]) throws {
        sync { for h in items where !history.contains(where: { $0.info.gid == h.info.gid }) { history.append(h) } }
    }

    func putDownloadDirname(gid: Int64, dirname: String) throws { sync { dirnames[gid] = dirname } }
    func downloadDirname(gid: Int64) throws -> String? { sync { dirnames[gid] } }
}

/// 事件收集
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [TransferEvent] = []
    func append(_ e: TransferEvent) { lock.withLock { list.append(e) } }
    var events: [TransferEvent] { lock.withLock { list } }
}

/// 单向字节管道：编码 → 不规则切分 → 增量解析 → 对端按序 handle
final class FramePipe: @unchecked Sendable {
    private let continuation: AsyncStream<Data>.Continuation
    private let task: Task<Void, Never>
    private let lock = NSLock()
    private var _bytes = 0
    var bytes: Int { lock.withLock { _bytes } }

    init(to engine: TransferEngine) {
        let (stream, cont) = AsyncStream.makeStream(of: Data.self)
        continuation = cont
        task = Task {
            var parser = WiFiFrameParser()
            for await data in stream {
                guard let frames = try? parser.append(data) else { return }
                for f in frames { await engine.handle(f) }
            }
        }
    }

    func send(_ frame: WiFiFrame) {
        let data = WiFiFrameCodec.encode(frame)
        lock.withLock { _bytes += data.count }
        // 切成 3 段模拟分包
        let a = data.count / 3, b = data.count * 2 / 3
        continuation.yield(data.subdata(in: 0..<a))
        continuation.yield(data.subdata(in: a..<b))
        continuation.yield(data.subdata(in: b..<data.count))
    }

    func close() {
        continuation.finish()
        task.cancel()
    }
}

/// 两个引擎互连
struct Loopback {
    let sender: TransferEngine
    let receiver: TransferEngine
    let toReceiver: FramePipe
    let toSender: FramePipe
    let senderEvents = EventLog()
    let receiverEvents = EventLog()

    init(senderStore: TransferStore, receiverStore: TransferStore, chunkSize: Int = 7) async {
        sender = TransferEngine(store: senderStore, pageSize: 3, chunkSize: chunkSize)
        receiver = TransferEngine(store: receiverStore, pageSize: 3, chunkSize: chunkSize)
        toReceiver = FramePipe(to: receiver)
        toSender = FramePipe(to: sender)
        let tr = toReceiver, ts = toSender
        await sender.attach(sender: { tr.send($0) })
        await receiver.attach(sender: { ts.send($0) })
        let se = senderEvents, re = receiverEvents
        await sender.setEventHandler { se.append($0) }
        await receiver.setEventHandler { re.append($0) }
    }

    func close() {
        toReceiver.close()
        toSender.close()
    }
}

@Suite struct TransferEngineTests {
    @Test func quickSearchFavoriteHistoryPaging() async throws {
        let a = MemoryTransferStore(root: nil)
        let b = MemoryTransferStore(root: nil)
        a.quick = (1...7).map { TransferQuickSearch(name: "q\($0)", keyword: "k\($0)", time: Int64($0)) }
        b.quick = [TransferQuickSearch(name: "exists", keyword: "k2")]
        a.favorites = (1...4).map { GalleryInfo(gid: Int64($0), token: "t\($0)", title: "F\($0)", rating: 3.5) }
        b.favorites = [GalleryInfo(gid: 1, token: "old")]
        a.history = [TransferHistoryItem(info: GalleryInfo(gid: 77, token: "h"), mode: 1, time: 5)]
        let lb = await Loopback(senderStore: a, receiverStore: b)
        defer { lb.close() }

        let s1 = try await lb.sender.send(.quickSearch)
        #expect(s1.pages == 3)  // 7 条 / 每页 3
        #expect(s1.items == 7)
        #expect(b.quick.map(\.keyword) == ["k2", "k1", "k3", "k4", "k5", "k6", "k7"])

        let s2 = try await lb.sender.send(.favorite)
        #expect(s2.pages == 2)
        #expect(b.favorites.map(\.gid) == [1, 2, 3, 4])
        #expect(b.favorites[0].token == "old")
        #expect(b.favorites[1].rating == 3.5)

        try await lb.sender.send(.history)
        #expect(b.history == a.history)

        // 空列表：不发帧，直接完成
        a.quick = []
        let empty = try await lb.sender.send(.quickSearch)
        #expect(empty.pages == 0)

        let sentProgress = lb.senderEvents.events.compactMap { e -> TransferProgress? in
            if case let .progress(p) = e, p.kind == .quickSearch { return p }
            return nil
        }
        #expect(sentProgress.map(\.current) == [1, 2, 3])
        #expect(sentProgress.allSatisfy { $0.total == 3 && $0.direction == .sending })
        let recvProgress = lb.receiverEvents.events.compactMap { e -> TransferProgress? in
            if case let .progress(p) = e, p.kind == .quickSearch { return p }
            return nil
        }
        #expect(recvProgress.map(\.itemCount) == [3, 3, 1])
        #expect(lb.senderEvents.events.contains { if case .sendFinished(.favorite, _) = $0 { return true }; return false })
    }

    @Test func downloadSendsLabelsThenItems() async throws {
        let a = MemoryTransferStore(root: nil)
        let b = MemoryTransferStore(root: nil)
        a.labels = ["L1", "L2"]
        b.labels = ["L2"]
        a.downloads = (1...4).map {
            TransferDownloadItem(info: GalleryInfo(gid: Int64($0), token: "t"), label: $0 == 1 ? "L1" : nil,
                                 state: 3, time: Int64($0), archiveUri: "content://x")
        }
        let lb = await Loopback(senderStore: a, receiverStore: b)
        defer { lb.close() }
        let s = try await lb.sender.send(.download)
        #expect(s.pages == 1 + 2)
        #expect(s.items == 2 + 4)
        #expect(b.labels == ["L2", "L1"])
        #expect(b.downloads.map(\.info.gid) == [1, 2, 3, 4])
        #expect(b.downloads[0].label == "L1")
        #expect(b.downloads.allSatisfy { $0.archiveUri == nil })
    }

    @Test func downloadDirMigration() async throws {
        let rootA = try makeTransferTempDir()
        let rootB = try makeTransferTempDir()
        defer {
            try? FileManager.default.removeItem(at: rootA)
            try? FileManager.default.removeItem(at: rootB)
        }
        let fm = FileManager.default
        let g1 = rootA.appendingPathComponent("11-One")
        let g2 = rootA.appendingPathComponent("22-Two")
        try fm.createDirectory(at: g1.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try fm.createDirectory(at: g2, withIntermediateDirectories: true)
        let big = Data((0..<100).map { UInt8($0) })  // chunkSize 7 → 15 块
        try big.write(to: g1.appendingPathComponent("00000001.jpg"))
        try Data("same".utf8).write(to: g1.appendingPathComponent("00000002.jpg"))
        try Data().write(to: g1.appendingPathComponent("sub/empty.txt"))
        try SpiderInfo(gid: 11, token: "tok11", pages: 2).write(to: g1.appendingPathComponent(".ehviewer"))
        try Data("x".utf8).write(to: g2.appendingPathComponent("00000001.png"))

        // 接收端已有 11-One/00000002.jpg（相同）与 22-Two 目录
        let d1 = rootB.appendingPathComponent("11-One")
        try fm.createDirectory(at: d1, withIntermediateDirectories: true)
        try Data("same".utf8).write(to: d1.appendingPathComponent("00000002.jpg"))
        try fm.createDirectory(at: rootB.appendingPathComponent("22-Two"), withIntermediateDirectories: true)

        let a = MemoryTransferStore(root: rootA)
        let b = MemoryTransferStore(root: rootB)
        let lb = await Loopback(senderStore: a, receiverStore: b)
        defer { lb.close() }

        let s = try await lb.sender.send(.downloadDir)
        #expect(s.pages == 2)
        #expect(s.files == 4)  // .ehviewer、00000001.jpg、sub/empty.txt、22 的 00000001.png
        #expect(s.skippedFiles == 1)
        #expect(s.bytes == Int64(100 + 1) + Int64(try Data(contentsOf: g1.appendingPathComponent(".ehviewer")).count))

        // 文件块在 ACK 后连续发送，不等应答；等待接收端处理完
        try await waitUntil { lb.receiverEvents.events.filter { if case .directoryCompleted = $0 { return true }; return false }.count == 2 }

        #expect(try Data(contentsOf: d1.appendingPathComponent("00000001.jpg")) == big)
        #expect(try Data(contentsOf: d1.appendingPathComponent("sub/empty.txt")).isEmpty)
        #expect(SpiderInfo.read(contentsOf: d1.appendingPathComponent(".ehviewer"))?.token == "tok11")
        // 11 的 .ehviewer 有效；22 没有 .ehviewer → 报告，不伪造
        #expect(lb.receiverEvents.events.contains(.spiderInfoInvalid(gid: 22, dirname: "22-Two")))
        #expect(!lb.receiverEvents.events.contains(.spiderInfoInvalid(gid: 11, dirname: "11-One")))
        #expect(!FileManager.default.fileExists(atPath: rootB.appendingPathComponent("22-Two/.ehviewer").path))
        #expect(try Data(contentsOf: rootB.appendingPathComponent("22-Two/00000001.png")) == Data("x".utf8))
        // 目录已存在、库中无记录时也写入 DownloadDirname
        #expect(b.dirnames == [11: "11-One", 22: "22-Two"])

        let manifestProgress = lb.receiverEvents.events.compactMap { e -> TransferProgress? in
            if case let .progress(p) = e, p.kind == .downloadDir, p.fileIndex == 0 { return p }
            return nil
        }
        #expect(manifestProgress.map(\.dirname) == ["11-One", "22-Two"])
        #expect(manifestProgress.first?.skippedFiles == 1)
        #expect(manifestProgress.first?.fileCount == 3)

        // 再发一次：全部跳过
        let again = try await lb.sender.send(.downloadDir)
        #expect(again.files == 0)
        #expect(again.skippedFiles == 5)
    }

    @Test func checksumMismatchDeletesFile() async throws {
        let rootB = try makeTransferTempDir()
        defer { try? FileManager.default.removeItem(at: rootB) }
        let b = MemoryTransferStore(root: rootB)
        let receiver = TransferEngine(store: b)
        let log = EventLog()
        await receiver.setEventHandler { log.append($0) }
        let replies = EventLog()
        await receiver.attach(sender: { f in
            if f.dataType == TransferDataType.downloadDirAck { replies.append(.unknownDataType(f.dataType)) }
        })
        let manifest = try WiFiFrameCodec.encodeManifest(
            gid: 3, dirname: "3-x", files: [.init(name: "a.jpg", md5: MD5.hexString(Data("good".utf8)), size: 4)],
            pageIndex: 1, pageSize: 1)
        await receiver.handle(manifest)
        #expect(replies.events.count == 1)
        let chunk = try WiFiFrameCodec.encodeFileChunk(gid: 3, name: "a.jpg", fileMd5: MD5.hexString(Data("good".utf8)),
                                                       chunkIndex: 0, chunkTotal: 1, data: Data("bad!".utf8),
                                                       lastChunk: true)
        await receiver.handle(chunk)
        #expect(!FileManager.default.fileExists(atPath: rootB.appendingPathComponent("3-x/a.jpg").path))
        #expect(log.events.contains(.fileChecksumFailed(gid: 3, name: "a.jpg")))

        // 路径穿越被忽略
        let evil = try WiFiFrameCodec.encodeFileChunk(gid: 3, name: "../evil", fileMd5: "", chunkIndex: 0,
                                                      chunkTotal: 1, data: Data("x".utf8), lastChunk: true)
        await receiver.handle(evil)
        #expect(!FileManager.default.fileExists(atPath: rootB.appendingPathComponent("evil").path))
    }

    @Test func noDownloadLocationAcksEmpty() async throws {
        let receiver = TransferEngine(store: MemoryTransferStore(root: nil))
        let log = EventLog()
        await receiver.setEventHandler { log.append($0) }
        let acks = AckBox()
        await receiver.attach(sender: { f in acks.set(WiFiFrameCodec.decodeAck(f)) })
        await receiver.handle(try WiFiFrameCodec.encodeManifest(
            gid: 1, dirname: "1-a", files: [.init(name: "x", md5: "y", size: 1)], pageIndex: 1, pageSize: 1))
        #expect(acks.value == .init(gid: 1, dirname: "1-a", filesNeeded: []))
        #expect(log.events.contains(.downloadLocationUnavailable))
    }

    @Test func unknownDataTypeStillReplies() async throws {
        let receiver = TransferEngine(store: MemoryTransferStore(root: nil))
        let box = FrameBox()
        await receiver.attach(sender: { box.set($0) })
        var hand = WiFiDataHand(messageType: WiFiDataHand.send, dataType: 4242)
        hand.addData("x", .int(1))
        await receiver.handle(WiFiFrameCodec.encode(hand))
        let reply = try #require(box.value)
        #expect(reply.messageType == WiFiDataHand.received)
        #expect(reply.dataType == 4242)
        #expect(WiFiFrameCodec.decodeDataHand(reply).data == ["x": .int(1)])
    }

    @Test func senderErrorsAndCancellation() async throws {
        let a = MemoryTransferStore(root: nil)
        a.quick = [TransferQuickSearch(keyword: "k")]
        let engine = TransferEngine(store: a)
        await #expect(throws: TransferError.notConnected) { try await engine.send(.quickSearch) }

        // 对端不应答 → 取消
        let gen = await engine.attach(sender: { _ in })
        let task = Task { try await engine.send(.quickSearch) }
        try await waitUntil { await engine.isSending }
        await #expect(throws: TransferError.busy) { try await engine.send(.favorite) }
        await engine.cancelSending()
        await #expect(throws: TransferError.cancelled) { try await task.value }

        // 发送中断开
        let task2 = Task { try await engine.send(.quickSearch) }
        try await waitUntil { await engine.isSending }
        await engine.connectionClosed(generation: gen, reason: "bye")
        await #expect(throws: TransferError.disconnected("bye")) { try await task2.value }

        // 没有下载目录
        _ = await engine.attach(sender: { _ in })
        await #expect(throws: TransferError.noDownloadLocation) { try await engine.send(.downloadDir) }
        let empty = try makeTransferTempDir()
        defer { try? FileManager.default.removeItem(at: empty) }
        let e2 = TransferEngine(store: MemoryTransferStore(root: empty))
        _ = await e2.attach(sender: { _ in })
        await #expect(throws: TransferError.downloadDirEmpty) { try await e2.send(.downloadDir) }
    }

    @Test func taskCancellationStopsSending() async throws {
        let a = MemoryTransferStore(root: nil)
        a.quick = [TransferQuickSearch(keyword: "k")]
        let engine = TransferEngine(store: a)
        _ = await engine.attach(sender: { _ in })
        let task = Task { try await engine.send(.quickSearch) }
        try await waitUntil { await engine.isSending }
        task.cancel()
        await #expect(throws: TransferError.cancelled) { try await task.value }
        #expect(await engine.isSending == false)
    }
}

final class AckBox: @unchecked Sendable {
    private let lock = NSLock()
    private var v: WiFiDownloadMigration.DirAck?
    func set(_ a: WiFiDownloadMigration.DirAck?) { lock.withLock { v = a } }
    var value: WiFiDownloadMigration.DirAck? { lock.withLock { v } }
}

final class FrameBox: @unchecked Sendable {
    private let lock = NSLock()
    private var v: WiFiFrame?
    func set(_ f: WiFiFrame) { lock.withLock { v = f } }
    var value: WiFiFrame? { lock.withLock { v } }
}

struct WaitTimeout: Error {}

func waitUntil(timeout: Double = 10, _ condition: @Sendable () async -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !(await condition()) {
        if Date() > deadline { throw WaitTimeout() }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
}
