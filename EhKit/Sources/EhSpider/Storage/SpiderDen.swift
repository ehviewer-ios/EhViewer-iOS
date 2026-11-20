import EhStorage
import Foundation

/// 加载模式。对应 `SpiderQueen.MODE_READ / MODE_DOWNLOAD`
public enum LoaderMode: Int, Sendable, Hashable {
    case read = 0
    case download = 1
}

/// 下载根目录 + gid→目录名映射。对应 `SpiderDen` 的静态方法（`findDownloadDirname` / `getGalleryDownloadDir` 等）
public struct DownloadLocation: Sendable {
    /// 下载根目录（对应 `Settings.getDownloadLocation()`）；nil 表示不可用
    public var root: URL?
    public var database: EhDatabase?
    /// 新建目录名时是否优先日文标题（`Settings.getShowJpnTitle`）
    public var preferJapaneseTitle: Bool

    public init(root: URL?, database: EhDatabase?, preferJapaneseTitle: Bool = false) {
        self.root = root
        self.database = database
        self.preferJapaneseTitle = preferJapaneseTitle
    }

    /// 对应 `findDownloadDirname`：先查数据库（sanitize 后写回），再扫描根目录中 "gid-" 开头且名字最长的子目录
    public func findDownloadDirname(gid: Int64) -> String? {
        if let stored = try? database?.downloadDirname(gid: gid) {
            let dirname = SpiderNaming.sanitizeFilename(stored)
            if dirname != stored { try? database?.putDownloadDirname(gid: gid, dirname: dirname) }
            return dirname
        }
        guard let root else { return nil }
        let found = SpiderNaming.findExistingDirname(gid: gid, in: root)
        if let found { try? database?.putDownloadDirname(gid: gid, dirname: found) }
        return found
    }

    /// 对应 `getExistingGalleryDownloadDir`：已知（数据库或已存在）的目录；不创建、不登记新名字
    public func existingGalleryDownloadDir(gid: Int64) -> URL? {
        guard let root, let dirname = findDownloadDirname(gid: gid) else { return nil }
        return root.appendingPathComponent(dirname, isDirectory: true)
    }

    /// 对应 `getGalleryDownloadDir`：找不到时生成 "gid-标题" 并登记到数据库（不创建目录）
    public func galleryDownloadDir(for info: GalleryInfo) -> URL? {
        guard let root else { return nil }
        var dirname = findDownloadDirname(gid: info.gid)
        if dirname == nil {
            let name = SpiderNaming.downloadDirname(for: info, preferJapanese: preferJapaneseTitle)
            try? database?.putDownloadDirname(gid: info.gid, dirname: name)
            dirname = name
        }
        return root.appendingPathComponent(dirname!, isDirectory: true)
    }
}

/// 单个画廊的图片存取（缓存目录 / 下载目录）。对应 Android `spider/SpiderDen.java`。
///
/// - 阅读模式：写入 `ImageDiskCache`（开启"阅读时同步下载"时写下载目录）；读取先缓存后下载目录（只读）
/// - 下载模式：写入下载目录；读取下载目录，没有时从缓存复制过来
public final class SpiderDen: @unchecked Sendable {
    public let galleryInfo: GalleryInfo
    public let location: DownloadLocation
    public let cache: ImageDiskCache?
    /// 下载临时文件目录
    public let tempDirectory: URL
    private let lock = NSLock()
    private var _mode: LoaderMode = .read
    private var _downloadDir: URL?
    /// 已确认没有既有下载目录（避免阅读时反复扫描下载根目录）
    private var _noExistingDir = false
    private var _syncDownloadWhileReading: Bool
    private let fileManager = FileManager()

    public init(galleryInfo: GalleryInfo, location: DownloadLocation, cache: ImageDiskCache?,
                tempDirectory: URL? = nil, syncDownloadWhileReading: Bool = false) {
        self.galleryInfo = galleryInfo
        self.location = location
        self.cache = cache
        self.tempDirectory = tempDirectory
            ?? cache?.directory.appendingPathComponent(".tmp", isDirectory: true)
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("ehspider", isDirectory: true)
        _syncDownloadWhileReading = syncDownloadWhileReading
    }

    var gid: Int64 { galleryInfo.gid }

    public var mode: LoaderMode {
        get { lock.withLock { _mode } }
        set { lock.withLock { _mode = newValue; _noExistingDir = false } }
    }

    public var syncDownloadWhileReading: Bool {
        get { lock.withLock { _syncDownloadWhileReading } }
        set { lock.withLock { _syncDownloadWhileReading = newValue } }
    }

    public var isDownloadMode: Bool { mode == .download }

    private var shouldSyncDownloadWhileReading: Bool { mode == .read && syncDownloadWhileReading }

    // MARK: - 下载目录

    private func resolveDownloadDirLocked() -> URL? {
        if let d = _downloadDir { return d }
        _downloadDir = location.galleryDownloadDir(for: galleryInfo)
        return _downloadDir
    }

    /// 对应 `prepareDownloadStorage`：下载模式下确保目录存在
    @discardableResult
    public func prepareDownloadStorage() -> Bool {
        if mode != .download { return true }
        return ensureDownloadDirExists()
    }

    private func ensureDownloadDirExists() -> Bool {
        guard let dir = lock.withLock({ resolveDownloadDirLocked() }) else { return false }
        if ImageFiles.isDirectory(dir, fileManager: fileManager) { return true }
        do {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            return true
        } catch {
            return false
        }
    }

    /// 对应 `isReady`
    public var isReady: Bool {
        switch mode {
        case .read: return true
        case .download:
            guard let d = lock.withLock({ _downloadDir }) else { return false }
            return ImageFiles.isDirectory(d, fileManager: fileManager)
        }
    }

    /// 已存在的下载目录（对应 `getDownloadDir`）
    public var downloadDir: URL? {
        // 未登记过目录名时不生成新名字，避免阅读时登记无用的 DOWNLOAD_DIRNAME
        let dir: URL? = lock.withLock {
            if let d = _downloadDir { return d }
            if _noExistingDir { return nil }
            if let existing = location.existingGalleryDownloadDir(gid: gid) {
                _downloadDir = existing
                return existing
            }
            _noExistingDir = true
            return nil
        }
        guard let dir, ImageFiles.isDirectory(dir, fileManager: fileManager) else { return nil }
        return dir
    }

    // MARK: - 查询

    private func cacheKey(_ index: Int) -> String { EhCacheKeyFactory.getImageKey(gid, index) }

    private func containInCache(_ index: Int) -> Bool { cache?.contains(cacheKey(index)) ?? false }

    private func findInDownloadDir(_ index: Int) -> URL? {
        guard let dir = downloadDir else { return nil }
        return SpiderNaming.findImageFile(in: dir, index: index, fileManager: fileManager)
    }

    /// 对应 `copyFromCacheToDownloadDir`
    @discardableResult
    func copyFromCacheToDownloadDir(_ index: Int) -> URL? {
        guard let cache, let dir = downloadDir, let src = cache.get(cacheKey(index)),
              let ext = ImageFiles.sniffExtension(fileAt: src) else { return nil }
        let dst = dir.appendingPathComponent(SpiderNaming.imageFilename(index: index, extension: SpiderNaming.fixExtension(ext)))
        try? fileManager.removeItem(at: dst)
        do {
            try fileManager.copyItem(at: src, to: dst)
            return dst
        } catch {
            return nil
        }
    }

    /// 对应 `contain`
    public func contains(_ index: Int) -> Bool {
        switch mode {
        case .read: return containInCache(index) || findInDownloadDir(index) != nil
        case .download: return findInDownloadDir(index) != nil || copyFromCacheToDownloadDir(index) != nil
        }
    }

    /// 某页图片文件（对应 `openInputStreamPipe`）。读取优先级见类型说明
    public func fileURL(for index: Int) -> URL? {
        switch mode {
        case .read:
            if shouldSyncDownloadWhileReading {
                if let u = findInDownloadDir(index) ?? copyFromCacheToDownloadDir(index) { return u }
                return cache?.get(cacheKey(index))
            }
            // 下载目录中的完整图片优先（与"读取优先下载目录"一致）；阅读模式不触发缓存→下载目录复制
            return findInDownloadDir(index) ?? cache?.get(cacheKey(index))
        case .download:
            return findInDownloadDir(index) ?? copyFromCacheToDownloadDir(index)
        }
    }

    // MARK: - 写入

    /// 生成下载临时文件路径
    public func makeTempFileURL() -> URL {
        try? fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        return tempDirectory.appendingPathComponent("\(gid)-\(UUID().uuidString)")
    }

    private func commitToDownloadDir(_ index: Int, _ temp: URL, _ ext: String) throws -> URL {
        guard let dir = downloadDir ?? (ensureDownloadDirExists() ? lock.withLock({ _downloadDir }) : nil) else {
            throw EhError.other("写入失败：下载目录不可用")
        }
        // 删除其它扩展名的旧文件，避免 findImageFile 命中旧图
        for name in SpiderNaming.imageFilenameCandidates(index: index) {
            try? fileManager.removeItem(at: dir.appendingPathComponent(name))
        }
        let dst = dir.appendingPathComponent(SpiderNaming.imageFilename(index: index, extension: SpiderNaming.fixExtension(ext)))
        try fileManager.moveItem(at: temp, to: dst)
        return dst
    }

    /// 把下载完成的临时文件放到最终位置（对应 `openOutputStreamPipe` + 写入）。返回最终文件 URL
    /// - Parameter ext: 带点扩展名
    public func commit(_ index: Int, tempFile: URL, extension ext: String) throws -> URL {
        switch mode {
        case .read:
            if shouldSyncDownloadWhileReading, ensureDownloadDirExists(),
               let u = try? commitToDownloadDir(index, tempFile, ext) {
                return u
            }
            guard let cache else { throw EhError.other("写入失败：缓存不可用") }
            return try cache.put(cacheKey(index), movingFileAt: tempFile)
        case .download:
            return try commitToDownloadDir(index, tempFile, ext)
        }
    }

    /// 对应 `remove`：删除缓存与下载目录中的该页
    @discardableResult
    public func remove(_ index: Int) -> Bool {
        var result = cache?.remove(cacheKey(index)) ?? false
        if let dir = downloadDir {
            for name in SpiderNaming.imageFilenameCandidates(index: index) {
                result = ((try? fileManager.removeItem(at: dir.appendingPathComponent(name))) != nil) || result
            }
        }
        return result
    }
}
