import Foundation

/// 下载目录与图片文件的命名规则（纯函数）。
/// 对应 Android `spider/SpiderDen.java` 中的路径/命名逻辑、`FileUtils.sanitizeFilename`、
/// `GalleryProvider2.SUPPORT_IMAGE_EXTENSIONS`，以及 `download/DownloadGalleryMetaHelper.java`。
public enum SpiderNaming {
    /// 对应 `SpiderQueen.SPIDER_INFO_FILENAME`
    public static let spiderInfoFilename = ".ehviewer"

    /// 支持的图片扩展名（带点，顺序有意义：第一个为兜底）。对应 `GalleryProvider2.SUPPORT_IMAGE_EXTENSIONS`
    public static let supportImageExtensions = [".jpg", ".jpeg", ".png", ".gif", ".webp"]

    /// 对应 `FileUtils.FORBIDDEN_FILENAME_CHARACTERS`
    public static let forbiddenFilenameCharacters: Set<Unicode.Scalar> = ["\\", "/", ":", "*", "?", "\"", "<", ">", "|"]

    /// 对应 `StringUtils.WHITE_SPACE_ARRAY`（trim 只去掉这四种）
    static let trimCharacters: Set<Unicode.Scalar> = ["\u{0009}", "\u{0020}", "\u{00A0}", "\u{3000}"]

    /// 文件名 UTF-8 最大字节数
    public static let maxFilenameBytes = 255

    /// 对应 `FileUtils.sanitizeFilename`：去掉禁用字符 → 截断到 UTF-8 ≤ 255 字节 → 去掉首尾空白。
    /// 注：Java 版在代理对处截断时会留下孤立高位代理，这里按完整码点截断。
    public static func sanitizeFilename(_ filename: String) -> String {
        var scalars = String.UnicodeScalarView()
        var byteCount = 0
        for s in filename.unicodeScalars where !forbiddenFilenameCharacters.contains(s) {
            let v = s.value
            byteCount += v <= 0x7F ? 1 : v <= 0x7FF ? 2 : v <= 0xFFFF ? 3 : 4
            if byteCount > maxFilenameBytes { break }
            scalars.append(s)
        }
        var arr = Array(scalars)
        while let first = arr.first, trimCharacters.contains(first) { arr.removeFirst() }
        while let last = arr.last, trimCharacters.contains(last) { arr.removeLast() }
        var out = String.UnicodeScalarView()
        out.append(contentsOf: arr)
        return String(out)
    }

    /// 下载目录名前缀 "gid-"。用于在下载根目录中查找已有目录（`StartWithFilenameFilter`）
    public static func downloadDirnamePrefix(gid: Int64) -> String { "\(gid)-" }

    /// 新建下载目录名：`sanitize("{gid}-{suitableTitle}")`。对应 `getGalleryDownloadDir` 中的创建分支
    public static func downloadDirname(gid: Int64, title: String?) -> String {
        sanitizeFilename("\(gid)-\(title ?? "null")")
    }

    /// 按设置选择日文/英文标题后生成目录名（`EhUtils.getSuitableTitle`）
    public static func downloadDirname(for info: GalleryInfo, preferJapanese: Bool) -> String {
        downloadDirname(gid: info.gid, title: suitableTitle(info, preferJapanese: preferJapanese))
    }

    /// 对应 `EhUtils.getSuitableTitle`（可能为 nil，与 Java 一致：两者都空时 Java 会拼出 "null"）
    public static func suitableTitle(_ info: GalleryInfo, preferJapanese: Bool) -> String? {
        if preferJapanese {
            return (info.titleJpn?.isEmpty ?? true) ? info.title : info.titleJpn
        }
        return (info.title?.isEmpty ?? true) ? info.titleJpn : info.title
    }

    /// 在已有目录名中挑出属于该 gid 的目录：以 "gid-" 开头、名字最长者。对应 `findDownloadDirname` 的目录扫描分支
    public static func pickExistingDirname(gid: Int64, candidates: [String]) -> String? {
        let prefix = downloadDirnamePrefix(gid: gid)
        var best: String?
        var maxLength = -1
        for name in candidates where name.hasPrefix(prefix) {
            let length = name.utf16.count
            if length > maxLength {
                maxLength = length
                best = name
            }
        }
        return best
    }

    /// 在下载根目录中查找该 gid 的已有目录（只看子目录）
    public static func findExistingDirname(gid: Int64, in root: URL, fileManager: FileManager = .default) -> String? {
        guard let names = try? fileManager.contentsOfDirectory(atPath: root.path) else { return nil }
        let dirs = names.filter { name in
            var isDir: ObjCBool = false
            return fileManager.fileExists(atPath: root.appendingPathComponent(name).path, isDirectory: &isDir) && isDir.boolValue
        }
        return pickExistingDirname(gid: gid, candidates: dirs)
    }

    /// 图片文件名 `%08d{ext}`，index 从 0 开始，文件名从 1 开始。对应 `generateImageFilename`
    /// - Parameter extension: 带点扩展名，如 ".jpg"
    public static func imageFilename(index: Int, extension ext: String) -> String {
        String(format: "%08d", index + 1) + ext
    }

    /// 某页所有可能的文件名（按 `supportImageExtensions` 顺序）。对应 `findImageFile` / `removeFromDownloadDir`
    public static func imageFilenameCandidates(index: Int) -> [String] {
        supportImageExtensions.map { imageFilename(index: index, extension: $0) }
    }

    /// 不支持的扩展名回退为 ".jpg"。对应 `fixExtension`
    public static func fixExtension(_ ext: String) -> String {
        supportImageExtensions.contains(ext) ? ext : supportImageExtensions[0]
    }

    /// 由 MIME 类型得到扩展名（带点并经过 `fixExtension`）。对应 `MimeTypeMap.getExtensionFromMimeType` + fix
    public static func imageExtension(forMimeType mime: String?) -> String? {
        guard let mime = mime?.lowercased() else { return nil }
        let ext: String
        switch mime {
        case "image/jpeg", "image/jpg", "image/pjpeg": ext = ".jpg"
        case "image/png": ext = ".png"
        case "image/gif": ext = ".gif"
        case "image/webp": ext = ".webp"
        default:
            guard mime.hasPrefix("image/") else { return nil }
            ext = "." + mime.dropFirst("image/".count)
        }
        return fixExtension(ext)
    }

    /// 反解图片文件名得到页序号（0 起）："00000001.jpg" → 0。非图片 / 格式不符返回 nil
    public static func imageIndex(fromFilename name: String) -> Int? {
        guard let dot = name.lastIndex(of: ".") else { return nil }
        let ext = String(name[dot...]).lowercased()
        guard supportImageExtensions.contains(ext) else { return nil }
        let stem = name[..<dot]
        guard stem.count == 8, stem.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(stem), n >= 1 else {
            return nil
        }
        return n - 1
    }

    /// 在目录中查找某页图片。对应 `findImageFile`
    public static func findImageFile(in dir: URL, index: Int, fileManager: FileManager = .default) -> URL? {
        for name in imageFilenameCandidates(index: index) {
            let url = dir.appendingPathComponent(name)
            if fileManager.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// 下载目录时间戳（毫秒）：优先目录创建时间，其次修改时间，最后回退任务时间。
    /// 对应 `DownloadGalleryMetaHelper.getGalleryDirectoryTimestamp`
    public static func galleryDirectoryTimestamp(_ dir: URL?, fallbackTime: Int64, fileManager: FileManager = .default) -> Int64 {
        if let dir {
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue,
               let attrs = try? fileManager.attributesOfItem(atPath: dir.path) {
                if let created = attrs[.creationDate] as? Date {
                    let ms = Int64(created.timeIntervalSince1970 * 1000)
                    if ms > 0 { return ms }
                }
                if let modified = attrs[.modificationDate] as? Date {
                    let ms = Int64(modified.timeIntervalSince1970 * 1000)
                    if ms > 0 { return ms }
                }
            }
        }
        return max(fallbackTime, 0)
    }
}
