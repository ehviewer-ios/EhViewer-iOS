import Foundation

/// 单页状态。对应 Android `SpiderQueen.STATE_*` + `request()` 返回值（null / Float / String）
public enum PageState: Sendable, Hashable {
    /// 未加载（含排队中）
    case none
    /// 加载中；progress 为 0...1，未知总大小时为 nil
    case loading(progress: Float?)
    /// 已完成，图片文件位置（读取优先下载目录）
    case loaded(URL)
    /// 失败（可读错误信息）
    case failed(String)

    public var fileURL: URL? {
        if case let .loaded(url) = self { return url }
        return nil
    }

    public var isLoaded: Bool { fileURL != nil }
}

/// 加载进度统计。对应 `OnSpiderListener` 回调里的 finished / downloaded / total
public struct LoaderProgress: Sendable, Hashable {
    /// 成功页数
    public var finished: Int
    /// 已结束页数（成功 + 失败）
    public var downloaded: Int
    /// 总页数；未知时为 -1
    public var total: Int

    public init(finished: Int = 0, downloaded: Int = 0, total: Int = -1) {
        self.finished = finished
        self.downloaded = downloaded
        self.total = total
    }
}

/// 阅读源事件。对应 Android `SpiderQueen.OnSpiderListener` / `GalleryProvider` 的通知
public enum LoaderEvent: Sendable, Hashable {
    /// 获知总页数（`onGetPages`）
    case pageCount(Int)
    /// 页下载进度（`onPageDownload`）；received 为累计字节
    case pageProgress(index: Int, received: Int64, total: Int64?)
    /// 页完成（`onPageSuccess`）
    case pageLoaded(index: Int, url: URL, progress: LoaderProgress)
    /// 页失败（`onPageFailure`）
    case pageFailed(index: Int, error: String, progress: LoaderProgress)
    /// 遇到 509 配额（`onGet509`）
    case got509(index: Int)
    /// 全部 worker 结束（`onFinish`）。downloadMode 表示结束时是否处于下载模式
    case finished(progress: LoaderProgress, downloadMode: Bool)
    /// 加载源整体失败（无法获取页数 / 不是目录 / 压缩包损坏等）
    case error(String)
}

/// 阅读器 UI 唯一依赖的阅读源抽象。实现：`GalleryLoader`（在线 / 已下载）、`LocalDirectorySource`、`ArchiveSource`。
/// 对应 Android `GalleryProvider2`。
public protocol ReaderPageSource: AnyObject, Sendable {
    /// 订阅事件。每次访问返回一个新的独立订阅（广播），订阅方结束迭代或源关闭后自动释放
    var events: AsyncStream<LoaderEvent> { get }

    /// 开始加载（幂等）
    func start() async
    /// 阅读器关闭时调用（`GalleryLoader` 释放读引用，本地源释放资源）
    func close() async

    /// 总页数；尚未获知时为 nil
    var pageCount: Int? { get async }
    /// 整体错误（对应 `getError()`）；正常时为 nil
    var loadError: String? { get async }

    func state(of index: Int) async -> PageState
    /// 请求某页。force 为 true 时强制重新下载（对应 `forceRequest`）。返回请求时的状态
    @discardableResult
    func request(_ index: Int, force: Bool) async -> PageState
    func cancel(_ index: Int) async
    /// 预加载窗口（请求某页时顺带请求其后 count 页）
    func setPreloadCount(_ count: Int) async

    /// 上次阅读位置（对应 `getStartPage`）
    func startPage() async -> Int
    /// 保存阅读位置（对应 `putStartPage`）
    func putStartPage(_ page: Int) async
    /// 保存图片时使用的文件名（不含扩展名）。对应 `getImageFilename`
    func imageFilename(at index: Int) async -> String
}

public extension ReaderPageSource {
    @discardableResult
    func request(_ index: Int) async -> PageState { await request(index, force: false) }
}

/// 线程安全的事件广播器：每个订阅者一个 AsyncStream（无界缓冲）
final class EventBroadcaster<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]
    private var finished = false

    func subscribe() -> AsyncStream<Element> {
        let (stream, continuation) = AsyncStream<Element>.makeStream()
        let id = UUID()
        let alreadyFinished: Bool = lock.withLock {
            if finished { return true }
            continuations[id] = continuation
            return false
        }
        if alreadyFinished {
            continuation.finish()
        } else {
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                _ = self.lock.withLock { self.continuations.removeValue(forKey: id) }
            }
        }
        return stream
    }

    func yield(_ element: Element) {
        let targets = lock.withLock { Array(continuations.values) }
        for c in targets { c.yield(element) }
    }

    var subscriberCount: Int { lock.withLock { continuations.count } }

    /// 结束所有订阅；之后的订阅立即结束
    func finish() {
        let targets: [AsyncStream<Element>.Continuation] = lock.withLock {
            finished = true
            defer { continuations.removeAll() }
            return Array(continuations.values)
        }
        for c in targets { c.finish() }
    }
}

/// 简单的异步互斥锁（FIFO），用于串行化 pToken 获取与 showKey 获取（对应 Android `mQueenLock` / `showKeyLock`）
final class AsyncMutex: @unchecked Sendable {
    private let lock = NSLock()
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        let acquired: Bool = lock.withLock {
            if !locked {
                locked = true
                return true
            }
            return false
        }
        if acquired { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let immediate: Bool = lock.withLock {
                if !locked {
                    locked = true
                    return true
                }
                waiters.append(c)
                return false
            }
            if immediate { c.resume() }
        }
    }

    func release() {
        let next: CheckedContinuation<Void, Never>? = lock.withLock {
            if waiters.isEmpty {
                locked = false
                return nil
            }
            return waiters.removeFirst()
        }
        next?.resume()
    }
}

/// 线程安全的小容器
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
    var get: Value { withLock { $0 } }
}
