import Foundation

/// 下载目录迁移的文件工具。对应 Android `client/wifi/WiFiDownloadMigrationHelper.java`。
///
/// Android → iOS 的等价替换：
/// - 下载根目录：Android `Settings.getDownloadLocation()`（UniFile，可能是 SAF tree Uri）→ 调用方传入的本地目录 URL
///   （默认 `AppDirectories.defaultDownloadDir`，即 Documents/download）
/// - `UniFile.subFile/createFile/createDirectory` → FileManager；相对路径一律用 "/" 分隔（与 Android 一致）
/// - 额外的安全检查：对端传来的目录名 / 相对路径不允许 ".."、"." 或空段，防止写出下载目录之外
public enum WiFiDownloadMigration {
    /// 对应 `FILE_CHUNK_SIZE`
    public static let fileChunkSize = 256 * 1024
    /// 对应 `SpiderQueen.SPIDER_INFO_BACKUP_DIR`：扫描时跳过
    public static let spiderInfoBackupDir = "backupDir"

    public struct FileMeta: Sendable, Hashable {
        /// 相对画廊目录的路径，"/" 分隔
        public var name: String
        /// 小写十六进制 MD5
        public var md5: String
        public var size: Int64

        public init(name: String, md5: String, size: Int64) {
            self.name = name; self.md5 = md5; self.size = size
        }
    }

    public struct DirManifest: Sendable, Hashable {
        public var gid: Int64
        public var dirname: String
        public var files: [FileMeta]
        /// 当前目录序号（1 起）
        public var pageIndex: Int32
        /// 目录总数
        public var pageSize: Int32

        public init(gid: Int64, dirname: String, files: [FileMeta], pageIndex: Int32, pageSize: Int32) {
            self.gid = gid; self.dirname = dirname; self.files = files
            self.pageIndex = pageIndex; self.pageSize = pageSize
        }
    }

    public struct DirAck: Sendable, Hashable {
        public var gid: Int64
        public var dirname: String
        public var filesNeeded: [String]

        public init(gid: Int64, dirname: String, filesNeeded: [String]) {
            self.gid = gid; self.dirname = dirname; self.filesNeeded = filesNeeded
        }
    }

    public struct FileChunk: Sendable, Hashable {
        public var gid: Int64
        public var name: String
        public var fileMd5: String
        public var chunkIndex: Int32
        public var chunkTotal: Int32
        public var data: Data
        public var lastChunk: Bool

        public init(gid: Int64, name: String, fileMd5: String, chunkIndex: Int32, chunkTotal: Int32, data: Data,
                    lastChunk: Bool) {
            self.gid = gid; self.name = name; self.fileMd5 = fileMd5; self.chunkIndex = chunkIndex
            self.chunkTotal = chunkTotal; self.data = data; self.lastChunk = lastChunk
        }
    }

    public struct GalleryDirEntry: Sendable, Hashable {
        public var gid: Int64
        public var dirname: String
        public var url: URL

        public init(gid: Int64, dirname: String, url: URL) {
            self.gid = gid; self.dirname = dirname; self.url = url
        }
    }

    // MARK: - 扫描（发送端）

    /// 对应 `scanGalleryDirs`：下载根目录下名为 "{gid}-…" 的子目录（按名称排序，Android 为文件系统顺序）
    public static func scanGalleryDirs(root: URL, fileManager: FileManager = .default) -> [GalleryDirEntry] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: root.path) else { return [] }
        var result: [GalleryDirEntry] = []
        for name in names.sorted() {
            let url = root.appendingPathComponent(name, isDirectory: true)
            guard isDirectory(url, fileManager) else { continue }
            let gid = parseGidFromDirname(name)
            if gid < 0 { continue }
            result.append(GalleryDirEntry(gid: gid, dirname: name, url: url))
        }
        return result
    }

    /// 对应 `parseGidFromDirname`：第一个 '-' 之前的部分按 Java `Long.parseLong` 解析，失败返回 -1
    public static func parseGidFromDirname(_ dirname: String) -> Int64 {
        guard let dash = dirname.firstIndex(of: "-"), dash > dirname.startIndex else { return -1 }
        return Int64(dirname[..<dash]) ?? -1
    }

    /// 对应 `scanGalleryDir`：递归列出全部文件（跳过 backupDir），计算 MD5。无法读取的文件跳过
    public static func scanGalleryDir(_ dir: URL, fileManager: FileManager = .default) -> [FileMeta] {
        var list: [FileMeta] = []
        collectFiles(dir, prefix: "", into: &list, fileManager: fileManager)
        return list
    }

    private static func collectFiles(_ dir: URL, prefix: String, into out: inout [FileMeta],
                                     fileManager: FileManager) {
        guard let names = try? fileManager.contentsOfDirectory(atPath: dir.path) else { return }
        for name in names.sorted() {
            let url = dir.appendingPathComponent(name)
            let rel = prefix.isEmpty ? name : prefix + "/" + name
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                if name == spiderInfoBackupDir { continue }
                collectFiles(url, prefix: rel, into: &out, fileManager: fileManager)
            } else if let md5 = computeMd5Hex(url) {
                out.append(FileMeta(name: rel, md5: md5, size: fileSize(url, fileManager)))
            }
        }
    }

    // MARK: - 路径（双方）

    /// 目录名是否可安全地作为下载根目录下的一级子目录
    public static func isSafeDirname(_ dirname: String) -> Bool {
        !dirname.isEmpty && dirname != "." && dirname != ".." && !dirname.contains("/")
            && !dirname.contains("\0")
    }

    /// 相对路径的各段；含空段、"."、".." 或 NUL 时返回 nil
    public static func safeComponents(_ relPath: String) -> [String]? {
        let parts = relPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty else { return nil }
        for p in parts where p.isEmpty || p == "." || p == ".." || p.contains("\0") {
            return nil
        }
        return parts
    }

    /// 对应 `resolveGalleryDir`：root/dirname（目录名不安全时为 nil）
    public static func resolveGalleryDir(root: URL, dirname: String) -> URL? {
        isSafeDirname(dirname) ? root.appendingPathComponent(dirname, isDirectory: true) : nil
    }

    /// 对应 `ensureGalleryDir`：确保 root/dirname 是目录。返回目录与“是否新建”
    /// （Android 仅在新建时写 `EhDB.putDownloadDirname`）
    public static func ensureGalleryDir(root: URL, dirname: String,
                                        fileManager: FileManager = .default) -> (url: URL, created: Bool)? {
        guard let dir = resolveGalleryDir(root: root, dirname: dirname) else { return nil }
        if isDirectory(dir, fileManager) { return (dir, false) }
        do {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            return (dir, true)
        } catch {
            return nil
        }
    }

    /// 对应 `resolveFileInGallery`（路径不安全时为 nil；不检查是否存在）
    public static func resolveFileInGallery(_ galleryDir: URL, _ relPath: String) -> URL? {
        guard let parts = safeComponents(relPath) else { return nil }
        var url = galleryDir
        for p in parts { url.appendPathComponent(p) }
        return url
    }

    /// 对应 `filterFilesNeeded`：本地不存在或 MD5 不同（忽略大小写）的文件名。大小不同时直接判定需要，省去 MD5。
    /// 路径不安全的条目不请求
    public static func filterFilesNeeded(_ galleryDir: URL, remoteFiles: [FileMeta],
                                         fileManager: FileManager = .default) -> [String] {
        var needed: [String] = []
        for meta in remoteFiles {
            guard let local = resolveFileInGallery(galleryDir, meta.name) else { continue }
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: local.path, isDirectory: &isDir), !isDir.boolValue,
                  fileSize(local, fileManager) == meta.size,
                  let md5 = computeMd5Hex(local), md5.caseInsensitiveCompare(meta.md5) == .orderedSame
            else {
                needed.append(meta.name)
                continue
            }
        }
        return needed
    }

    // MARK: - 写入（接收端）

    /// 对应 `writeChunk`：offset == 0 时新建 / 截断，否则追加（Android `openOutputStream(append: offset != 0)`）。
    /// 父目录不存在时逐级创建
    @discardableResult
    public static func writeChunk(_ galleryDir: URL, relPath: String, data: Data, offset: Int64,
                                  fileManager: FileManager = .default) throws -> Bool {
        guard let target = resolveFileInGallery(galleryDir, relPath) else { return false }
        let parent = target.deletingLastPathComponent()
        if !isDirectory(parent, fileManager) {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        if offset == 0 || !fileManager.fileExists(atPath: target.path) {
            guard fileManager.createFile(atPath: target.path, contents: data) else {
                throw CocoaError(.fileWriteUnknown)
            }
            return true
        }
        let handle = try FileHandle(forWritingTo: target)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        return true
    }

    /// 对应 `verifyFileMd5`
    public static func verifyFileMd5(_ url: URL, expected: String) -> Bool {
        guard let actual = computeMd5Hex(url) else { return false }
        return actual.caseInsensitiveCompare(expected) == .orderedSame
    }

    /// 对应 `computeMd5Hex`：流式读取（8 KiB → 这里 256 KiB 一块），失败返回 nil
    public static func computeMd5Hex(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var md5 = MD5()
        do {
            while let data = try handle.read(upToCount: fileChunkSize), !data.isEmpty {
                md5.update(data)
            }
        } catch {
            return nil
        }
        return md5.finalizeHex()
    }

    /// 文件分块数：ceil(size / chunkSize)，至少 1（对应 `sendFileChunks` 中的 chunkTotal）
    public static func chunkCount(fileSize: Int64, chunkSize: Int = fileChunkSize) -> Int32 {
        let n = (fileSize + Int64(chunkSize) - 1) / Int64(chunkSize)
        return Int32(clamping: max(n, 1))
    }

    /// 接收端每个文件已写入的字节数。对应 `FileWriteState`
    public struct FileWriteState: Sendable {
        private var offsets: [String: Int64] = [:]

        public init() {}

        public func offset(_ name: String) -> Int64 { offsets[name] ?? 0 }
        public mutating func addWritten(_ name: String, _ bytes: Int) { offsets[name, default: 0] += Int64(bytes) }
        public mutating func clear(_ name: String) { offsets[name] = nil }
    }

    // MARK: - 工具

    static func isDirectory(_ url: URL, _ fileManager: FileManager) -> Bool {
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    static func fileSize(_ url: URL, _ fileManager: FileManager) -> Int64 {
        ((try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
