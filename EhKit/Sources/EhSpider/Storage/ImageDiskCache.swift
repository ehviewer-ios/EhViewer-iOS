import Foundation

/// 阅读图片磁盘缓存（LRU，按总字节限额）。对应 Android `SpiderDen.sCache`（`SimpleDiskCache(cacheDir/image, readCacheSize MB)`）。
///
/// - 每个键一个文件，文件名为键的安全形式（`image:gid:index` → `image_gid_index`）
/// - 访问时更新修改时间作为 LRU 依据；写入后超出限额从最旧开始删除
/// - 多个 `GalleryLoader` 共享同一个实例（线程安全）
public final class ImageDiskCache: @unchecked Sendable {
    public let directory: URL
    private let lock = NSLock()
    private var maxBytes: Int64
    /// 文件名 → (大小, 最近访问时间)
    private var entries: [String: (size: Int64, access: Date)] = [:]
    private var totalBytes: Int64 = 0
    private let fileManager = FileManager()

    /// - Parameter maxBytes: 对应 `clamp(readCacheSize, 40, 640) MB`
    public init(directory: URL, maxBytes: Int64) {
        self.directory = directory
        self.maxBytes = max(maxBytes, 1)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        scan()
    }

    /// 以设置中的 MB 数构造（clamp 到 40...640）
    public convenience init(directory: URL, readCacheSizeMB: Int) {
        self.init(directory: directory, maxBytes: Int64(min(max(readCacheSizeMB, 40), 640)) * 1024 * 1024)
    }

    public var size: Int64 { lock.withLock { totalBytes } }
    public var limit: Int64 {
        get { lock.withLock { maxBytes } }
        set {
            lock.withLock { maxBytes = max(newValue, 1) }
            trim()
        }
    }

    static func filename(forKey key: String) -> String {
        var s = ""
        for ch in key.unicodeScalars {
            if CharacterSet.alphanumerics.contains(ch) || ch == "-" || ch == "_" || ch == "." {
                s.unicodeScalars.append(ch)
            } else {
                s += "_"
            }
        }
        return s
    }

    public func fileURL(forKey key: String) -> URL {
        directory.appendingPathComponent(Self.filename(forKey: key))
    }

    public func contains(_ key: String) -> Bool {
        fileManager.fileExists(atPath: fileURL(forKey: key).path)
    }

    /// 读取：存在则返回文件 URL 并更新 LRU
    public func get(_ key: String) -> URL? {
        let name = Self.filename(forKey: key)
        let url = directory.appendingPathComponent(name)
        guard fileManager.fileExists(atPath: url.path) else {
            lock.withLock {
                if let e = entries.removeValue(forKey: name) { totalBytes -= e.size }
            }
            return nil
        }
        let now = Date()
        lock.withLock {
            if entries[name] == nil {
                let sz = ImageFiles.fileSize(url, fileManager: fileManager)
                entries[name] = (sz, now)
                totalBytes += sz
            } else {
                entries[name]?.access = now
            }
        }
        try? fileManager.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
        return url
    }

    /// 把临时文件移入缓存（覆盖已有）。返回缓存中的文件 URL
    @discardableResult
    public func put(_ key: String, movingFileAt source: URL) throws -> URL {
        let name = Self.filename(forKey: key)
        let dst = directory.appendingPathComponent(name)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: dst.path) { try? fileManager.removeItem(at: dst) }
        try fileManager.moveItem(at: source, to: dst)
        let sz = ImageFiles.fileSize(dst, fileManager: fileManager)
        lock.withLock {
            if let old = entries[name] { totalBytes -= old.size }
            entries[name] = (sz, Date())
            totalBytes += sz
        }
        trim(keeping: name)
        return dst
    }

    @discardableResult
    public func remove(_ key: String) -> Bool {
        let name = Self.filename(forKey: key)
        let url = directory.appendingPathComponent(name)
        lock.withLock {
            if let e = entries.removeValue(forKey: name) { totalBytes -= e.size }
        }
        return (try? fileManager.removeItem(at: url)) != nil
    }

    public func clear() {
        let names = lock.withLock { () -> [String] in
            defer { entries.removeAll(); totalBytes = 0 }
            return Array(entries.keys)
        }
        for n in names { try? fileManager.removeItem(at: directory.appendingPathComponent(n)) }
    }

    private func scan() {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return }
        var map: [String: (Int64, Date)] = [:]
        var total: Int64 = 0
        for n in names {
            let url = directory.appendingPathComponent(n)
            guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
                  (attrs[.type] as? FileAttributeType) != .typeDirectory else { continue }
            let sz = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            let date = attrs[.modificationDate] as? Date ?? .distantPast
            map[n] = (sz, date)
            total += sz
        }
        lock.withLock {
            entries = map.mapValues { (size: $0.0, access: $0.1) }
            totalBytes = total
        }
        trim()
    }

    /// 超限时按访问时间从旧到新删除（不删除 keeping）
    private func trim(keeping: String? = nil) {
        let victims: [String] = lock.withLock {
            guard totalBytes > maxBytes else { return [] }
            var out: [String] = []
            for (name, e) in entries.sorted(by: { $0.value.access < $1.value.access }) {
                if totalBytes <= maxBytes { break }
                if name == keeping { continue }
                entries.removeValue(forKey: name)
                totalBytes -= e.size
                out.append(name)
            }
            return out
        }
        for n in victims { try? fileManager.removeItem(at: directory.appendingPathComponent(n)) }
    }
}

/// `.ehviewer` 缓存（Caches/spider_info/{gid}）。对应 Android `EhApplication.getSpiderInfoCache`
public struct SpiderInfoCache: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func fileURL(gid: Int64) -> URL { directory.appendingPathComponent(String(gid)) }

    public func read(gid: Int64) -> SpiderInfo? {
        SpiderInfo.read(contentsOf: fileURL(gid: gid))
    }

    public func write(_ info: SpiderInfo) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? info.write(to: fileURL(gid: info.gid))
    }

    public func remove(gid: Int64) {
        try? FileManager.default.removeItem(at: fileURL(gid: gid))
    }
}
