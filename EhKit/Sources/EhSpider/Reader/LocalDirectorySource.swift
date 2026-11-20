import Foundation

/// 本地图片文件夹阅读源。对应 Android `gallery/DirGalleryProvider.java`。
///
/// 列出目录中的图片（支持的扩展名，不递归），按自然排序。所有页立即可用（`.loaded(fileURL)`）。
/// 目录中若有有效 `.ehviewer`，阅读位置读写其 startPage（Android 拷贝来的下载目录 / 导入相册）。
public actor LocalDirectorySource: ReaderPageSource {
    public nonisolated let directory: URL
    private let broadcaster = EventBroadcaster<LoaderEvent>()
    private var files: [URL]?
    private var _loadError: String?
    private var started = false
    private var closed = false

    public init(directory: URL) {
        self.directory = directory
    }

    public nonisolated var events: AsyncStream<LoaderEvent> { broadcaster.subscribe() }

    public func start() {
        guard !started, !closed else { return }
        started = true
        guard let list = ImageFiles.listImages(in: directory) else {
            _loadError = SpiderMessages.notFolder
            broadcaster.yield(.error(SpiderMessages.notFolder))
            return
        }
        files = list
        broadcaster.yield(.pageCount(list.count))
    }

    public func close() {
        closed = true
        files = nil
        broadcaster.finish()
    }

    public var pageCount: Int? { files?.count }
    public var loadError: String? { _loadError }

    /// 排序后的文件列表
    public var fileURLs: [URL] { files ?? [] }

    public func state(of index: Int) -> PageState {
        guard let files else { return .none }
        guard index >= 0, index < files.count else { return .failed(SpiderMessages.outOfRange) }
        return FileManager.default.fileExists(atPath: files[index].path)
            ? .loaded(files[index]) : .failed(SpiderMessages.readingFailed)
    }

    @discardableResult
    public func request(_ index: Int, force: Bool) -> PageState {
        if !started { start() }
        let s = state(of: index)
        switch s {
        case let .loaded(url):
            broadcaster.yield(.pageLoaded(index: index, url: url, progress: progress))
        case let .failed(msg):
            broadcaster.yield(.pageFailed(index: index, error: msg, progress: progress))
        default:
            break
        }
        return s
    }

    private var progress: LoaderProgress {
        let n = files?.count ?? -1
        return LoaderProgress(finished: max(n, 0), downloaded: max(n, 0), total: n)
    }

    public func cancel(_ index: Int) {}
    public func setPreloadCount(_ count: Int) {}

    private var spiderInfoURL: URL { directory.appendingPathComponent(SpiderNaming.spiderInfoFilename) }

    public func startPage() -> Int {
        SpiderInfo.read(contentsOf: spiderInfoURL)?.startPage ?? 0
    }

    public func putStartPage(_ page: Int) {
        guard var info = SpiderInfo.read(contentsOf: spiderInfoURL) else { return }
        info.startPage = page
        try? info.write(to: spiderInfoURL)
    }

    /// 对应 `DirGalleryProvider.getImageFilename`（Android 为 index 字符串）
    public nonisolated func imageFilename(at index: Int) -> String {
        "\(directory.lastPathComponent)-\(String(format: "%08d", index + 1))"
    }
}
