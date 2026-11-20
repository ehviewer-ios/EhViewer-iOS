import Foundation
import EhStorage

/// 用 `EhDatabase` + 本地下载目录实现的 `TransferStore`。合并规则逐条对照 Android：
///
/// | 数据 | Android 调用 | 规则 |
/// |------|-------------|------|
/// | 快速搜索 | `EhDB.takeOverQuickSearchList` | keyword 已存在跳过，其余以当前时间插入 |
/// | 本地收藏 | `EhDB.putLocalFavorite` | gid 不存在才插入，time = 当前时间 |
/// | 下载标签 | `DownloadManager.addLabelInSyncThread` | 同名已存在跳过，否则以当前时间新建 |
/// | 下载项 | `DownloadManager.addDownloadInfo(info, label)` | gid 已存在跳过；只复制 GalleryInfo 基础列 + label，state = NONE，time = 当前时间 |
/// | 下载目录名 | `EhDB.putDownloadDirname` | 插入或更新 |
/// | 历史（iOS 扩展） | `EhDB.putHistoryInfo(List)` | gid 不存在才插入（保留 time），再裁剪 |
///
/// 与 Android 的差异：下载项的标签若不存在，Android 会丢弃该项（`getInfoListForLabel` 返回 null），
/// 这里改为先新建标签再插入（与 `importDB` 的处理一致）。
public struct EhDatabaseTransferStore: TransferStore {
    public let database: EhDatabase
    public let downloadRoot: URL?

    public init(database: EhDatabase, downloadRoot: URL?) {
        self.database = database
        self.downloadRoot = downloadRoot
    }

    // MARK: 读取

    public func quickSearches() throws -> [TransferQuickSearch] {
        try database.allQuickSearch().map {
            TransferQuickSearch(name: $0.name, mode: $0.mode, category: $0.category, keyword: $0.keyword,
                                advanceSearch: $0.advanceSearch, minRating: $0.minRating,
                                pageFrom: $0.pageFrom, pageTo: $0.pageTo, time: $0.time)
        }
    }

    public func localFavorites() throws -> [GalleryInfo] {
        try database.allLocalFavorites().map(\.galleryInfo)
    }

    public func downloadLabels() throws -> [String] {
        try database.allDownloadLabels().compactMap(\.label)
    }

    public func downloadItems() throws -> [TransferDownloadItem] {
        try database.allDownloadInfo().map {
            TransferDownloadItem(info: $0.galleryInfo, finished: $0.finished, legacy: $0.legacy, label: $0.label,
                                 downloaded: $0.downloaded, remaining: $0.remaining, speed: $0.speed,
                                 state: $0.state, time: $0.time, total: $0.total, archiveUri: nil)
        }
    }

    public func historyItems() throws -> [TransferHistoryItem] {
        try database.allHistory().map { TransferHistoryItem(info: $0.galleryInfo, mode: $0.mode, time: $0.time) }
    }

    // MARK: 写入

    public func takeOverQuickSearches(_ list: [TransferQuickSearch]) throws {
        try database.takeOverQuickSearchList(list.map {
            QuickSearch(name: $0.name, mode: $0.mode, category: $0.category, keyword: $0.keyword,
                        advanceSearch: $0.advanceSearch, minRating: $0.minRating, pageFrom: $0.pageFrom,
                        pageTo: $0.pageTo, time: $0.time)
        })
    }

    public func putLocalFavorites(_ list: [GalleryInfo]) throws {
        for info in list { try database.putLocalFavorite(info) }
    }

    public func addDownloadLabels(_ labels: [String]) throws {
        let existing = Set(try database.allDownloadLabels().compactMap(\.label))
        var seen = existing
        for label in labels where !seen.contains(label) {
            try database.addDownloadLabel(label)
            seen.insert(label)
        }
    }

    public func addDownloadItems(_ items: [TransferDownloadItem]) throws {
        var labels = Set(try database.allDownloadLabels().compactMap(\.label))
        for item in items {
            if try database.containDownloadInfo(gid: item.info.gid) { continue }
            if let label = item.label, !labels.contains(label) {
                try database.addDownloadLabel(label)
                labels.insert(label)
            }
            let info = DownloadInfo(item.info, state: DownloadInfo.stateNone,
                                    time: EhDatabase.currentTimeMillis(), label: item.label)
            try database.putDownloadInfo(info)
        }
    }

    public func putHistoryItems(_ items: [TransferHistoryItem]) throws {
        try database.putHistoryInfo(items.map { HistoryInfo($0.info, mode: $0.mode, time: $0.time) })
    }

    public func putDownloadDirname(gid: Int64, dirname: String) throws {
        try database.putDownloadDirname(gid: gid, dirname: dirname)
    }

    public func downloadDirname(gid: Int64) throws -> String? {
        try database.downloadDirname(gid: gid)
    }
}

/// WiFi 互传业务会话：协议引擎 + 数据库存储。由 `TransferServer` / `TransferClient` 驱动。
///
/// ```swift
/// let session = TransferSession(database: db, directories: .standard())
/// let server = TransferServer(session: session)
/// let info = try await server.start()        // 展示 info.qrString
/// for await e in server.events { … }        // .connected 后调用 server.send(.favorite)
/// ```
public final class TransferSession: Sendable {
    public let engine: TransferEngine
    public let store: any TransferStore

    public init(store: any TransferStore, pageSize: Int = TransferEngine.defaultPageSize) {
        self.store = store
        engine = TransferEngine(store: store, pageSize: pageSize)
    }

    /// - Parameter downloadRoot: 下载根目录（nil = 未设置，下载目录迁移不可用）
    public convenience init(database: EhDatabase, downloadRoot: URL?) {
        self.init(store: EhDatabaseTransferStore(database: database, downloadRoot: downloadRoot))
    }

    /// 下载根目录取 `AppDirectories.defaultDownloadDir`（Documents/download）
    public convenience init(database: EhDatabase, directories: AppDirectories) {
        self.init(database: database, downloadRoot: directories.defaultDownloadDir)
    }

    /// 发送一种数据（需已连接）
    @discardableResult
    public func send(_ kind: TransferDataKind) async throws -> TransferSendSummary {
        try await engine.send(kind)
    }

    /// 依次发送多种数据
    @discardableResult
    public func send(_ kinds: [TransferDataKind]) async throws -> [TransferDataKind: TransferSendSummary] {
        var result: [TransferDataKind: TransferSendSummary] = [:]
        for kind in kinds {
            result[kind] = try await engine.send(kind)
        }
        return result
    }

    /// 停止当前发送
    public func cancelSending() async {
        await engine.cancelSending()
    }
}
