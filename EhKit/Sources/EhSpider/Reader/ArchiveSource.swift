import Foundation
import ZIPFoundation

/// 本地导入 / 归档相关错误
public enum SpiderImportError: Error, Sendable, Equatable, LocalizedError {
    /// 不支持的压缩格式（rar / cbr / 7z 等）
    case unsupportedFormat(String)
    /// 压缩包无法打开或已损坏
    case invalidArchive(String)
    case notADirectory
    case noImages
    case alreadyImported
    /// 下载目录不可用（对应 settings_download_invalid_download_location）
    case downloadLocationUnavailable
    case copyFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedFormat(ext): return "暂不支持该压缩格式：\(ext)（仅支持 zip / cbz）"
        case let .invalidArchive(msg): return "压缩包无法读取：\(msg)"
        case .notADirectory: return SpiderMessages.notFolder
        case .noImages: return "没有找到图片"
        case .alreadyImported: return "已经导入过"
        case .downloadLocationUnavailable: return "下载目录不可用"
        case let .copyFailed(msg): return "复制失败：\(msg)"
        }
    }

    /// 支持读取的压缩包扩展名
    public static let supportedArchiveExtensions = ["zip", "cbz"]
    /// 识别但不支持的扩展名
    public static let unsupportedArchiveExtensions = ["rar", "cbr", "7z", "cb7", "tar", "cbt"]

    /// 检查文件扩展名，rar/7z 抛 `unsupportedFormat`
    public static func checkArchiveFormat(_ url: URL) throws {
        let ext = url.pathExtension.lowercased()
        if supportedArchiveExtensions.contains(ext) { return }
        throw unsupportedFormat(ext.isEmpty ? url.lastPathComponent : ext)
    }
}

/// zip / cbz 压缩包阅读源。对应 Android `gallery/ArchiveGalleryProvider.java`（+ `A7ZipArchive`）。
///
/// 图片条目（按路径小写后缀判断）按路径自然排序；请求时把条目解压到临时目录后返回文件 URL。
/// 与 Android 的差异：跳过 `__MACOSX/` 与 `._` 开头的资源分叉条目；不支持加密 zip；rar/7z 抛 `unsupportedFormat`。
public actor ArchiveSource: ReaderPageSource {
    public nonisolated let archiveURL: URL
    private let extractDirectory: URL
    private let broadcaster = EventBroadcaster<LoaderEvent>()
    private var archive: Archive?
    private var entries: [Entry]?
    private var extracted: [Int: URL] = [:]
    private var _loadError: String?
    private var started = false
    private var closed = false
    private var memoryStartPage = 0
    private let startPageStore: SpiderInfoCache?
    private let startPageKey: Int64?

    /// - Parameters:
    ///   - extractDirectory: 解压临时目录（关闭时删除）；nil 时用系统临时目录
    ///   - startPageStore / gid: 提供时阅读位置持久化到 spider_info 缓存（导入的压缩包对应的下载项 gid）
    public init(archiveURL: URL, extractDirectory: URL? = nil, startPageStore: SpiderInfoCache? = nil, gid: Int64? = nil) {
        self.archiveURL = archiveURL
        self.extractDirectory = extractDirectory
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("eharchive-\(UUID().uuidString)", isDirectory: true)
        self.startPageStore = startPageStore
        startPageKey = gid
    }

    public nonisolated var events: AsyncStream<LoaderEvent> { broadcaster.subscribe() }

    /// 压缩包中的图片条目路径（排序后）。供导入使用
    public static func imageEntryPaths(of archive: Archive) -> [Entry] {
        archive.filter { entry in
            guard entry.type == .file else { return false }
            let path = entry.path
            if path.hasPrefix("__MACOSX/") { return false }
            let base = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? path
            if base.hasPrefix("._") { return false }
            return ImageFiles.isSupportedImageName(path)
        }.sorted { NaturalComparator.compare($0.path, $1.path) < 0 }
    }

    static func openArchive(_ url: URL) throws -> Archive {
        try SpiderImportError.checkArchiveFormat(url)
        do {
            return try Archive(url: url, accessMode: .read)
        } catch {
            throw SpiderImportError.invalidArchive(SpiderMessages.readable(error))
        }
    }

    public func start() {
        guard !started, !closed else { return }
        started = true
        do {
            let a = try Self.openArchive(archiveURL)
            archive = a
            let list = Self.imageEntryPaths(of: a)
            entries = list
            broadcaster.yield(.pageCount(list.count))
        } catch {
            let msg = SpiderMessages.readable(error)
            _loadError = msg
            broadcaster.yield(.error(msg))
        }
    }

    public func close() {
        closed = true
        archive = nil
        entries = nil
        extracted.removeAll()
        try? FileManager.default.removeItem(at: extractDirectory)
        broadcaster.finish()
    }

    public var pageCount: Int? { entries?.count }
    public var loadError: String? { _loadError }

    private var progress: LoaderProgress {
        LoaderProgress(finished: extracted.count, downloaded: extracted.count, total: entries?.count ?? -1)
    }

    public func state(of index: Int) -> PageState {
        guard let entries else { return .none }
        guard index >= 0, index < entries.count else { return .failed(SpiderMessages.outOfRange) }
        if let url = extracted[index], FileManager.default.fileExists(atPath: url.path) { return .loaded(url) }
        return .none
    }

    @discardableResult
    public func request(_ index: Int, force: Bool) -> PageState {
        if !started { start() }
        guard let entries, let archive else { return .none }
        guard index >= 0, index < entries.count else {
            broadcaster.yield(.pageFailed(index: index, error: SpiderMessages.outOfRange, progress: progress))
            return .failed(SpiderMessages.outOfRange)
        }
        if !force, let url = extracted[index], FileManager.default.fileExists(atPath: url.path) {
            broadcaster.yield(.pageLoaded(index: index, url: url, progress: progress))
            return .loaded(url)
        }
        let entry = entries[index]
        let dst = extractDirectory.appendingPathComponent(
            SpiderNaming.imageFilename(index: index, extension: ImageFiles.imageExtension(ofFilename: entry.path)))
        do {
            try FileManager.default.createDirectory(at: extractDirectory, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: dst)
            _ = try archive.extract(entry, to: dst, skipCRC32: true)
            extracted[index] = dst
            broadcaster.yield(.pageLoaded(index: index, url: dst, progress: progress))
            return .loaded(dst)
        } catch {
            let msg = SpiderMessages.readingFailed
            broadcaster.yield(.pageFailed(index: index, error: msg, progress: progress))
            return .failed(msg)
        }
    }

    public func cancel(_ index: Int) {}
    public func setPreloadCount(_ count: Int) {}

    public func startPage() -> Int {
        if let store = startPageStore, let gid = startPageKey, let info = store.read(gid: gid) { return info.startPage }
        return memoryStartPage
    }

    public func putStartPage(_ page: Int) {
        memoryStartPage = page
        guard let store = startPageStore, let gid = startPageKey else { return }
        var info = store.read(gid: gid) ?? SpiderInfo(gid: gid, token: "archive", pages: max(entries?.count ?? 1, 1))
        info.startPage = page
        store.write(info)
    }

    public nonisolated func imageFilename(at index: Int) -> String {
        "\(archiveURL.deletingPathExtension().lastPathComponent)-\(String(format: "%08d", index + 1))"
    }
}
