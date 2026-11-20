import Foundation
import GRDB
import Testing
@testable import EhStorage

/// 构造一个 Android 风格的旧库（schema 6：DOWNLOADS 无 ARCHIVE_URI，Gallery_Tags 无 LOCATION，带 android_metadata）
private func makeAndroidV6Database(at path: String) throws {
    let q = try DatabaseQueue(path: path)
    try q.write { db in
        try db.execute(sql: "CREATE TABLE android_metadata (locale TEXT)")
        try db.execute(sql: "INSERT INTO android_metadata VALUES ('zh_CN')")
        try db.execute(sql: "CREATE TABLE \"Gallery_Tags\" (\"GID\" INTEGER PRIMARY KEY NOT NULL ,\"ROWS\" TEXT,\"ARTIST\" TEXT,\"COSPLAYER\" TEXT,\"CHARACTER\" TEXT,\"FEMALE\" TEXT,\"GROUP\" TEXT,\"LANGUAGE\" TEXT,\"MALE\" TEXT,\"MISC\" TEXT,\"MIXED\" TEXT,\"OTHER\" TEXT,\"PARODY\" TEXT,\"RECLASS\" TEXT,\"CREATE_TIME\" INTEGER,\"UPDATE_TIME\" INTEGER);")
        try db.execute(sql: "CREATE TABLE \"DOWNLOADS\" (\"GID\" INTEGER PRIMARY KEY NOT NULL ,\"TOKEN\" TEXT,\"TITLE\" TEXT,\"TITLE_JPN\" TEXT,\"THUMB\" TEXT,\"CATEGORY\" INTEGER NOT NULL ,\"POSTED\" TEXT,\"UPLOADER\" TEXT,\"RATING\" REAL NOT NULL ,\"SIMPLE_LANGUAGE\" TEXT,\"STATE\" INTEGER NOT NULL ,\"LEGACY\" INTEGER NOT NULL ,\"TIME\" INTEGER NOT NULL ,\"LABEL\" TEXT);")
        try db.execute(sql: "CREATE TABLE \"DOWNLOAD_LABELS\" (\"_id\" INTEGER PRIMARY KEY ,\"LABEL\" TEXT,\"TIME\" INTEGER NOT NULL );")
        try db.execute(sql: "CREATE TABLE \"DOWNLOAD_DIRNAME\" (\"GID\" INTEGER PRIMARY KEY NOT NULL ,\"DIRNAME\" TEXT);")
        try db.execute(sql: "CREATE TABLE \"HISTORY\" (\"GID\" INTEGER PRIMARY KEY NOT NULL ,\"TOKEN\" TEXT,\"TITLE\" TEXT,\"TITLE_JPN\" TEXT,\"THUMB\" TEXT,\"CATEGORY\" INTEGER NOT NULL ,\"POSTED\" TEXT,\"UPLOADER\" TEXT,\"RATING\" REAL NOT NULL ,\"SIMPLE_LANGUAGE\" TEXT,\"MODE\" INTEGER NOT NULL ,\"TIME\" INTEGER NOT NULL );")
        try db.execute(sql: "CREATE TABLE \"QUICK_SEARCH\" (\"_id\" INTEGER PRIMARY KEY ,\"NAME\" TEXT,\"MODE\" INTEGER NOT NULL ,\"CATEGORY\" INTEGER NOT NULL ,\"KEYWORD\" TEXT,\"ADVANCE_SEARCH\" INTEGER NOT NULL ,\"MIN_RATING\" INTEGER NOT NULL ,\"PAGE_FROM\" INTEGER NOT NULL ,\"PAGE_TO\" INTEGER NOT NULL ,\"TIME\" INTEGER NOT NULL );")
        try db.execute(sql: "CREATE TABLE \"Black_List\" (\"_id\" INTEGER PRIMARY KEY AUTOINCREMENT ,\"BADGAYNAME\" TEXT,\"REASON\" TEXT,\"ANGRYWITH\" TEXT,\"ADD_TIME\" TEXT,\"MODE\" INTEGER);")
        try db.execute(sql: "CREATE TABLE \"LOCAL_FAVORITES\" (\"GID\" INTEGER PRIMARY KEY NOT NULL ,\"TOKEN\" TEXT,\"TITLE\" TEXT,\"TITLE_JPN\" TEXT,\"THUMB\" TEXT,\"CATEGORY\" INTEGER NOT NULL ,\"POSTED\" TEXT,\"UPLOADER\" TEXT,\"RATING\" REAL NOT NULL ,\"SIMPLE_LANGUAGE\" TEXT,\"TIME\" INTEGER NOT NULL );")
        try db.execute(sql: "CREATE TABLE \"BOOKMARKS\" (\"GID\" INTEGER PRIMARY KEY NOT NULL ,\"TOKEN\" TEXT,\"TITLE\" TEXT,\"TITLE_JPN\" TEXT,\"THUMB\" TEXT,\"CATEGORY\" INTEGER NOT NULL ,\"POSTED\" TEXT,\"UPLOADER\" TEXT,\"RATING\" REAL NOT NULL ,\"SIMPLE_LANGUAGE\" TEXT,\"PAGE\" INTEGER NOT NULL ,\"TIME\" INTEGER NOT NULL );")
        try db.execute(sql: "CREATE TABLE \"FILTER\" (\"_id\" INTEGER PRIMARY KEY ,\"MODE\" INTEGER NOT NULL ,\"TEXT\" TEXT,\"ENABLE\" INTEGER);")

        try db.execute(sql: "INSERT INTO DOWNLOAD_LABELS VALUES (1, 'Comics', 100), (2, 'Existing', 200)")
        try db.execute(sql: """
            INSERT INTO DOWNLOADS VALUES
            (101, 'aaa', 'Gallery A', 'ギャラリーA', 'https://t/a.jpg', 4, '2020-01-01 10:00', 'alice', 4.5, 'ZH', 2, 0, 1000, 'Comics'),
            (102, 'bbb', 'Gallery B', NULL, NULL, 2, NULL, 'bob', 3.0, NULL, 3, 0, 2000, 'NewLabel'),
            (200, 'ccc', 'Dup', NULL, NULL, 2, NULL, NULL, 0, NULL, 3, 0, 3000, NULL)
            """)
        try db.execute(sql: "INSERT INTO DOWNLOAD_DIRNAME VALUES (101, '101-Gallery A'), (200, '200-overwritten')")
        try db.execute(sql: "INSERT INTO HISTORY VALUES (301, 'h', 'Hist', NULL, NULL, 2, NULL, NULL, 2.0, NULL, 0, 5000), (200, 'x', 'Exists', NULL, NULL, 2, NULL, NULL, 0, NULL, 0, 1)")
        try db.execute(sql: "INSERT INTO QUICK_SEARCH VALUES (1, 'same', 0, 1023, 'kw1', 0, 0, -1, -1, 0), (2, 'new', 0, 1023, 'kw2', 0, 0, 1, 10, 777)")
        try db.execute(sql: "INSERT INTO Black_List VALUES (1, 'troll', 'r', 'angry', '2023-01-01 00:00:00', 1), (2, 'existing', NULL, NULL, NULL, 1)")
        try db.execute(sql: "INSERT INTO LOCAL_FAVORITES VALUES (401, 'f', 'Fav', NULL, NULL, 2, NULL, NULL, 5.0, NULL, 8888)")
        try db.execute(sql: "INSERT INTO BOOKMARKS VALUES (501, 'b', 'Book', NULL, NULL, 2, NULL, NULL, 1.0, NULL, 7, 9999)")
        try db.execute(sql: "INSERT INTO FILTER VALUES (1, 0, 'spam', 1), (2, 1, 'Existing', 0)")
        try db.execute(sql: "INSERT INTO Gallery_Tags VALUES (601, NULL, 'artist1', NULL, NULL, 'female1', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 1, 2), (700, NULL, 'dup', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 1, 2)")
        try db.execute(sql: "PRAGMA user_version = 6")
    }
    try q.close()
}

@Suite struct EhDatabaseTransferTests {
    @Test func importAndroidDatabase() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("android-export.db")
        try makeAndroidV6Database(at: src.path)

        let clock = Clock(1_700_000_000_000)
        let db = try makeDB(clock)
        db.maxHistoryCount = 100
        // 已有数据
        _ = try db.addDownloadLabel("Existing")
        try db.putDownloadInfo(DownloadInfo(gid: 200, title: "Mine", time: 1))
        try db.putHistoryInfo(sampleInfo(200))
        _ = try db.insertQuickSearch(QuickSearch(name: "same", keyword: "other"))
        _ = try db.addFilter(Filter(mode: 1, text: "Existing"))
        _ = try db.insertBlackList(BlackList(badgayname: "existing"))
        _ = try db.insertGalleryTags(GalleryTags(gid: 700, artist: "mine"))

        let progress = ProgressBox()
        let s = try db.importDatabase(from: src) { progress.append($0) }
        #expect(progress.values == [10, 50, 90, 100])

        // 源文件未被修改（Android 会原地升级）
        try DatabaseQueue(path: src.path).read { (r: Database) throws in
            #expect(try Int.fetchOne(r, sql: "PRAGMA user_version") == 6)
        }

        // 标签：Comics 新增；Existing 已存在；NewLabel 由下载项引入
        #expect(try db.allDownloadLabels().map(\.label) == ["Comics", "Existing", "NewLabel"])
        #expect(s.downloadLabels == 2)

        // 下载：101/102 新增，200 已存在保持不变；DOWNLOAD 状态改为 NONE
        let downloads = try db.allDownloadInfo()
        #expect(Set(downloads.map(\.gid)) == [101, 102, 200])
        let a = try #require(try db.downloadInfo(gid: 101))
        #expect(a.state == DownloadInfo.stateNone)
        #expect(a.titleJpn == "ギャラリーA")
        #expect(a.galleryInfo.category == .manga)
        #expect(a.rating == 4.5)
        #expect(a.archiveUri == nil)
        #expect(try db.downloadInfo(gid: 200)?.title == "Mine")
        #expect(s.downloads == 2)

        // 目录名全部覆盖
        #expect(try db.downloadDirname(gid: 200) == "200-overwritten")
        #expect(try db.downloadDirname(gid: 101) == "101-Gallery A")

        // 历史：301 新增，200 保留本地
        let history = try db.allHistory()
        #expect(Set(history.map(\.gid)) == [200, 301])
        #expect(history.first(where: { $0.gid == 200 })?.title == "Title")

        // 快速搜索：同名跳过；time 非 0 保留
        let qs = try db.allQuickSearch()
        #expect(qs.map(\.name) == ["new", "same"])
        #expect(qs.first?.time == 777)
        #expect(qs.first?.pageTo == 10)

        #expect(try db.searchLocalFavorites(gid: 401)?.time == 8888)
        #expect(try db.bookmark(gid: 501)?.page == 7)

        // 过滤器：mode+text 相同跳过
        let filters = try db.allFilters()
        #expect(filters.count == 2)
        #expect(filters.contains { $0.text == "spam" && $0.enable == true })

        // 黑名单按名字去重
        #expect(try db.allBlackList().compactMap(\.badgayname).sorted() == ["existing", "troll"])

        // GalleryTags：700 已存在跳过；601 新增并刷新时间
        #expect(try db.queryGalleryTags(gid: 700)?.artist == "mine")
        let t = try #require(try db.queryGalleryTags(gid: 601))
        #expect(t.female == "female1")
        #expect(t.create_time.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) } ?? 0 > 1_700_000_000_000)
        #expect(s.galleryTags == 1)

        // 再次导入不产生重复
        let again = try db.importDatabase(from: src)
        #expect(again.downloads == 0)
        #expect(again.quickSearches == 0)
        #expect(again.filters == 0)
        #expect(again.blackList == 0)
        #expect(again.galleryTags == 0)
    }

    @Test func importRejectsBadFiles() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try makeDB()
        let junk = dir.appendingPathComponent("junk.db")
        try Data("this is not sqlite at all, definitely not".utf8).write(to: junk)
        #expect(throws: EhStorageError.self) { try db.importDatabase(from: junk) }
        let newer = dir.appendingPathComponent("newer.db")
        try DatabaseQueue(path: newer.path).write { try $0.execute(sql: "PRAGMA user_version = 99") }
        #expect(throws: EhStorageError.unsupportedVersion(99)) { try db.importDatabase(from: newer) }
        #expect(throws: EhStorageError.self) { try db.importDatabase(from: dir.appendingPathComponent("missing.db")) }
    }

    @Test func exportThenImportRoundTrip() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try makeDB()
        _ = try db.addDownloadLabel("L1")
        try db.putDownloadInfo(DownloadInfo(sampleInfo(1), state: DownloadInfo.stateFinish, time: 5, label: "L1", archiveUri: "file:///a.zip"))
        try db.putDownloadDirname(gid: 1, dirname: "1-Title")
        try db.putHistoryInfo(sampleInfo(2))
        _ = try db.insertQuickSearch(QuickSearch(name: "q", keyword: "k"))
        try db.putLocalFavorite(sampleInfo(3))
        try db.putBookmark(BookmarkInfo(sampleInfo(4), page: 3, time: 1))
        _ = try db.addFilter(Filter(mode: 2, text: "female:x"))
        _ = try db.insertBlackList(BlackList(badgayname: "b"))
        _ = try db.insertGalleryTags(GalleryTags(gid: 9))

        let out = dir.appendingPathComponent("export.db")
        try db.exportDatabase(to: out)
        try DatabaseQueue(path: out.path).read { (r: Database) throws in
            #expect(try Int.fetchOne(r, sql: "PRAGMA user_version") == 8)
            #expect(try String.fetchOne(r, sql: "SELECT locale FROM android_metadata") == "en_US")
            #expect(try Int.fetchOne(r, sql: "SELECT COUNT(*) FROM DOWNLOADS") == 1)
            #expect(try String.fetchOne(r, sql: "SELECT ARCHIVE_URI FROM DOWNLOADS") == "file:///a.zip")
            // 与 Android 相同：默认不导出黑名单与 GalleryTags
            #expect(try Int.fetchOne(r, sql: "SELECT COUNT(*) FROM Black_List") == 0)
            #expect(try Int.fetchOne(r, sql: "SELECT COUNT(*) FROM Gallery_Tags") == 0)
        }
        // 导出文件可直接作为数据库打开
        let reopened = try EhDatabase(url: out)
        #expect(try reopened.allDownloadInfo().first?.label == "L1")
        try reopened.close()

        let fresh = try makeDB()
        let s = try fresh.importDatabase(from: out)
        #expect(s.downloads == 1)
        #expect(try fresh.allDownloadLabels().map(\.label) == ["L1"])
        #expect(try fresh.downloadDirname(gid: 1) == "1-Title")
        #expect(try fresh.allHistory().map(\.gid) == [2])
        #expect(try fresh.allQuickSearch().map(\.keyword) == ["k"])
        #expect(try fresh.containLocalFavorites(gid: 3))
        #expect(try fresh.bookmark(gid: 4)?.page == 3)
        #expect(try fresh.allFilters().map(\.text) == ["female:x"])

        let full = dir.appendingPathComponent("full.db")
        try db.exportDatabase(to: full, includeBlackListAndTags: true)
        let fresh2 = try makeDB()
        let s2 = try fresh2.importDatabase(from: full)
        #expect(s2.blackList == 1)
        #expect(s2.galleryTags == 1)
    }
}

final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Int] = []
    func append(_ v: Int) { lock.withLock { _values.append(v) } }
    var values: [Int] { lock.withLock { _values } }
}
