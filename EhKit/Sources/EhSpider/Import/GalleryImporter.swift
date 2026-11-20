import EhStorage
import Foundation

/// 本地导入：压缩包、图片文件夹、Android 下载目录、归档下载完成后的 zip。
/// 对应 Android `DownloadArchiveImporter`、`DownloadAlbumImporter`、`ArchiverDownloadCompleter.importGallery`。
/// 文件操作在后台执行，登记下载项在主线程。
extension DownloadManager {
    /// 导入相册的 archiveUri 前缀（`DownloadAlbumImporter.URI_PREFIX`）
    public nonisolated static let localAlbumURIPrefix = "local-album:"
    public nonisolated static let localToken = "local"
    public nonisolated static let localThumb = "local"
    public nonisolated static let localAlbumUploader = "Local Album"
    public nonisolated static let localArchiveUploader = "Local Archive"
    public nonisolated static let thumbFilename = ".thumb"

    /// 对应 `DownloadAlbumImporter.isLocalAlbum`
    public nonisolated static func isLocalAlbum(_ info: DownloadInfo) -> Bool {
        info.archiveUri?.hasPrefix(localAlbumURIPrefix) ?? false
    }

    /// 是否为导入的压缩包（阅读时应使用 `ArchiveSource`）
    public nonisolated static func isLocalArchive(_ info: DownloadInfo) -> Bool {
        guard let uri = info.archiveUri else { return false }
        return !uri.hasPrefix(localAlbumURIPrefix)
    }

    /// 生成不冲突的本地 gid（毫秒时间戳，与 Android 一致）
    private func uniqueLocalGid() -> Int64 {
        var gid = now()
        while infos[gid] != nil || ((try? database.containDownloadInfo(gid: gid)) ?? false) { gid += 1 }
        return gid
    }

    // MARK: - 压缩包（对应 DownloadArchiveImporter）

    /// 导入 zip / cbz：登记为已完成下载（archiveUri 指向文件），阅读时用 `ArchiveSource`。
    /// rar / cbr / 7z 抛 `SpiderImportError.unsupportedFormat`。
    /// - Parameter copyInto: 提供时先把文件复制到该目录（例如 App 的 Documents/archive），避免依赖外部文件权限
    @discardableResult
    public func importArchive(_ url: URL, copyInto: URL? = nil, label: String? = nil) async throws -> DownloadInfo {
        try SpiderImportError.checkArchiveFormat(url)
        let uriString = url.absoluteString
        if infos.values.contains(where: { $0.archiveUri == uriString }) { throw SpiderImportError.alreadyImported }

        let finalURL: URL = try await Task.detached {
            // 校验能打开且有图片
            let archive = try ArchiveSource.openArchive(url)
            if ArchiveSource.imageEntryPaths(of: archive).isEmpty { throw SpiderImportError.noImages }
            guard let dir = copyInto else { return url }
            let fm = FileManager.default
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            var dst = dir.appendingPathComponent(url.lastPathComponent)
            if dst.standardizedFileURL == url.standardizedFileURL { return url }
            var n = 1
            while fm.fileExists(atPath: dst.path) {
                dst = dir.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent) (\(n)).\(url.pathExtension)")
                n += 1
            }
            do { try fm.copyItem(at: url, to: dst) } catch { throw SpiderImportError.copyFailed(SpiderMessages.readable(error)) }
            return dst
        }.value

        let gid = uniqueLocalGid()
        var info = DownloadInfo(gid: gid, token: "", title: url.deletingPathExtension().lastPathComponent,
                                category: EhCategory.unknown.rawValue, uploader: Self.localArchiveUploader, rating: -1,
                                state: DownloadInfo.stateFinish, legacy: 0, time: now(), label: label,
                                archiveUri: finalURL.absoluteString)
        info.total = 0
        addDownload([info])
        return infos[gid] ?? info
    }

    // MARK: - 文件夹

    /// 导入文件夹：
    /// - 含有效 `.ehviewer`（文本或 CBOR，Android 拷贝来的下载目录）：恢复 gid / token，目录复制到下载根目录并登记
    /// - 否则按相册导入（对应 DownloadAlbumImporter）：图片按自然排序复制为 %08d.ext，登记为本地画廊
    @discardableResult
    public func importFolder(_ url: URL, label: String? = nil, move: Bool = false) async throws -> DownloadInfo {
        guard ImageFiles.isDirectory(url) else { throw SpiderImportError.notADirectory }
        let spider = await Task.detached { Self.findSpiderInfo(in: url) }.value
        if let (dir, info) = spider {
            return try await importAndroidDownloadDirectory(dir, spiderInfo: info, label: label, move: move)
        }
        return try await importAlbum(url, label: label)
    }

    /// 导入整个下载根目录（如 Android 的 EhViewer/download）：每个含 `.ehviewer` 的子目录一个画廊。已存在的跳过
    public func importDownloadRoot(_ root: URL, label: String? = nil, move: Bool = false) async -> [Result<DownloadInfo, Error>] {
        let children = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .filter { ImageFiles.isDirectory($0) }
            .sorted { NaturalComparator.compare($0.lastPathComponent, $1.lastPathComponent) < 0 }
        var results: [Result<DownloadInfo, Error>] = []
        for dir in children {
            guard let info = SpiderInfo.read(contentsOf: dir.appendingPathComponent(SpiderNaming.spiderInfoFilename),
                                             includePTokens: true), info.gid >= 0, info.token != nil else { continue }
            do {
                results.append(.success(try await importAndroidDownloadDirectory(dir, spiderInfo: info, label: label, move: move)))
            } catch {
                results.append(.failure(error))
            }
        }
        return results
    }

    /// 在目录或其导入根中查找有效 `.ehviewer`
    nonisolated static func findSpiderInfo(in url: URL) -> (URL, SpiderInfo)? {
        var candidates = [url]
        if let root = ArchiveExtractor.resolveImportRoot(url), root != url { candidates.append(root) }
        for dir in candidates {
            let file = dir.appendingPathComponent(SpiderNaming.spiderInfoFilename)
            if let info = SpiderInfo.read(contentsOf: file), info.gid >= 0, let token = info.token, !token.isEmpty {
                return (dir, info)
            }
        }
        return nil
    }

    /// 由目录名推断标题："gid-标题" → "标题"
    nonisolated static func title(fromDirname name: String, gid: Int64) -> String {
        let prefix = SpiderNaming.downloadDirnamePrefix(gid: gid)
        if name.hasPrefix(prefix), name.count > prefix.count { return String(name.dropFirst(prefix.count)) }
        return name
    }

    private func importAndroidDownloadDirectory(_ source: URL, spiderInfo: SpiderInfo, label: String?,
                                                move: Bool) async throws -> DownloadInfo {
        let gid = spiderInfo.gid
        if infos[gid] != nil { throw SpiderImportError.alreadyImported }
        guard let root = location.root else { throw SpiderImportError.downloadLocationUnavailable }
        let token = spiderInfo.token ?? ""
        let sourceName = source.lastPathComponent
        let title = Self.title(fromDirname: sourceName, gid: gid)
        let dirname = sourceName.hasPrefix(SpiderNaming.downloadDirnamePrefix(gid: gid))
            ? SpiderNaming.sanitizeFilename(sourceName) : SpiderNaming.downloadDirname(gid: gid, title: title)
        let fallbackTime = now()

        let (dst, imageCount, timestamp): (URL, Int, Int64) = try await Task.detached {
            let fm = FileManager.default
            try? fm.createDirectory(at: root, withIntermediateDirectories: true)
            let dst = root.appendingPathComponent(dirname, isDirectory: true)
            if dst.standardizedFileURL.path != source.standardizedFileURL.path {
                if fm.fileExists(atPath: dst.path) {
                    throw SpiderImportError.copyFailed("目标目录已存在：\(dirname)")
                }
                do {
                    if move { try fm.moveItem(at: source, to: dst) } else { try fm.copyItem(at: source, to: dst) }
                } catch {
                    throw SpiderImportError.copyFailed(SpiderMessages.readable(error))
                }
            }
            let names = (try? fm.contentsOfDirectory(atPath: dst.path)) ?? []
            let indices = Set(names.compactMap { SpiderNaming.imageIndex(fromFilename: $0) })
            let ts = SpiderNaming.galleryDirectoryTimestamp(dst, fallbackTime: fallbackTime, fileManager: fm)
            return (dst, indices.filter { $0 < spiderInfo.pages }.count, ts)
        }.value

        try? database.putDownloadDirname(gid: gid, dirname: dirname)
        spiderInfoCache?.write(spiderInfo)
        let complete = imageCount >= spiderInfo.pages
        var info = DownloadInfo(gid: gid, token: token, title: title, category: EhCategory.unknown.rawValue,
                                state: complete ? DownloadInfo.stateFinish : DownloadInfo.stateNone,
                                legacy: max(spiderInfo.pages - imageCount, 0), time: timestamp, label: label)
        info.total = spiderInfo.pages
        info.finished = imageCount
        info.downloaded = imageCount
        _ = dst
        addDownload([info])
        return infos[gid] ?? info
    }

    // MARK: - 相册（对应 DownloadAlbumImporter.processAlbumFolder）

    private func importAlbum(_ source: URL, label: String?) async throws -> DownloadInfo {
        let archiveUri = Self.localAlbumURIPrefix + source.absoluteString
        if infos.values.contains(where: { $0.archiveUri == archiveUri }) { throw SpiderImportError.alreadyImported }
        guard location.root != nil else { throw SpiderImportError.downloadLocationUnavailable }

        let images: [URL] = await Task.detached {
            guard let root = ArchiveExtractor.resolveImportRoot(source) else { return [] }
            return ArchiveExtractor.collectImageFiles(root)
                .sorted { NaturalComparator.compare($0.lastPathComponent, $1.lastPathComponent) < 0 }
        }.value
        if images.isEmpty { throw SpiderImportError.noImages }

        let gid = uniqueLocalGid()
        var folderName = source.lastPathComponent
        if folderName.trimmingCharacters(in: .whitespaces).isEmpty { folderName = "imported_album_\(gid)" }
        var info = DownloadInfo(gid: gid, token: Self.localToken, title: folderName, thumb: Self.localThumb,
                                category: EhCategory.unknown.rawValue, uploader: Self.localAlbumUploader, rating: -1,
                                state: DownloadInfo.stateFinish, legacy: 0, time: gid, label: label,
                                archiveUri: archiveUri)
        guard let dir = location.galleryDownloadDir(for: info.galleryInfo) else {
            throw SpiderImportError.downloadLocationUnavailable
        }
        let spiderInfoCache = spiderInfoCache
        let copied: Int
        do {
            copied = try await Task.detached {
                let fm = FileManager.default
                do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) } catch {
                    throw SpiderImportError.downloadLocationUnavailable
                }
                let n = ArchiveExtractor.copyImages(images, to: dir)
                if n == 0 { throw SpiderImportError.copyFailed("没有图片被复制") }
                let si = SpiderInfo(startPage: 0, gid: gid, token: Self.localToken, pages: n, previewPages: 0, previewPerPage: 0)
                try? si.write(to: dir.appendingPathComponent(SpiderNaming.spiderInfoFilename))
                spiderInfoCache?.write(si)
                // 对应 copyThumb
                let thumb = dir.appendingPathComponent(Self.thumbFilename)
                try? fm.removeItem(at: thumb)
                try? fm.copyItem(at: images[0], to: thumb)
                return n
            }.value
        } catch {
            try? FileManager.default.removeItem(at: dir)
            try? database.removeDownloadDirname(gid: gid)
            throw error
        }
        info.total = copied
        info.finished = copied
        info.downloaded = copied
        addDownload([info])
        return infos[gid] ?? info
    }

    // MARK: - 归档下载完成（对应 ArchiverDownloadCompleter.importDownloadedZip）

    /// 解压归档 zip 到下载目录，写 `.ehviewer`，登记为已完成下载（标签 `label`，默认"档案"）。
    /// 与 Android 不同：已在下载列表中时把该项改为 FINISH（Android 保持原状态）。
    @discardableResult
    public func importDownloadedArchive(zip: URL, galleryInfo: GalleryInfo, tempDirectory: URL,
                                        label: String = DownloadManager.defaultArchiverLabel,
                                        deleteZip: Bool = true) async throws -> DownloadInfo {
        guard ImageFiles.isFile(zip) else { throw SpiderImportError.invalidArchive("文件不存在") }
        guard let dir = location.galleryDownloadDir(for: galleryInfo) else {
            throw SpiderImportError.downloadLocationUnavailable
        }
        let gid = galleryInfo.gid
        let token = galleryInfo.token
        let spiderInfoCache = spiderInfoCache
        let temp = tempDirectory.appendingPathComponent("archiver_\(gid)", isDirectory: true)
        let pages: Int = try await Task.detached {
            let fm = FileManager.default
            defer { try? fm.removeItem(at: temp) }
            try ArchiveExtractor.unzipArchive(zip, to: temp, fileManager: fm)
            guard let importRoot = ArchiveExtractor.resolveImportRoot(temp, fileManager: fm) else {
                throw SpiderImportError.noImages
            }
            let pictures = ArchiveExtractor.collectImageFiles(importRoot, fileManager: fm)
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            if pictures.isEmpty { throw SpiderImportError.noImages }
            do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) } catch {
                throw SpiderImportError.downloadLocationUnavailable
            }
            let n = ArchiveExtractor.copyImages(pictures, to: dir, move: true, fileManager: fm)
            if n == 0 { throw SpiderImportError.copyFailed("没有图片被复制") }
            let si = SpiderInfo(startPage: 0, gid: gid, token: token, pages: n)
            try? si.write(to: dir.appendingPathComponent(SpiderNaming.spiderInfoFilename))
            spiderInfoCache?.write(si)
            if deleteZip { try? fm.removeItem(at: zip) }
            return n
        }.value

        addLabel(label)
        if infos[gid] != nil {
            if currentGid == gid { stopCurrentDownload() }
            markFinished(gid, pages: pages)
        } else {
            addDownload(galleryInfo, label: label, state: DownloadInfo.stateFinish)
            markFinished(gid, pages: pages)
        }
        return infos[gid]!
    }
}
