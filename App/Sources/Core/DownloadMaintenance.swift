import Foundation
import EhCore
import EhSpider

/// 下载目录维护操作。对应 Android `RestoreDownloadPreference`、`CleanRedundancyPreference`、
/// `DownloadFragment.CleanInvalidDownloadTask`
extension AppModel {
    private var downloadRoot: URL? { directories.defaultDownloadDir }

    private func subdirectories(of root: URL) -> [URL] {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    /// 恢复下载项：扫描下载目录中不在列表里的画廊目录（.ehviewer 或 ComicInfo.xml 中有 gid/token），
    /// 通过 API 补全信息后加入下载列表。返回恢复数量；nil 表示下载目录不可用
    func restoreDownloadItems() async -> Int? {
        guard let root = downloadRoot else { return nil }
        let known = Set(downloads.order)
        let candidates: [(gid: Int64, token: String, dirname: String)] = await Task.detached { [self] in
            var result: [(Int64, String, String)] = []
            for dir in await subdirectories(of: root) {
                var gid: Int64 = -1
                var token: String?
                let siURL = dir.appendingPathComponent(SpiderNaming.spiderInfoFilename)
                if let data = try? Data(contentsOf: siURL), let si = SpiderInfo.readHeader(data),
                   si.gid >= 0, let t = si.token, !t.isEmpty {
                    gid = si.gid
                    token = t
                }
                if gid < 0 || token == nil {
                    let comic = dir.appendingPathComponent("ComicInfo.xml")
                    if let data = try? Data(contentsOf: comic), let r = ComicInfoParser.parse(data: data),
                       r.gid >= 0, !r.token.isEmpty {
                        gid = r.gid
                        token = r.token
                    }
                }
                guard gid >= 0, let token, !known.contains(gid) else { continue }
                result.append((gid, token, dir.lastPathComponent))
            }
            return result
        }.value
        guard !candidates.isEmpty else { return 0 }

        let placeholders = candidates.map { GalleryInfo(gid: $0.gid, token: $0.token) }
        let filled = await api.fillGalleryListByApiBestEffort(placeholders, referer: site.referer)
        let byGid = Dictionary(filled.map { ($0.gid, $0) }, uniquingKeysWith: { a, _ in a })
        var count = 0
        for c in candidates {
            var info = byGid[c.gid] ?? GalleryInfo(gid: c.gid, token: c.token)
            if info.title?.isEmpty ?? true { info.title = c.dirname.isEmpty ? String(c.gid) : c.dirname }
            downloads.addDownload(info, label: nil)
            try? database.putDownloadDirname(gid: c.gid, dirname: c.dirname)
            count += 1
        }
        return count
    }

    /// 清理冗余：删除下载目录中以 "gid-" 命名、但不在下载列表里的目录。返回删除数量
    func cleanRedundantDownloads() async -> Int {
        guard let root = downloadRoot else { return 0 }
        let known = Set(downloads.order)
        return await Task.detached {
            let fm = FileManager.default
            var count = 0
            let items = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            for item in items {
                var name = item.lastPathComponent
                if let dash = name.firstIndex(of: "-") { name = String(name[..<dash]) }
                guard let gid = Int64(name), !known.contains(gid) else { continue }
                if (try? fm.removeItem(at: item)) != nil { count += 1 }
            }
            return count
        }.value
    }

    /// 清理无效下载：删除空目录；.ehviewer 缺失/无效、或图片数与页数不符的目录记为无效，
    /// 页数不符时删除其中图片并把下载项重置为未下载（与 Android 一致）。返回无效数量与日志
    func cleanInvalidDownloads() async -> (count: Int, logs: [String]) {
        guard let root = downloadRoot else { return (0, []) }
        let result: (Int, [String], [Int64]) = await Task.detached {
            let fm = FileManager.default
            var invalid = 0
            var logs: [String] = []
            var resetGids: [Int64] = []
            let items = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for dir in items where (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                let name = dir.lastPathComponent
                let sub = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
                if sub.isEmpty {
                    logs.append("空目录：\(name)")
                    invalid += 1
                    try? fm.removeItem(at: dir)
                    continue
                }
                let siURL = dir.appendingPathComponent(SpiderNaming.spiderInfoFilename)
                guard fm.fileExists(atPath: siURL.path) else {
                    logs.append("缺少 .ehviewer：\(name)")
                    invalid += 1
                    continue
                }
                guard let si = SpiderInfo.read(contentsOf: siURL, includePTokens: false), si.pages > 0 else {
                    logs.append("无效的 .ehviewer：\(name)")
                    invalid += 1
                    if let gid = Int64(name.split(separator: "-").first ?? "") { resetGids.append(gid) }
                    continue
                }
                let images = sub.filter { !$0.lastPathComponent.hasPrefix(".") }
                if images.count != si.pages {
                    logs.append("文件数不一致：\(name)，应为 \(si.pages)，实际 \(images.count)")
                    invalid += 1
                    for f in images where f.lastPathComponent != SpiderNaming.spiderInfoFilename {
                        try? fm.removeItem(at: f)
                    }
                    resetGids.append(si.gid)
                }
            }
            return (invalid, logs, resetGids)
        }.value
        for gid in result.2 {
            if var info = downloads.downloadInfo(gid) {
                downloads.stopDownload(gid)
                info.state = DownloadInfo.stateNone
                try? database.putDownloadInfo(info)
            }
        }
        if !result.2.isEmpty { downloads.reloadFromDatabase() }
        return (result.0, result.1)
    }
}
