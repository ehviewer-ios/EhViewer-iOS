import SwiftUI
import EhCore
import EhSpider

/// 打开阅读器的请求
struct ReaderRequest: Identifiable, Hashable {
    enum Source: Hashable {
        /// 在线画廊（若已下载会自动读取下载目录）
        case gallery(GalleryInfo)
        /// 本地目录（导入的文件夹）
        case directory(URL, title: String)
        /// zip 归档
        case archive(URL, title: String)
    }

    let id = UUID()
    var source: Source
    /// 起始页（从 0 开始）；nil 表示使用阅读进度
    var startPage: Int?
}

/// 跨功能操作入口。各功能通过 AppModel 调用，具体实现由对应模块接入
extension AppModel {
    /// 打开阅读器（由 RootView 以 fullScreenCover 展示）
    func openReader(_ request: ReaderRequest) {
        readerRequest = request
    }

    func openReader(_ info: GalleryInfo, page: Int? = nil) {
        openReader(ReaderRequest(source: .gallery(info), startPage: page))
    }

    /// 开始下载画廊。label 为 nil 时：若设置了默认标签则用它，否则用最近使用的标签
    func startDownload(_ info: GalleryInfo, label: String? = nil) {
        let resolved: String?
        if let label {
            resolved = label
        } else if settings.hasDefaultDownloadLabel {
            resolved = settings.defaultDownloadLabel
        } else {
            resolved = nil
        }
        downloads.startDownload(info, label: resolved)
        if let resolved { settings.recentDownloadLabel = resolved }
        Haptics.success()
        DownloadNotifier.shared.requestAuthorizationIfNeeded()
    }

    /// 画廊在下载列表中的状态（DownloadInfo.STATE_*）；nil 表示未下载
    func downloadState(gid: Int64) -> Int? {
        downloads.containDownloadInfo(gid) ? downloads.downloadState(gid) : nil
    }

    /// 下载归档 zip（获取下载链接后调用），完成后自动解压并登记为已下载
    func startArchiveDownload(_ info: GalleryInfo, url: String) {
        Task {
            DownloadNotifier.shared.requestAuthorizationIfNeeded()
            _ = await archiver.start(info, url: url)
            toast.show("开始下载归档：\(title(of: info))", systemImage: "archivebox")
        }
    }

    /// 从下载列表删除（可选删除文件）
    func deleteDownload(gid: Int64, deleteFiles: Bool = false) {
        downloads.deleteDownload(gid, deleteFiles: deleteFiles)
    }

    /// 阅读进度（起始页，从 0 开始）；与 GalleryLoader 一致：取下载目录 .ehviewer 与阅读缓存中较大者。无进度返回 nil
    func readProgress(gid: Int64) async -> Int? {
        let downloadDir = downloads.downloadDirectory(for: gid)
        let cacheDir = directories.spiderInfoCacheDir
        let page = await Task.detached { () -> Int in
            var best = 0
            if let downloadDir,
               let info = SpiderInfo.read(contentsOf: downloadDir.appendingPathComponent(SpiderNaming.spiderInfoFilename),
                                          includePTokens: false) {
                best = max(best, info.startPage)
            }
            if let cacheDir, let info = SpiderInfoCache(directory: cacheDir).read(gid: gid) {
                best = max(best, info.startPage)
            }
            return best
        }.value
        return page > 0 ? page : nil
    }
}
