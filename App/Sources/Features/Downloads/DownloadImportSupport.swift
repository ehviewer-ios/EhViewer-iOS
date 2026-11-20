import Foundation
import UniformTypeIdentifiers
import EhStorage
import EhSpider

/// 本地导入类型。对应 Android 菜单 import_local_archive / import_local_album + 数据迁移的下载目录导入
enum DownloadImportKind: String, Identifiable {
    /// zip / cbz 压缩包（可多选）
    case archive
    /// 图片文件夹，或含 `.ehviewer` 的 Android 下载目录中的单个画廊
    case folder
    /// 整个 Android 下载根目录（EhViewer/download）
    case downloadRoot

    var id: String { rawValue }

    var contentTypes: [UTType] {
        switch self {
        case .archive:
            return [.zip] + ["cbz"].compactMap { UTType(filenameExtension: $0) }
        case .folder, .downloadRoot:
            return [.folder]
        }
    }

    var allowsMultipleSelection: Bool { self != .downloadRoot }
}

/// 执行导入（访问安全作用域资源）。对应 `DownloadArchiveImporter` / `DownloadAlbumImporter`
@MainActor
enum DownloadImporter {
    struct Summary {
        var imported = 0
        var skipped = 0
        var failures: [String] = []

        var message: String {
            var parts: [String] = []
            if imported > 0 { parts.append("已导入 \(imported) 项") }
            if skipped > 0 { parts.append("\(skipped) 项已存在") }
            if !failures.isEmpty { parts.append("\(failures.count) 项失败") }
            if parts.isEmpty { return "没有可导入的内容" }
            var s = parts.joined(separator: "，")
            if let first = failures.first { s += "：\(first)" }
            return s
        }
    }

    static func run(_ kind: DownloadImportKind, urls: [URL], label: String?, model: AppModel) async -> Summary {
        var summary = Summary()
        let manager = model.downloads
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            switch kind {
            case .archive:
                do {
                    // 复制进 App（Documents/archive），之后阅读不再依赖外部文件权限
                    try await manager.importArchive(url, copyInto: DownloadDisplay.importedArchiveDirectory(model),
                                                    label: label)
                    summary.imported += 1
                } catch {
                    record(error, name: url.lastPathComponent, into: &summary)
                }
            case .folder:
                do {
                    try await manager.importFolder(url, label: label, move: false)
                    summary.imported += 1
                } catch {
                    record(error, name: url.lastPathComponent, into: &summary)
                }
            case .downloadRoot:
                let results = await manager.importDownloadRoot(url, label: label, move: false)
                for r in results {
                    switch r {
                    case .success: summary.imported += 1
                    case let .failure(error): record(error, name: nil, into: &summary)
                    }
                }
            }
        }
        return summary
    }

    private static func record(_ error: Error, name: String?, into summary: inout Summary) {
        if let e = error as? SpiderImportError, e == .alreadyImported {
            summary.skipped += 1
            return
        }
        let msg = error.localizedDescription
        summary.failures.append(name.map { "\($0)（\(msg)）" } ?? msg)
    }

    /// 删除下载项；deleteFiles 时一并删除导入时复制进 Documents/archive 的压缩包
    /// （`DownloadManager` 只删除位于下载根目录内的压缩包）
    static func delete(_ gids: [Int64], deleteFiles: Bool, model: AppModel) {
        var copies: [URL] = []
        if deleteFiles {
            let dir = DownloadDisplay.importedArchiveDirectory(model).standardizedFileURL.path
            for gid in gids {
                guard let info = model.downloads.downloadInfo(gid), DownloadManager.isLocalArchive(info),
                      let s = info.archiveUri, let u = URL(string: s), u.isFileURL,
                      u.standardizedFileURL.path.hasPrefix(dir + "/") else { continue }
                copies.append(u)
            }
        }
        if gids.count == 1, let gid = gids.first {
            model.deleteDownload(gid: gid, deleteFiles: deleteFiles)
        } else {
            model.downloads.deleteRangeDownload(gids, deleteFiles: deleteFiles)
        }
        for u in copies { try? FileManager.default.removeItem(at: u) }
    }
}
