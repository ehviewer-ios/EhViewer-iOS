import Foundation
import SwiftUI
import EhCore
import EhStorage
import EhSpider

/// 下载列表的标签筛选。对应 Android `DownloadsScene.mLabel`（null 为默认标签）+ "全部"
enum DownloadLabelFilter: Hashable {
    case all
    case defaultLabel
    case label(String)

    /// 持久化编码（@AppStorage）
    var storageValue: String {
        switch self {
        case .all: return ""
        case .defaultLabel: return "\u{1}default"
        case let .label(l): return l
        }
    }

    init(storageValue: String) {
        switch storageValue {
        case "": self = .all
        case "\u{1}default": self = .defaultLabel
        default: self = .label(storageValue)
        }
    }

    /// 导入 / 新建下载时使用的标签
    var labelValue: String? {
        if case let .label(l) = self { return l }
        return nil
    }

    func matches(_ info: DownloadInfo) -> Bool {
        switch self {
        case .all: return true
        case .defaultLabel: return info.label == nil
        case let .label(l): return info.label == l
        }
    }
}

/// 按状态筛选。对应 Android 菜单 download_done / not_started / waiting / downloading / failed / local_import
enum DownloadStateFilter: String, CaseIterable, Hashable {
    case all, finished, notStarted, waiting, downloading, failed, localImport

    var title: String {
        switch self {
        case .all: return "全部状态"
        case .finished: return "已完成"
        case .notStarted: return "未开始"
        case .waiting: return "等待中"
        case .downloading: return "下载中"
        case .failed: return "失败"
        case .localImport: return "本地导入"
        }
    }

    var systemImage: String {
        switch self {
        case .all: return "tray.full"
        case .finished: return "checkmark.circle"
        case .notStarted: return "pause.circle"
        case .waiting: return "clock"
        case .downloading: return "arrow.down.circle"
        case .failed: return "exclamationmark.circle"
        case .localImport: return "square.and.arrow.down"
        }
    }

    func matches(_ info: DownloadInfo) -> Bool {
        switch self {
        case .all: return true
        case .finished: return info.state == DownloadInfo.stateFinish
        case .notStarted: return info.state == DownloadInfo.stateNone
        case .waiting: return info.state == DownloadInfo.stateWait
        case .downloading: return info.state == DownloadInfo.stateDownload
        case .failed: return info.state == DownloadInfo.stateFailed
        case .localImport: return info.archiveUri != nil
        }
    }
}

/// 排序。对应 Android 菜单 sort_by_*
enum DownloadSortOrder: String, CaseIterable, Hashable {
    case `default`, timeDesc, timeAsc, gidDesc, gidAsc, ratingDesc, ratingAsc, nameAsc, nameDesc, sizeDesc, sizeAsc

    var title: String {
        switch self {
        case .default: return "默认"
        case .timeDesc: return "添加时间（新→旧）"
        case .timeAsc: return "添加时间（旧→新）"
        case .gidDesc: return "画廊 ID（大→小）"
        case .gidAsc: return "画廊 ID（小→大）"
        case .ratingDesc: return "评分（高→低）"
        case .ratingAsc: return "评分（低→高）"
        case .nameAsc: return "名称（A→Z）"
        case .nameDesc: return "名称（Z→A）"
        case .sizeDesc: return "文件大小（大→小）"
        case .sizeAsc: return "文件大小（小→大）"
        }
    }

    var needsFileSize: Bool { self == .sizeAsc || self == .sizeDesc }

    /// 稳定排序；文件大小未知的排在最后
    func sorted(_ list: [DownloadInfo], title: (DownloadInfo) -> String, size: (Int64) -> Int64?) -> [DownloadInfo] {
        func cmp(_ a: DownloadInfo, _ b: DownloadInfo) -> Bool? {
            switch self {
            case .default: return nil
            case .timeDesc: return a.time == b.time ? nil : a.time > b.time
            case .timeAsc: return a.time == b.time ? nil : a.time < b.time
            case .gidDesc: return a.gid == b.gid ? nil : a.gid > b.gid
            case .gidAsc: return a.gid == b.gid ? nil : a.gid < b.gid
            case .ratingDesc: return a.rating == b.rating ? nil : a.rating > b.rating
            case .ratingAsc: return a.rating == b.rating ? nil : a.rating < b.rating
            case .nameAsc, .nameDesc:
                let r = title(a).localizedStandardCompare(title(b))
                if r == .orderedSame { return nil }
                return self == .nameAsc ? r == .orderedAscending : r == .orderedDescending
            case .sizeAsc, .sizeDesc:
                let sa = size(a.gid), sb = size(b.gid)
                switch (sa, sb) {
                case (nil, nil): return nil
                case (nil, _): return false
                case (_, nil): return true
                case let (x?, y?):
                    if x == y { return nil }
                    return self == .sizeAsc ? x < y : x > y
                }
            }
        }
        guard self != .default else { return list }
        return list.enumerated().sorted { l, r in
            cmp(l.element, r.element) ?? (l.offset < r.offset)
        }.map(\.element)
    }
}

/// 下载项的显示辅助
@MainActor
enum DownloadDisplay {
    /// 导入的压缩包复制到的目录（Documents/archive，“文件” App 可见）
    static func importedArchiveDirectory(_ model: AppModel) -> URL {
        model.directories.documents.appendingPathComponent("archive", isDirectory: true)
    }

    /// 是否是本地导入（压缩包 / 相册）
    static func isLocal(_ info: DownloadInfo) -> Bool { info.archiveUri != nil }

    /// 用于 GalleryRow / GalleryGridCell 显示的 GalleryInfo：本地相册封面改为下载目录中的 `.thumb`，页数用总页数
    static func galleryInfo(for info: DownloadInfo, model: AppModel) -> GalleryInfo {
        var gi = info.galleryInfo
        if info.thumb == DownloadManager.localThumb {
            gi.thumb = model.downloads.downloadDirectory(for: info.gid)?
                .appendingPathComponent(DownloadManager.thumbFilename).absoluteString
        }
        if info.total > 0 { gi.pages = info.total }
        if info.rating < 0 { gi.rating = 0 }
        return gi
    }

    static func stateText(_ info: DownloadInfo) -> String {
        switch info.state {
        case DownloadInfo.stateNone: return "未开始"
        case DownloadInfo.stateWait: return "等待中"
        case DownloadInfo.stateDownload: return "下载中"
        case DownloadInfo.stateFinish: return DownloadDisplay.isLocal(info) ? "本地导入" : "已完成"
        case DownloadInfo.stateFailed:
            return info.legacy > 0 ? "失败（\(info.legacy) 页未完成）" : "失败"
        default: return ""
        }
    }

    static func stateColor(_ info: DownloadInfo) -> Color {
        switch info.state {
        case DownloadInfo.stateFinish: return .green
        case DownloadInfo.stateFailed: return .red
        case DownloadInfo.stateDownload: return .accentColor
        default: return .secondary
        }
    }

    /// 可以开始（右滑 / 批量开始）
    static func canStart(_ info: DownloadInfo) -> Bool {
        !isLocal(info) && (info.state == DownloadInfo.stateNone || info.state == DownloadInfo.stateFailed)
    }

    /// 可以暂停
    static func canStop(_ info: DownloadInfo) -> Bool {
        info.state == DownloadInfo.stateWait || info.state == DownloadInfo.stateDownload
    }

    static func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(bytes, 0), countStyle: .file)
    }

    static func speedText(_ bytesPerSecond: Int64) -> String {
        byteText(bytesPerSecond) + "/s"
    }

    /// 剩余时间（毫秒）→ 文本
    static func remainingText(_ ms: Int64) -> String? {
        guard ms > 0, ms < 100 * 24 * 3600 * 1000 else { return nil }
        let f = DateComponentsFormatter()
        f.allowedUnits = ms >= 3600_000 ? [.hour, .minute] : [.minute, .second]
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 2
        return f.string(from: TimeInterval(ms) / 1000).map { "剩余 \($0)" }
    }
}

/// 已完成下载的文件大小（后台计算并缓存）。对应 Android `DownloadListInfosExecutor.calculateDownloadDirSize`
@MainActor @Observable
final class DownloadSizeCache {
    private(set) var sizes: [Int64: Int64] = [:]
    @ObservationIgnored private var pending: Set<Int64> = []

    func size(_ gid: Int64) -> Int64? { sizes[gid] }

    func request(_ info: DownloadInfo, model: AppModel) {
        let gid = info.gid
        guard sizes[gid] == nil, !pending.contains(gid) else { return }
        pending.insert(gid)
        var target: URL?
        if DownloadManager.isLocalArchive(info), let s = info.archiveUri, let u = URL(string: s), u.isFileURL {
            target = u
        } else {
            target = model.downloads.downloadDirectory(for: gid)
        }
        guard let target else {
            pending.remove(gid)
            return
        }
        Task {
            let size = await Task.detached(priority: .utility) { Self.computeSize(target) }.value
            pending.remove(gid)
            sizes[gid] = size
        }
    }

    func invalidate(_ gid: Int64) {
        sizes.removeValue(forKey: gid)
    }

    nonisolated static func computeSize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        var total: Int64 = 0
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        if let e = fm.enumerator(at: url, includingPropertiesForKeys: keys) {
            for case let f as URL in e {
                guard let v = try? f.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
                total += Int64(v.fileSize ?? 0)
            }
        }
        return total
    }
}
