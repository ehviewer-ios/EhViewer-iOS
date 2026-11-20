import Foundation
import ZIPFoundation

/// 归档 zip 解压与本地图片整理工具。对应 Android `ArchiverDownloadCompleter` 的 companion 方法
/// 以及 `DownloadAlbumImporter` 中的目录扫描逻辑。
public enum ArchiveExtractor {
    /// 归档文件基名的 UTF-8 上限（255 - ".zip"）
    public static let maxArchiverBasenameUTF8Bytes = 255 - ".zip".utf8.count

    /// 对应 `createFileName`：sanitize → 按 UTF-8 截断 → 为空时 "archiver_{gid}"
    public static func createFileName(_ name: String?, gid: Int64) -> String {
        var result = name.map { SpiderNaming.sanitizeFilename($0) } ?? ""
        result = truncateUTF8(result, maxBytes: maxArchiverBasenameUTF8Bytes)
        if result.isEmpty {
            result = gid > 0 ? "archiver_\(gid)" : "archiver"
        }
        return result
    }

    /// 按完整码点截断到 UTF-8 ≤ maxBytes。对应 `truncateUtf8ToMaxBytes`
    public static func truncateUTF8(_ s: String, maxBytes: Int) -> String {
        guard !s.isEmpty, maxBytes > 0 else { return s }
        var count = 0
        var out = String.UnicodeScalarView()
        for scalar in s.unicodeScalars {
            let n = scalar.utf8.count
            if count + n > maxBytes { break }
            count += n
            out.append(scalar)
        }
        return String(out)
    }

    /// 条目基名（最后一个 / 或 \ 之后）
    static func entryBaseName(_ name: String) -> String {
        guard let i = name.lastIndex(where: { $0 == "/" || $0 == "\\" }) else { return name }
        return String(name[name.index(after: i)...])
    }

    /// 对应 `unzipArchive`：把 zip 中的图片按条目顺序解压为 destDir/%08d.ext（短文件名，规避 zip 内超长目录名）。
    /// 目录条目、非图片、路径含 ".." 的条目跳过。destDir 已存在时先删除。失败时删除 destDir。
    /// - Returns: 解压出的图片数（> 0）
    @discardableResult
    public static func unzipArchive(_ zipURL: URL, to destDir: URL, fileManager: FileManager = .default) throws -> Int {
        if fileManager.fileExists(atPath: destDir.path) {
            do { try fileManager.removeItem(at: destDir) } catch {
                throw SpiderImportError.copyFailed("无法删除残留目录 \(destDir.lastPathComponent)")
            }
        }
        do {
            try fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)
        } catch {
            throw SpiderImportError.copyFailed("无法创建目录 \(destDir.lastPathComponent)")
        }
        var imageIndex = 0
        do {
            let archive: Archive
            do {
                archive = try Archive(url: zipURL, accessMode: .read)
            } catch {
                throw SpiderImportError.invalidArchive(SpiderMessages.readable(error))
            }
            for entry in archive {
                let name = entry.path
                if entry.type != .file || name.contains("..") { continue }
                let baseName = entryBaseName(name)
                if baseName.isEmpty || !ImageFiles.isSupportedImageName(baseName) { continue }
                let ext = ImageFiles.imageExtension(ofFilename: baseName)
                let outFile = destDir.appendingPathComponent(SpiderNaming.imageFilename(index: imageIndex, extension: ext))
                do {
                    _ = try archive.extract(entry, to: outFile)
                } catch {
                    throw SpiderImportError.invalidArchive("解压失败：\(SpiderMessages.readable(error))")
                }
                imageIndex += 1
            }
        } catch {
            try? fileManager.removeItem(at: destDir)
            throw error
        }
        if imageIndex == 0 {
            try? fileManager.removeItem(at: destDir)
            throw SpiderImportError.noImages
        }
        return imageIndex
    }

    /// 对应 `resolveImportRoot`：当前层没有图片且只有一个子目录时向下钻取
    public static func resolveImportRoot(_ dir: URL, fileManager: FileManager = .default) -> URL? {
        guard ImageFiles.isDirectory(dir, fileManager: fileManager),
              let children = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
        var hasImage = false
        var onlySubdir: URL?
        var subdirCount = 0
        for child in children {
            if ImageFiles.isDirectory(child, fileManager: fileManager) {
                onlySubdir = child
                subdirCount += 1
            } else if ImageFiles.isSupportedImageName(child.lastPathComponent) {
                hasImage = true
            }
        }
        if hasImage { return dir }
        if subdirCount == 1, let onlySubdir { return resolveImportRoot(onlySubdir, fileManager: fileManager) }
        return dir
    }

    /// 对应 `collectImageFiles`：递归收集图片（未排序）
    public static func collectImageFiles(_ root: URL, fileManager: FileManager = .default) -> [URL] {
        var out: [URL] = []
        func walk(_ dir: URL) {
            guard let children = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
            for child in children {
                if ImageFiles.isDirectory(child, fileManager: fileManager) {
                    walk(child)
                } else if ImageFiles.isSupportedImageName(child.lastPathComponent) {
                    out.append(child)
                }
            }
        }
        walk(root)
        return out
    }

    /// 把图片复制（或移动）到下载目录，命名为 %08d.ext（按 copied 计数，无空洞）。返回成功数
    public static func copyImages(_ images: [URL], to downloadDir: URL, move: Bool = false,
                                  fileManager: FileManager = .default) -> Int {
        var copied = 0
        for picture in images where ImageFiles.isFile(picture, fileManager: fileManager) {
            let ext = ImageFiles.imageExtension(ofFilename: picture.lastPathComponent)
            let dst = downloadDir.appendingPathComponent(SpiderNaming.imageFilename(index: copied, extension: ext))
            for name in SpiderNaming.imageFilenameCandidates(index: copied) {
                try? fileManager.removeItem(at: downloadDir.appendingPathComponent(name))
            }
            do {
                if move {
                    try fileManager.moveItem(at: picture, to: dst)
                } else {
                    try fileManager.copyItem(at: picture, to: dst)
                }
                copied += 1
            } catch {
                try? fileManager.removeItem(at: dst)
            }
        }
        return copied
    }
}
