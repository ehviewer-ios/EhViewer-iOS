import Foundation
import GRDB

/// 数据库导入 / 导出。对应 Android `EhDB.exportDB / importDB`（以及 `DownloadManager.addDownload(List)` /
/// `addDownloadLabel(List)` 中被导入流程调用的合并逻辑）。
extension EhDatabase {
    /// 导入结果统计
    public struct ImportSummary: Sendable, Hashable {
        public var downloadLabels = 0
        public var downloads = 0
        public var downloadDirnames = 0
        public var history = 0
        public var quickSearches = 0
        public var localFavorites = 0
        public var bookmarks = 0
        public var filters = 0
        public var blackList = 0
        public var galleryTags = 0
    }

    /// 导出到一个 Android 兼容的 .db 文件。对应 `exportDB`。
    ///
    /// 与 Android 相同：新建完整 schema（user_version = 8），复制 DOWNLOADS、DOWNLOAD_LABELS、DOWNLOAD_DIRNAME、
    /// HISTORY、QUICK_SEARCH、LOCAL_FAVORITES、BOOKMARKS、FILTER 八张表（主键保持不变）。
    /// Android 不导出 Black_List / Gallery_Tags；`includeBlackListAndTags = true` 时额外导出这两张表。
    public func exportDatabase(to url: URL, includeBlackListAndTags: Bool = false) throws {
        let fm = FileManager.default
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".eh.export.\(UUID().uuidString).db")
        defer {
            for suffix in ["", "-journal", "-wal", "-shm"] {
                try? fm.removeItem(atPath: tmp.path + suffix)
            }
        }
        do {
            let export = try DatabaseQueue(path: tmp.path)
            let snapshot = try dbQueue.read { db in try Snapshot(db, includeBlackListAndTags: includeBlackListAndTags) }
            try export.write { db in
                try EhDatabaseSchema.createAllTables(db, ifNotExists: false)
                // Android SQLiteOpenHelper 建出的库都带 android_metadata，保持文件结构一致
                try db.execute(sql: "CREATE TABLE IF NOT EXISTS android_metadata (locale TEXT)")
                try db.execute(sql: "INSERT INTO android_metadata VALUES ('en_US')")
                try EhDatabaseSchema.setUserVersion(db, EhDatabaseSchema.version)
                try snapshot.insertAll(db)
            }
            try export.close()
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
            try fm.moveItem(at: tmp, to: url)
        } catch let e as EhStorageError {
            throw e
        } catch {
            try? fm.removeItem(at: url)
            throw EhStorageError.exportFailed(String(describing: error))
        }
    }

    /// 从另一个 .db（Android 导出或 iOS 导出）合并数据。对应 `importDB`。
    ///
    /// 源文件先复制到临时目录再按需升级（Android 会直接原地升级源文件）。合并规则与 Android 一致：
    /// - 下载标签：同名已存在则跳过，否则插入（保留 time）
    /// - 下载项：gid 已存在跳过；WAIT/DOWNLOAD 状态改为 NONE；所用标签不存在时以当前时间新建
    /// - 下载目录名：全部覆盖写入
    /// - 历史：不存在才插入（保留 time），之后裁剪到 `maxHistoryCount`
    /// - 快速搜索：已有同名（name）则跳过；插入时 time 为 0 才取当前时间
    /// - 本地收藏：不存在才插入（保留 time）
    /// - 过滤器：已有相同 mode + text 则跳过
    /// - 黑名单 / GalleryTags：见下方差异说明
    ///
    /// 与 Android 的差异：
    /// - 书签：Android 为 TODO 未导入；这里按 gid 不存在才插入。
    /// - 黑名单：Android 因 BlackList 未实现 equals 会重复插入；这里按 badgayname 去重。
    /// - GalleryTags：Android 遇到已存在的 gid 会主键冲突导致整个导入报错；这里跳过已存在的 gid。
    /// - 全部写入在一个事务中完成，失败时不留下部分数据。
    ///
    /// - Parameter progress: 进度回调（10 / 50 / 90 / 100），对应 Android `sendImportProgress`
    @discardableResult
    public func importDatabase(from url: URL, progress: (@Sendable (Int) -> Void)? = nil) throws -> ImportSummary {
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory.appendingPathComponent("eh-import-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tmpDir) }
        let snapshot: Snapshot
        do {
            try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
            let copy = tmpDir.appendingPathComponent("import.db")
            try fm.copyItem(at: url, to: copy)
            var config = Configuration()
            config.readonly = false
            let source = try DatabaseQueue(path: copy.path, configuration: config)
            defer { try? source.close() }
            try source.write { db in
                let v = try EhDatabaseSchema.userVersion(db)
                if v > EhDatabaseSchema.version {
                    throw EhStorageError.unsupportedVersion(v)
                }
                if v > 0, v < EhDatabaseSchema.version {
                    try EhDatabaseSchema.upgrade(db, from: v)
                    try EhDatabaseSchema.setUserVersion(db, EhDatabaseSchema.version)
                }
                // 只读取存在的表；缺列 / 缺表补齐后读出为空
                try EhDatabaseSchema.ensureLatestColumns(db)
            }
            snapshot = try source.read { db in try Snapshot(db, includeBlackListAndTags: true) }
        } catch let e as EhStorageError {
            throw e
        } catch {
            throw EhStorageError.cantReadFile(String(describing: error))
        }
        progress?(10)
        let time = now()
        let maxHistory = maxHistoryCount
        let summary = try dbQueue.write { db -> ImportSummary in
            var s = ImportSummary()

            // Download label（DownloadManager.addDownloadLabel(List)）
            var labels = Set(try DownloadLabel.fetchAll(db).compactMap(\.label))
            for raw in snapshot.downloadLabels {
                guard let name = raw.label, !labels.contains(name) else { continue }
                var l = raw
                l.id = nil
                try l.insert(db)
                labels.insert(name)
                s.downloadLabels += 1
            }

            // Downloads（DownloadManager.addDownload(List)）
            for item in snapshot.downloads {
                if try DownloadInfo.exists(db, key: item.gid) { continue }
                var info = item
                if info.state == DownloadInfo.stateWait || info.state == DownloadInfo.stateDownload {
                    info.state = DownloadInfo.stateNone
                }
                if let label = info.label, !labels.contains(label) {
                    _ = try Self.addDownloadLabel(db, label, time: time)
                    labels.insert(label)
                    s.downloadLabels += 1
                }
                try info.insert(db)
                s.downloads += 1
            }
            progress?(50)

            // Download dirname
            for d in snapshot.downloadDirnames {
                try d.save(db)
                s.downloadDirnames += 1
            }
            progress?(90)

            // History
            let historyBefore = try HistoryInfo.fetchCount(db)
            try Self.putHistoryInfo(db, snapshot.history, max: maxHistory)
            s.history = max(try HistoryInfo.fetchCount(db) - historyBefore, 0)

            // QuickSearch：与导入前已有的名字比较
            let currentNames = try QuickSearch.fetchAll(db).map(\.name)
            for q in snapshot.quickSearches where !currentNames.contains(where: { $0 == q.name }) {
                _ = try Self.insertQuickSearch(db, q, now: time)
                s.quickSearches += 1
            }

            // LocalFavorites
            for f in snapshot.localFavorites where try !LocalFavoriteInfo.exists(db, key: f.gid) {
                try f.insert(db)
                s.localFavorites += 1
            }

            // Bookmarks（Android: TODO）
            for b in snapshot.bookmarks where try !BookmarkInfo.exists(db, key: b.gid) {
                try b.insert(db)
                s.bookmarks += 1
            }

            // Filter：与导入前已有的规则比较（mode + text）
            let currentFilters = try Filter.fetchAll(db)
            for f in snapshot.filters where !currentFilters.contains(where: { $0.isSameRule(f) }) {
                var nf = f
                nf.id = nil
                try nf.insert(db)
                s.filters += 1
            }

            // BlackList
            var names = Set(try BlackList.fetchAll(db).compactMap(\.badgayname))
            for b in snapshot.blackList {
                guard let name = b.badgayname, !names.contains(name) else { continue }
                var nb = b
                nb.id = nil
                try nb.insert(db)
                names.insert(name)
                s.blackList += 1
            }

            // GalleryTags：create_time = update_time = 现在（与 insertGalleryTags 一致）
            let date = Date(timeIntervalSince1970: Double(time) / 1000)
            for t in snapshot.galleryTags where try !GalleryTags.exists(db, key: t.gid) {
                var nt = t
                nt.create_time = date
                nt.update_time = date
                try nt.insert(db)
                s.galleryTags += 1
            }
            return s
        }
        progress?(100)
        return summary
    }
}

/// 一次性读出某个库的全部数据
struct Snapshot {
    var downloadLabels: [DownloadLabel] = []
    var downloads: [DownloadInfo] = []
    var downloadDirnames: [DownloadDirname] = []
    var history: [HistoryInfo] = []
    var quickSearches: [QuickSearch] = []
    var localFavorites: [LocalFavoriteInfo] = []
    var bookmarks: [BookmarkInfo] = []
    var filters: [Filter] = []
    var blackList: [BlackList] = []
    var galleryTags: [GalleryTags] = []

    init(_ db: Database, includeBlackListAndTags: Bool) throws {
        downloads = try DownloadInfo.fetchAll(db)
        downloadLabels = try DownloadLabel.fetchAll(db)
        downloadDirnames = try DownloadDirname.fetchAll(db)
        history = try HistoryInfo.fetchAll(db)
        quickSearches = try QuickSearch.fetchAll(db)
        localFavorites = try LocalFavoriteInfo.fetchAll(db)
        bookmarks = try BookmarkInfo.fetchAll(db)
        filters = try Filter.fetchAll(db)
        if includeBlackListAndTags {
            blackList = try BlackList.fetchAll(db)
            galleryTags = try GalleryTags.fetchAll(db)
        }
    }

    /// 原样插入（保留主键），用于导出
    func insertAll(_ db: Database) throws {
        for r in downloads { try r.insert(db) }
        for var r in downloadLabels { try r.insert(db) }
        for r in downloadDirnames { try r.insert(db) }
        for r in history { try r.insert(db) }
        for var r in quickSearches { try r.insert(db) }
        for r in localFavorites { try r.insert(db) }
        for r in bookmarks { try r.insert(db) }
        for var r in filters { try r.insert(db) }
        for var r in blackList { try r.insert(db) }
        for r in galleryTags { try r.insert(db) }
    }
}
