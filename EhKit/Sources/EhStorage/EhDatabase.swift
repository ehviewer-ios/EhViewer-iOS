import Foundation
import GRDB

/// 应用数据库。对应 Android `EhDB.java`（greenDAO），方法与 EhDB 一一对应。
///
/// - 底层为 GRDB `DatabaseQueue`（串行，线程安全）；所有方法同步执行，可在任意线程调用。
/// - 文件格式与 Android `eh.db` 完全一致（表名、列名、`user_version = 8`）。
/// - `observeXxx()` 返回 GRDB `AsyncValueObservation`，可直接 `for try await` 供 SwiftUI 订阅。
public final class EhDatabase: @unchecked Sendable {
    /// Android 默认数据库文件名
    public static let defaultFilename = "eh.db"
    /// 对应 `DaoMaster.SCHEMA_VERSION`
    public static var schemaVersion: Int { EhDatabaseSchema.version }

    let dbQueue: DatabaseQueue
    private let lock = NSLock()
    private var _maxHistoryCount = 100
    /// 当前时间（毫秒），可注入以便测试
    let now: @Sendable () -> Int64

    /// 可供 GRDB 生态（GRDBQuery 等）直接使用的 reader / writer
    public var writer: any DatabaseWriter { dbQueue }
    public var reader: any DatabaseReader { dbQueue }

    /// 对应 `EhDB.MAX_HISTORY_COUNT`（初始化后应设为 `EhSettings.historyInfoSize`）
    public var maxHistoryCount: Int {
        get { lock.withLock { _maxHistoryCount } }
        set { lock.withLock { _maxHistoryCount = newValue } }
    }

    /// 打开（或创建）数据库文件。版本较旧时自动升级（`upgradeDB`），版本更新时抛 `unsupportedVersion`。
    public convenience init(path: String, now: @escaping @Sendable () -> Int64 = EhDatabase.currentTimeMillis) throws {
        try self.init(queue: DatabaseQueue(path: path), now: now)
    }

    public convenience init(url: URL, now: @escaping @Sendable () -> Int64 = EhDatabase.currentTimeMillis) throws {
        try self.init(path: url.path, now: now)
    }

    /// 内存数据库（测试用）
    public static func inMemory(now: @escaping @Sendable () -> Int64 = EhDatabase.currentTimeMillis) throws -> EhDatabase {
        try EhDatabase(queue: DatabaseQueue(), now: now)
    }

    init(queue: DatabaseQueue, now: @escaping @Sendable () -> Int64) throws {
        dbQueue = queue
        self.now = now
        try dbQueue.write { db in try EhDatabaseSchema.prepare(db) }
    }

    @Sendable public static func currentTimeMillis() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000).rounded(.down))
    }

    /// 关闭数据库连接
    public func close() throws {
        try dbQueue.close()
    }

    // MARK: - Downloads（DOWNLOADS）

    /// 对应 `getAllDownloadInfo`：按 TIME 降序；WAIT / DOWNLOAD 状态修正为 NONE（仅内存）
    public func allDownloadInfo() throws -> [DownloadInfo] {
        var list = try dbQueue.read { db in
            try DownloadInfo.order(Column(Col.time).desc).fetchAll(db)
        }
        for i in list.indices where list[i].state == DownloadInfo.stateWait || list[i].state == DownloadInfo.stateDownload {
            list[i].state = DownloadInfo.stateNone
        }
        return list
    }

    public func downloadInfo(gid: Int64) throws -> DownloadInfo? {
        try dbQueue.read { db in try DownloadInfo.fetchOne(db, key: gid) }
    }

    public func containDownloadInfo(gid: Int64) throws -> Bool {
        try dbQueue.read { db in try DownloadInfo.exists(db, key: gid) }
    }

    /// 对应 `moveDownloadInfo`：在 [from, to] 区间内轮换 TIME 以调整顺序（数组本身不重排，仅更新 time），并写库
    public func moveDownloadInfo(_ infos: inout [DownloadInfo], from fromPosition: Int, to toPosition: Int) throws {
        if fromPosition == toPosition { return }
        let range = Self.rotationRange(from: fromPosition, to: toPosition)
        var times = infos[range].map(\.time)
        Self.rotateTimes(&times, reverse: fromPosition > toPosition)
        for (i, t) in zip(range, times) { infos[i].time = t }
        let changed = Array(infos[range])
        try dbQueue.write { db in
            for info in changed { try info.update(db) }
        }
    }

    /// 对应 `putDownloadInfo`：存在则更新，否则插入
    public func putDownloadInfo(_ info: DownloadInfo) throws {
        try dbQueue.write { db in try info.save(db) }
    }

    public func removeDownloadInfo(gid: Int64) throws {
        _ = try dbQueue.write { db in try DownloadInfo.deleteOne(db, key: gid) }
    }

    // MARK: - Download dirname（DOWNLOAD_DIRNAME）

    public func downloadDirname(gid: Int64) throws -> String? {
        try dbQueue.read { db in try DownloadDirname.fetchOne(db, key: gid)?.dirname }
    }

    /// 插入或更新
    public func putDownloadDirname(gid: Int64, dirname: String?) throws {
        try dbQueue.write { db in try DownloadDirname(gid: gid, dirname: dirname).save(db) }
    }

    public func removeDownloadDirname(gid: Int64) throws {
        _ = try dbQueue.write { db in try DownloadDirname.deleteOne(db, key: gid) }
    }

    /// 对应 `updateDownloadDirname(removeGid, newGid, dirname)`
    public func updateDownloadDirname(removeGid: Int64, newGid: Int64, dirname: String?) throws {
        try dbQueue.write { db in
            _ = try DownloadDirname.deleteOne(db, key: removeGid)
            try DownloadDirname(gid: newGid, dirname: dirname).save(db)
        }
    }

    public func clearDownloadDirname() throws {
        _ = try dbQueue.write { db in try DownloadDirname.deleteAll(db) }
    }

    public func allDownloadDirnames() throws -> [DownloadDirname] {
        try dbQueue.read { db in try DownloadDirname.fetchAll(db) }
    }

    // MARK: - Download labels（DOWNLOAD_LABELS）

    /// 对应 `getAllDownloadLabelList`：按 TIME 升序
    public func allDownloadLabels() throws -> [DownloadLabel] {
        try dbQueue.read { db in try DownloadLabel.order(Column(Col.time).asc).fetchAll(db) }
    }

    /// 对应 `addDownloadLabel(String)`：已存在同名标签则返回它，否则以当前时间新建
    @discardableResult
    public func addDownloadLabel(_ label: String) throws -> DownloadLabel {
        try dbQueue.write { db in try Self.addDownloadLabel(db, label, time: now()) }
    }

    static func addDownloadLabel(_ db: Database, _ label: String, time: Int64) throws -> DownloadLabel {
        if let existing = try DownloadLabel.filter(Column(Col.label) == label).fetchOne(db) {
            return existing
        }
        var raw = DownloadLabel(label: label, time: time)
        try raw.insert(db)
        return raw
    }

    /// 对应 `addDownloadLabel(DownloadLabel)`：重置 id 后插入（保留 time）
    @discardableResult
    public func addDownloadLabel(_ raw: DownloadLabel) throws -> DownloadLabel {
        var raw = raw
        raw.id = nil
        try dbQueue.write { db in try raw.insert(db) }
        return raw
    }

    public func updateDownloadLabel(_ raw: DownloadLabel) throws {
        try dbQueue.write { db in try raw.update(db) }
    }

    /// 对应 `moveDownloadLabel`：按 TIME 升序取区间，轮换 TIME
    public func moveDownloadLabel(from fromPosition: Int, to toPosition: Int) throws {
        if fromPosition == toPosition { return }
        try dbQueue.write { db in
            let range = Self.rotationRange(from: fromPosition, to: toPosition)
            var list = try DownloadLabel.order(Column(Col.time).asc)
                .limit(range.count, offset: range.lowerBound).fetchAll(db)
            guard list.count == range.count else { return }
            var times = list.map(\.time)
            Self.rotateTimes(&times, reverse: fromPosition > toPosition)
            for i in list.indices {
                list[i].time = times[i]
                try list[i].update(db)
            }
        }
    }

    public func removeDownloadLabel(_ raw: DownloadLabel) throws {
        _ = try dbQueue.write { db in try raw.delete(db) }
    }

    // MARK: - Local favorites（LOCAL_FAVORITES）

    /// 对应 `getAllLocalFavorites`：按 TIME 降序
    public func allLocalFavorites() throws -> [LocalFavoriteInfo] {
        try dbQueue.read { db in try LocalFavoriteInfo.order(Column(Col.time).desc).fetchAll(db) }
    }

    /// 对应 `searchLocalFavorites(String)`：TITLE LIKE '%query%'，按 TIME 降序
    public func searchLocalFavorites(_ query: String) throws -> [LocalFavoriteInfo] {
        try dbQueue.read { db in
            try LocalFavoriteInfo
                .filter(Column(Col.title).like("%\(query)%"))
                .order(Column(Col.time).desc)
                .fetchAll(db)
        }
    }

    /// 对应 `searchLocalFavorites(long)`（Android 不存在时会崩溃，这里返回 nil）
    public func searchLocalFavorites(gid: Int64) throws -> LocalFavoriteInfo? {
        try dbQueue.read { db in try LocalFavoriteInfo.fetchOne(db, key: gid) }
    }

    public func removeLocalFavorites(gid: Int64) throws {
        _ = try dbQueue.write { db in try LocalFavoriteInfo.deleteOne(db, key: gid) }
    }

    public func removeLocalFavorites(gids: [Int64]) throws {
        _ = try dbQueue.write { db in try LocalFavoriteInfo.deleteAll(db, keys: gids) }
    }

    public func containLocalFavorites(gid: Int64) throws -> Bool {
        try dbQueue.read { db in try LocalFavoriteInfo.exists(db, key: gid) }
    }

    /// 对应 `putLocalFavorite(GalleryInfo)`：不存在时以当前时间插入；已存在则不变
    public func putLocalFavorite(_ info: GalleryInfo) throws {
        let time = now()
        try dbQueue.write { db in
            if try !LocalFavoriteInfo.exists(db, key: info.gid) {
                try LocalFavoriteInfo(info, time: time).insert(db)
            }
        }
    }

    /// 对应 `putLocalFavorite(LocalFavoriteInfo)`：保留原 time
    public func putLocalFavorite(_ info: LocalFavoriteInfo) throws {
        try dbQueue.write { db in try Self.insertIfAbsent(db, info) }
    }

    public func putLocalFavorites(_ list: [GalleryInfo]) throws {
        let time = now()
        try dbQueue.write { db in
            for info in list {
                try Self.insertIfAbsent(db, LocalFavoriteInfo(info, time: time))
            }
        }
    }

    // MARK: - Bookmarks（BOOKMARKS）
    // Android EhDB 中没有书签的业务方法（只在导出时复制），这里补充基本读写。

    public func allBookmarks() throws -> [BookmarkInfo] {
        try dbQueue.read { db in try BookmarkInfo.order(Column(Col.time).desc).fetchAll(db) }
    }

    public func bookmark(gid: Int64) throws -> BookmarkInfo? {
        try dbQueue.read { db in try BookmarkInfo.fetchOne(db, key: gid) }
    }

    public func putBookmark(_ info: BookmarkInfo) throws {
        try dbQueue.write { db in try info.save(db) }
    }

    public func removeBookmark(gid: Int64) throws {
        _ = try dbQueue.write { db in try BookmarkInfo.deleteOne(db, key: gid) }
    }

    // MARK: - Black list（Black_List）

    /// 对应 `getAllBlackList`：按 ADD_TIME 升序
    public func allBlackList() throws -> [BlackList] {
        try dbQueue.read { db in try BlackList.order(Column("ADD_TIME").asc).fetchAll(db) }
    }

    /// 对应 `inBlackList`（Android 拼接 SQL，这里用参数绑定）
    public func inBlackList(_ badgayname: String) throws -> Bool {
        try dbQueue.read { db in
            try BlackList.filter(Column("BADGAYNAME") == badgayname).fetchCount(db) > 0
        }
    }

    /// 对应 `insertBlackList`：重置 id；badgayname 为空时忽略。返回插入后的记录
    @discardableResult
    public func insertBlackList(_ blackList: BlackList) throws -> BlackList? {
        var b = blackList
        b.id = nil
        guard b.badgayname != nil else { return nil }
        try dbQueue.write { db in try b.insert(db) }
        return b
    }

    public func updateBlackList(_ blackList: BlackList) throws {
        try dbQueue.write { db in try blackList.update(db) }
    }

    public func deleteBlackList(_ blackList: BlackList) throws {
        _ = try dbQueue.write { db in try blackList.delete(db) }
    }

    // MARK: - Gallery tags（Gallery_Tags）

    /// 对应 `getAllGalleryTags`：按 GID 升序
    public func allGalleryTags() throws -> [GalleryTags] {
        try dbQueue.read { db in try GalleryTags.order(Column(Col.gid).asc).fetchAll(db) }
    }

    public func inGalleryTags(gid: Int64) throws -> Bool {
        try dbQueue.read { db in try GalleryTags.exists(db, key: gid) }
    }

    public func queryGalleryTags(gid: Int64) throws -> GalleryTags? {
        try dbQueue.read { db in try GalleryTags.fetchOne(db, key: gid) }
    }

    /// 对应 `insertGalleryTags`：create_time = update_time = 现在。返回写入后的记录
    @discardableResult
    public func insertGalleryTags(_ tags: GalleryTags) throws -> GalleryTags {
        var t = tags
        let date = Date(timeIntervalSince1970: Double(now()) / 1000)
        t.create_time = date
        t.update_time = date
        try dbQueue.write { db in try t.insert(db) }
        return t
    }

    /// 对应 `updateGalleryTags`：update_time = 现在
    @discardableResult
    public func updateGalleryTags(_ tags: GalleryTags) throws -> GalleryTags {
        var t = tags
        t.update_time = Date(timeIntervalSince1970: Double(now()) / 1000)
        try dbQueue.write { db in try t.update(db) }
        return t
    }

    public func deleteGalleryTags(_ tags: GalleryTags) throws {
        _ = try dbQueue.write { db in try tags.delete(db) }
    }

    // MARK: - Quick search（QUICK_SEARCH）

    /// 对应 `getAllQuickSearch`：按 TIME 升序
    public func allQuickSearch() throws -> [QuickSearch] {
        try dbQueue.read { db in try QuickSearch.order(Column(Col.time).asc).fetchAll(db) }
    }

    /// 对应 `insertQuickSearch`：重置 id；time 为 0 时取当前时间。返回带 id 的记录
    @discardableResult
    public func insertQuickSearch(_ quickSearch: QuickSearch) throws -> QuickSearch {
        let time = now()
        return try dbQueue.write { db in try Self.insertQuickSearch(db, quickSearch, now: time) }
    }

    static func insertQuickSearch(_ db: Database, _ quickSearch: QuickSearch, now: Int64) throws -> QuickSearch {
        var q = quickSearch
        q.id = nil
        if q.time == 0 { q.time = now }
        try q.insert(db)
        return q
    }

    /// 对应 `insertQuickSearchList`：全部以当前时间插入
    @discardableResult
    public func insertQuickSearchList(_ list: [QuickSearch]) throws -> [QuickSearch] {
        try dbQueue.write { db in
            try list.map { item in
                var q = item
                q.id = nil
                q.time = now()
                try q.insert(db)
                return q
            }
        }
    }

    /// 对应 `takeOverQuickSearchList`：keyword 已存在的跳过，其余以当前时间插入
    @discardableResult
    public func takeOverQuickSearchList(_ list: [QuickSearch]) throws -> [QuickSearch] {
        try dbQueue.write { db in
            let all = try QuickSearch.order(Column(Col.time).asc).fetchAll(db)
            var inserted: [QuickSearch] = []
            for item in list where !all.contains(where: { $0.keyword == item.keyword }) {
                var q = item
                q.id = nil
                q.time = now()
                try q.insert(db)
                inserted.append(q)
            }
            return inserted
        }
    }

    public func updateQuickSearch(_ quickSearch: QuickSearch) throws {
        try dbQueue.write { db in try quickSearch.update(db) }
    }

    public func deleteQuickSearch(_ quickSearch: QuickSearch) throws {
        _ = try dbQueue.write { db in try quickSearch.delete(db) }
    }

    /// 对应 `moveQuickSearch`
    public func moveQuickSearch(from fromPosition: Int, to toPosition: Int) throws {
        if fromPosition == toPosition { return }
        try dbQueue.write { db in
            let range = Self.rotationRange(from: fromPosition, to: toPosition)
            var list = try QuickSearch.order(Column(Col.time).asc)
                .limit(range.count, offset: range.lowerBound).fetchAll(db)
            guard list.count == range.count else { return }
            var times = list.map(\.time)
            Self.rotateTimes(&times, reverse: fromPosition > toPosition)
            for i in list.indices {
                list[i].time = times[i]
                try list[i].update(db)
            }
        }
    }

    // MARK: - History（HISTORY）

    /// 对应 `getHistoryLazyList`：按 TIME 降序
    public func allHistory() throws -> [HistoryInfo] {
        try dbQueue.read { db in try HistoryInfo.order(Column(Col.time).desc).fetchAll(db) }
    }

    /// 对应 `putHistoryInfo(GalleryInfo)`：已存在只刷新 time；否则插入并裁剪到 `maxHistoryCount`（<1 时按 100）
    public func putHistoryInfo(_ info: GalleryInfo, mode: Int = 0) throws {
        let time = now()
        let max = maxHistoryCount
        try dbQueue.write { db in
            if var existing = try HistoryInfo.fetchOne(db, key: info.gid) {
                existing.time = time
                try existing.update(db)
            } else {
                try HistoryInfo(info, mode: mode, time: time).insert(db)
                try Self.trimHistory(db, keep: max < 1 ? 100 : max)
            }
        }
    }

    /// 对应 `putHistoryInfo(List<HistoryInfo>)`：插入不存在的项（保留其 time），再裁剪
    public func putHistoryInfo(_ list: [HistoryInfo]) throws {
        let max = maxHistoryCount
        try dbQueue.write { db in try Self.putHistoryInfo(db, list, max: max) }
    }

    static func putHistoryInfo(_ db: Database, _ list: [HistoryInfo], max: Int) throws {
        for info in list { try insertIfAbsent(db, info) }
        try trimHistory(db, keep: max)
    }

    /// 删除按 TIME 降序排在 keep 之后的记录（`limit(-1).offset(keep)`）
    static func trimHistory(_ db: Database, keep: Int) throws {
        try db.execute(
            sql: "DELETE FROM HISTORY WHERE GID IN (SELECT GID FROM HISTORY ORDER BY TIME DESC LIMIT -1 OFFSET ?)",
            arguments: [Swift.max(keep, 0)]
        )
    }

    public func deleteHistoryInfo(_ info: HistoryInfo) throws {
        _ = try dbQueue.write { db in try info.delete(db) }
    }

    public func clearHistoryInfo() throws {
        _ = try dbQueue.write { db in try HistoryInfo.deleteAll(db) }
    }

    // MARK: - Filter（FILTER）

    /// 对应 `getAllFilter`（无排序，按 rowid）
    public func allFilters() throws -> [Filter] {
        try dbQueue.read { db in try Filter.fetchAll(db) }
    }

    /// 对应 `addFilter`：重置 id 后插入，返回带 id 的记录
    @discardableResult
    public func addFilter(_ filter: Filter) throws -> Filter {
        var f = filter
        f.id = nil
        try dbQueue.write { db in try f.insert(db) }
        return f
    }

    public func deleteFilter(_ filter: Filter) throws {
        _ = try dbQueue.write { db in try filter.delete(db) }
    }

    /// 对应 `triggerFilter`：切换 enable 并写库，返回新值
    @discardableResult
    public func triggerFilter(_ filter: Filter) throws -> Filter {
        var f = filter
        f.enable = !f.isEnabled
        try dbQueue.write { db in try f.update(db) }
        return f
    }

    // MARK: - Observation（供 SwiftUI 订阅）

    public func observe<T: Sendable>(_ fetch: @escaping @Sendable (Database) throws -> T) -> AsyncValueObservation<T> {
        ValueObservation.tracking(fetch).values(in: dbQueue)
    }

    /// 下载列表（TIME 降序）
    public func observeDownloads() -> AsyncValueObservation<[DownloadInfo]> {
        observe { db in try DownloadInfo.order(Column(Col.time).desc).fetchAll(db) }
    }

    public func observeDownloadLabels() -> AsyncValueObservation<[DownloadLabel]> {
        observe { db in try DownloadLabel.order(Column(Col.time).asc).fetchAll(db) }
    }

    public func observeHistory() -> AsyncValueObservation<[HistoryInfo]> {
        observe { db in try HistoryInfo.order(Column(Col.time).desc).fetchAll(db) }
    }

    public func observeLocalFavorites() -> AsyncValueObservation<[LocalFavoriteInfo]> {
        observe { db in try LocalFavoriteInfo.order(Column(Col.time).desc).fetchAll(db) }
    }

    public func observeQuickSearch() -> AsyncValueObservation<[QuickSearch]> {
        observe { db in try QuickSearch.order(Column(Col.time).asc).fetchAll(db) }
    }

    public func observeFilters() -> AsyncValueObservation<[Filter]> {
        observe { db in try Filter.fetchAll(db) }
    }

    public func observeBlackList() -> AsyncValueObservation<[BlackList]> {
        observe { db in try BlackList.order(Column("ADD_TIME").asc).fetchAll(db) }
    }

    public func observeBookmarks() -> AsyncValueObservation<[BookmarkInfo]> {
        observe { db in try BookmarkInfo.order(Column(Col.time).desc).fetchAll(db) }
    }

    // MARK: - 工具

    static func insertIfAbsent<R: PersistableRecord & TableRecord>(_ db: Database, _ record: R) throws
        where R: GalleryInfoRecord {
        if try !R.exists(db, key: record.gid) {
            try record.insert(db)
        }
    }

    /// move 算法中受影响的下标区间
    static func rotationRange(from: Int, to: Int) -> Range<Int> {
        let reverse = from > to
        let offset = reverse ? to : from
        let limit = reverse ? from - to + 1 : to - from + 1
        return offset ..< offset + limit
    }

    /// 与 Android move* 系列完全一致的 time 轮换
    static func rotateTimes(_ times: inout [Int64], reverse: Bool) {
        let limit = times.count
        guard limit > 1 else { return }
        let step = reverse ? 1 : -1
        let start = reverse ? limit - 1 : 0
        let end = reverse ? 0 : limit - 1
        let toTime = times[end]
        var i = end
        while reverse ? i < start : i > start {
            times[i] = times[i + step]
            i += step
        }
        times[start] = toTime
    }
}
