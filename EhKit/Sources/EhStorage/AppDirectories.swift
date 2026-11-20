import Foundation

/// 应用目录。对应 Android `AppConfig.java` 的目录逻辑（及 `EhApplication` / `SpiderDen` 中的缓存目录）。
///
/// | Android                                  | iOS                                   |
/// |------------------------------------------|---------------------------------------|
/// | 外部存储 `EhViewer/download`（默认下载）    | `Documents/download`                  |
/// | 外部存储 `EhViewer/{temp,archiver,image,parse_error,logcat,data,crash}` | `Documents/<同名>` |
/// | `cacheDir/{temp,archiver}`               | `Caches/{temp,archiver}`              |
/// | `cacheDir/image`（阅读图片缓存）           | `Caches/image`                        |
/// | `cacheDir/thumb`（缩略图缓存）             | `Caches/thumb`                        |
/// | `cacheDir/spider_info`                   | `Caches/spider_info`                  |
/// | `cacheDir/http_cache`                    | `Caches/http_cache`                   |
/// | `filesDir/<name>`（如 tag-translations）  | `Application Support/<name>`          |
/// | `databases/eh.db`                        | `Application Support/eh.db`           |
///
/// 所有 `xxxDir` 访问时自动创建目录（对应 `FileUtils.ensureDirectory`），创建失败返回 nil。
public struct AppDirectories: Sendable {
    public static let download = "download"
    public static let temp = "temp"
    public static let archiver = "archiver"
    public static let image = "image"
    public static let parseError = "parse_error"
    public static let logcat = "logcat"
    public static let data = "data"
    public static let crash = "crash"
    public static let thumb = "thumb"
    public static let spiderInfo = "spider_info"
    public static let httpCache = "http_cache"

    /// 用户可见的数据根（Files App 中可见，对应 Android 外部存储 `EhViewer/`）
    public let documents: URL
    /// 可被系统清理的缓存根（对应 Android `getCacheDir()`）
    public let caches: URL
    /// 应用私有数据根（对应 Android `getFilesDir()` / `databases/`）
    public let applicationSupport: URL

    public init(documents: URL, caches: URL, applicationSupport: URL) {
        self.documents = documents
        self.caches = caches
        self.applicationSupport = applicationSupport
    }

    /// App 沙盒中的标准目录
    public static func standard(fileManager: FileManager = .default) -> AppDirectories {
        func dir(_ d: FileManager.SearchPathDirectory) -> URL {
            fileManager.urls(for: d, in: .userDomainMask).first ?? fileManager.temporaryDirectory
        }
        return AppDirectories(documents: dir(.documentDirectory), caches: dir(.cachesDirectory),
                              applicationSupport: dir(.applicationSupportDirectory))
    }

    /// 以一个根目录构造（测试用）：root/Documents、root/Caches、root/Application Support
    public init(root: URL) {
        self.init(documents: root.appendingPathComponent("Documents", isDirectory: true),
                  caches: root.appendingPathComponent("Caches", isDirectory: true),
                  applicationSupport: root.appendingPathComponent("Application Support", isDirectory: true))
    }

    // MARK: - 用户可见目录（对应 getDirInExternalAppDir）

    /// 默认下载根目录。对应 `getDefaultDownloadDir`
    public var defaultDownloadDir: URL? { Self.ensure(documents.appendingPathComponent(Self.download, isDirectory: true)) }
    public var externalTempDir: URL? { Self.ensure(documents.appendingPathComponent(Self.temp, isDirectory: true)) }
    public var externalArchiverDir: URL? { Self.ensure(documents.appendingPathComponent(Self.archiver, isDirectory: true)) }
    /// 保存的图片。对应 `getExternalImageDir`
    public var externalImageDir: URL? { Self.ensure(documents.appendingPathComponent(Self.image, isDirectory: true)) }
    public var externalParseErrorDir: URL? { Self.ensure(documents.appendingPathComponent(Self.parseError, isDirectory: true)) }
    public var externalLogcatDir: URL? { Self.ensure(documents.appendingPathComponent(Self.logcat, isDirectory: true)) }
    /// 数据导出目录。对应 `getExternalDataDir`
    public var externalDataDir: URL? { Self.ensure(documents.appendingPathComponent(Self.data, isDirectory: true)) }
    public var externalCrashDir: URL? { Self.ensure(documents.appendingPathComponent(Self.crash, isDirectory: true)) }

    // MARK: - 缓存目录

    /// 对应 `getTempDir`（cacheDir/temp）
    public var tempDir: URL? { Self.ensure(caches.appendingPathComponent(Self.temp, isDirectory: true)) }
    /// 对应 `getArchiverDir`（cacheDir/archiver）
    public var archiverDir: URL? { Self.ensure(caches.appendingPathComponent(Self.archiver, isDirectory: true)) }
    /// 阅读图片磁盘缓存（SpiderDen sCache）
    public var imageCacheDir: URL? { Self.ensure(caches.appendingPathComponent(Self.image, isDirectory: true)) }
    public var thumbCacheDir: URL? { Self.ensure(caches.appendingPathComponent(Self.thumb, isDirectory: true)) }
    /// `.ehviewer` 缓存（EhApplication mSpiderInfoCache）
    public var spiderInfoCacheDir: URL? { Self.ensure(caches.appendingPathComponent(Self.spiderInfo, isDirectory: true)) }
    public var httpCacheDir: URL? { Self.ensure(caches.appendingPathComponent(Self.httpCache, isDirectory: true)) }

    // MARK: - 私有数据

    /// 对应 `getFilesDir(name)`
    public func filesDir(_ name: String) -> URL? {
        Self.ensure(applicationSupport.appendingPathComponent(name, isDirectory: true))
    }

    /// 数据库文件路径（Application Support/eh.db），会确保父目录存在
    public var databaseURL: URL {
        _ = Self.ensure(applicationSupport)
        return applicationSupport.appendingPathComponent(EhDatabase.defaultFilename)
    }

    // MARK: - 工具

    /// 对应 `createTempFile`：在 tempDir 下生成一个不存在的文件路径（不创建文件）
    public func createTempFile(extension ext: String? = nil) -> URL? {
        guard let dir = tempDir else { return nil }
        let name = UUID().uuidString + (ext.map { ".\($0)" } ?? "")
        return dir.appendingPathComponent(name)
    }

    /// 解析错误时保存页面正文。对应 `saveParseErrorBody`（文件名为可读时间）
    @discardableResult
    public func saveParseErrorBody(_ body: String, now: Date = Date()) -> URL? {
        guard let dir = externalParseErrorDir else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HH-mm-ss-SSS"
        let url = dir.appendingPathComponent(f.string(from: now) + ".txt")
        do {
            try Data(body.utf8).write(to: url)
            return url
        } catch {
            return nil
        }
    }

    /// 对应 `deleteOldParseErrorFiles`：删除 3 天前的解析错误文件
    public func deleteOldParseErrorFiles(now: Date = Date(), fileManager: FileManager = .default) {
        guard let dir = externalParseErrorDir,
              let names = try? fileManager.contentsOfDirectory(atPath: dir.path) else { return }
        let threshold = now.addingTimeInterval(-3 * 24 * 60 * 60)
        for name in names {
            let url = dir.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue,
                  let modified = (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                  modified < threshold else { continue }
            try? fileManager.removeItem(at: url)
        }
    }

    /// 对应 `FileUtils.ensureDirectory`：目录存在或创建成功返回 url；同名文件存在返回 nil
    static func ensure(_ url: URL, fileManager: FileManager = .default) -> URL? {
        var isDir: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDir) {
            return isDir.boolValue ? url : nil
        }
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        } catch {
            return nil
        }
    }
}
