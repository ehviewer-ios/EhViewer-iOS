import Foundation
import GRDB
import Testing
@testable import EhStorage

/// 可控时钟
final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64
    init(_ start: Int64 = 1_000) { value = start }
    func tick() -> Int64 { lock.withLock { value += 1; return value } }
    var now: @Sendable () -> Int64 { { [self] in tick() } }
}

func makeDB(_ clock: Clock = Clock()) throws -> EhDatabase {
    try EhDatabase.inMemory(now: clock.now)
}

func sampleInfo(_ gid: Int64, title: String = "Title", uploader: String? = "up") -> GalleryInfo {
    GalleryInfo(gid: gid, token: "tok\(gid)", title: title, titleJpn: "jp\(gid)", thumb: "https://t/\(gid).jpg",
                category: .manga, posted: "2020-01-01 00:00", uploader: uploader, rating: 4.5,
                simpleLanguage: "ZH")
}

func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ehstorage-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite struct EhDatabaseSchemaTests {
    /// 列定义与 greenDAO 生成的 SQL 完全一致
    @Test func columnsMatchGreenDao() throws {
        let db = try makeDB()
        let expected: [String: [(String, String, Bool, Int)]] = [
            "DOWNLOADS": [
                ("GID", "INTEGER", true, 1), ("TOKEN", "TEXT", false, 0), ("TITLE", "TEXT", false, 0),
                ("TITLE_JPN", "TEXT", false, 0), ("THUMB", "TEXT", false, 0), ("CATEGORY", "INTEGER", true, 0),
                ("POSTED", "TEXT", false, 0), ("UPLOADER", "TEXT", false, 0), ("RATING", "REAL", true, 0),
                ("SIMPLE_LANGUAGE", "TEXT", false, 0), ("STATE", "INTEGER", true, 0), ("LEGACY", "INTEGER", true, 0),
                ("TIME", "INTEGER", true, 0), ("LABEL", "TEXT", false, 0), ("ARCHIVE_URI", "TEXT", false, 0),
            ],
            "DOWNLOAD_LABELS": [("_id", "INTEGER", false, 1), ("LABEL", "TEXT", false, 0), ("TIME", "INTEGER", true, 0)],
            "DOWNLOAD_DIRNAME": [("GID", "INTEGER", true, 1), ("DIRNAME", "TEXT", false, 0)],
            "HISTORY": [
                ("GID", "INTEGER", true, 1), ("TOKEN", "TEXT", false, 0), ("TITLE", "TEXT", false, 0),
                ("TITLE_JPN", "TEXT", false, 0), ("THUMB", "TEXT", false, 0), ("CATEGORY", "INTEGER", true, 0),
                ("POSTED", "TEXT", false, 0), ("UPLOADER", "TEXT", false, 0), ("RATING", "REAL", true, 0),
                ("SIMPLE_LANGUAGE", "TEXT", false, 0), ("MODE", "INTEGER", true, 0), ("TIME", "INTEGER", true, 0),
            ],
            "QUICK_SEARCH": [
                ("_id", "INTEGER", false, 1), ("NAME", "TEXT", false, 0), ("MODE", "INTEGER", true, 0),
                ("CATEGORY", "INTEGER", true, 0), ("KEYWORD", "TEXT", false, 0), ("ADVANCE_SEARCH", "INTEGER", true, 0),
                ("MIN_RATING", "INTEGER", true, 0), ("PAGE_FROM", "INTEGER", true, 0), ("PAGE_TO", "INTEGER", true, 0),
                ("TIME", "INTEGER", true, 0),
            ],
            "Black_List": [
                ("_id", "INTEGER", false, 1), ("BADGAYNAME", "TEXT", false, 0), ("REASON", "TEXT", false, 0),
                ("ANGRYWITH", "TEXT", false, 0), ("ADD_TIME", "TEXT", false, 0), ("MODE", "INTEGER", false, 0),
            ],
            "FILTER": [("_id", "INTEGER", false, 1), ("MODE", "INTEGER", true, 0), ("TEXT", "TEXT", false, 0), ("ENABLE", "INTEGER", false, 0)],
            "BOOKMARKS": [
                ("GID", "INTEGER", true, 1), ("TOKEN", "TEXT", false, 0), ("TITLE", "TEXT", false, 0),
                ("TITLE_JPN", "TEXT", false, 0), ("THUMB", "TEXT", false, 0), ("CATEGORY", "INTEGER", true, 0),
                ("POSTED", "TEXT", false, 0), ("UPLOADER", "TEXT", false, 0), ("RATING", "REAL", true, 0),
                ("SIMPLE_LANGUAGE", "TEXT", false, 0), ("PAGE", "INTEGER", true, 0), ("TIME", "INTEGER", true, 0),
            ],
            "LOCAL_FAVORITES": [
                ("GID", "INTEGER", true, 1), ("TOKEN", "TEXT", false, 0), ("TITLE", "TEXT", false, 0),
                ("TITLE_JPN", "TEXT", false, 0), ("THUMB", "TEXT", false, 0), ("CATEGORY", "INTEGER", true, 0),
                ("POSTED", "TEXT", false, 0), ("UPLOADER", "TEXT", false, 0), ("RATING", "REAL", true, 0),
                ("SIMPLE_LANGUAGE", "TEXT", false, 0), ("TIME", "INTEGER", true, 0),
            ],
            "Gallery_Tags": [
                ("GID", "INTEGER", true, 1), ("ROWS", "TEXT", false, 0), ("ARTIST", "TEXT", false, 0),
                ("COSPLAYER", "TEXT", false, 0), ("CHARACTER", "TEXT", false, 0), ("FEMALE", "TEXT", false, 0),
                ("GROUP", "TEXT", false, 0), ("LANGUAGE", "TEXT", false, 0), ("MALE", "TEXT", false, 0),
                ("MISC", "TEXT", false, 0), ("MIXED", "TEXT", false, 0), ("OTHER", "TEXT", false, 0),
                ("PARODY", "TEXT", false, 0), ("RECLASS", "TEXT", false, 0), ("CREATE_TIME", "INTEGER", false, 0),
                ("UPDATE_TIME", "INTEGER", false, 0), ("LOCATION", "TEXT", false, 0),
            ],
        ]
        try db.reader.read { (d: Database) throws in
            for (table, cols) in expected {
                let actual = try d.columns(in: table)
                #expect(actual.map(\.name) == cols.map(\.0), "\(table)")
                #expect(actual.map(\.type) == cols.map(\.1), "\(table)")
                #expect(actual.map(\.isNotNull) == cols.map(\.2), "\(table)")
                #expect(actual.map(\.primaryKeyIndex) == cols.map(\.3), "\(table)")
            }
            #expect(try Int.fetchOne(d, sql: "PRAGMA user_version") == 8)
            #expect(try d.indexes(on: "Black_List").contains { $0.name == "IDX_Black_List_BADGAYNAME" })
        }
    }

    @Test func refusesNewerVersion() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("new.db").path
        try DatabaseQueue(path: path).write { try $0.execute(sql: "PRAGMA user_version = 9") }
        #expect(throws: EhStorageError.unsupportedVersion(9)) { try EhDatabase(path: path) }
    }

    @Test func upgradeFromVersion2() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("v2.db").path
        let q = try DatabaseQueue(path: path)
        try q.write { db in
            try db.execute(sql: "CREATE TABLE \"FILTER\" (\"_id\" INTEGER PRIMARY KEY ,\"MODE\" INTEGER NOT NULL ,\"TEXT\" TEXT);")
            try db.execute(sql: "INSERT INTO FILTER VALUES (1, 0, 'abc')")
            try db.execute(sql: "CREATE TABLE \"QUICK_SEARCH\" (\"_id\" INTEGER PRIMARY KEY ,\"NAME\" TEXT,\"MODE\" INTEGER NOT NULL ,\"CATEGORY\" INTEGER NOT NULL ,\"KEYWORD\" TEXT,\"ADVANCE_SEARCH\" INTEGER NOT NULL ,\"MIN_RATING\" INTEGER NOT NULL ,\"TIME\" INTEGER NOT NULL );")
            try db.execute(sql: "INSERT INTO QUICK_SEARCH VALUES (1, 'n', 0, 1023, 'kw', 0, 0, 5)")
            try db.execute(sql: "CREATE TABLE \"DOWNLOADS\" (\"GID\" INTEGER PRIMARY KEY NOT NULL ,\"TOKEN\" TEXT,\"TITLE\" TEXT,\"TITLE_JPN\" TEXT,\"THUMB\" TEXT,\"CATEGORY\" INTEGER NOT NULL ,\"POSTED\" TEXT,\"UPLOADER\" TEXT,\"RATING\" REAL NOT NULL ,\"SIMPLE_LANGUAGE\" TEXT,\"STATE\" INTEGER NOT NULL ,\"LEGACY\" INTEGER NOT NULL ,\"TIME\" INTEGER NOT NULL ,\"LABEL\" TEXT);")
            try db.execute(sql: "INSERT INTO DOWNLOADS VALUES (7, 't', 'x', NULL, NULL, 2, NULL, NULL, 3.5, NULL, 3, 0, 10, NULL)")
            try db.execute(sql: "PRAGMA user_version = 2")
        }
        try q.close()
        let db = try EhDatabase(path: path)
        let filters = try db.allFilters()
        #expect(filters.count == 1)
        #expect(filters[0].enable == true)
        let qs = try db.allQuickSearch()
        #expect(qs.first?.pageFrom == -1)
        #expect(qs.first?.pageTo == -1)
        #expect(qs.first?.keyword == "kw")
        let d = try db.allDownloadInfo()
        #expect(d.first?.gid == 7)
        #expect(d.first?.archiveUri == nil)
        try db.reader.read { (r: Database) throws in
            #expect(try Int.fetchOne(r, sql: "PRAGMA user_version") == 8)
            #expect(try r.columns(in: "Gallery_Tags").contains { $0.name == "LOCATION" })
        }
    }
}

@Suite struct EhDatabaseDownloadTests {
    @Test func putAndListDownloads() throws {
        let db = try makeDB()
        var a = DownloadInfo(sampleInfo(1), state: DownloadInfo.stateDownload, time: 10, label: "L")
        try db.putDownloadInfo(a)
        try db.putDownloadInfo(DownloadInfo(sampleInfo(2), state: DownloadInfo.stateFinish, time: 20))
        a.state = DownloadInfo.stateWait
        a.archiveUri = "file:///x.zip"
        try db.putDownloadInfo(a) // 更新
        let list = try db.allDownloadInfo()
        #expect(list.map(\.gid) == [2, 1])
        #expect(list[1].state == DownloadInfo.stateNone) // WAIT → NONE
        #expect(list[1].archiveUri == "file:///x.zip")
        #expect(list[1].galleryInfo.category == .manga)
        #expect(list[1].galleryInfo.rating == 4.5)
        #expect(try db.downloadInfo(gid: 1)?.state == DownloadInfo.stateWait) // 库中原值不变
        #expect(try db.containDownloadInfo(gid: 2))
        try db.removeDownloadInfo(gid: 2)
        #expect(try !db.containDownloadInfo(gid: 2))
    }

    @Test func moveDownloadInfoRotatesTimes() throws {
        let db = try makeDB()
        for (gid, t) in [(1, 40), (2, 30), (3, 20), (4, 10)] {
            try db.putDownloadInfo(DownloadInfo(sampleInfo(Int64(gid)), time: Int64(t)))
        }
        var list = try db.allDownloadInfo() // 1,2,3,4
        try db.moveDownloadInfo(&list, from: 0, to: 2)
        #expect(list.map(\.time) == [20, 40, 30, 10])
        #expect(try db.allDownloadInfo().map(\.gid) == [2, 3, 1, 4])
        var list2 = try db.allDownloadInfo()
        try db.moveDownloadInfo(&list2, from: 3, to: 1)
        #expect(try db.allDownloadInfo().map(\.gid) == [2, 4, 3, 1])
    }

    @Test func dirnames() throws {
        let db = try makeDB()
        try db.putDownloadDirname(gid: 1, dirname: "1-a")
        try db.putDownloadDirname(gid: 1, dirname: "1-b")
        #expect(try db.downloadDirname(gid: 1) == "1-b")
        try db.updateDownloadDirname(removeGid: 1, newGid: 2, dirname: "2-c")
        #expect(try db.downloadDirname(gid: 1) == nil)
        #expect(try db.downloadDirname(gid: 2) == "2-c")
        try db.removeDownloadDirname(gid: 2)
        #expect(try db.downloadDirname(gid: 2) == nil)
        try db.putDownloadDirname(gid: 3, dirname: "3")
        try db.clearDownloadDirname()
        #expect(try db.allDownloadDirnames().isEmpty)
    }

    @Test func labels() throws {
        let db = try makeDB()
        let a = try db.addDownloadLabel("A")
        let a2 = try db.addDownloadLabel("A")
        #expect(a.id != nil)
        #expect(a == a2)
        _ = try db.addDownloadLabel("B")
        _ = try db.addDownloadLabel(DownloadLabel(id: 99, label: "C", time: 5_000))
        #expect(try db.allDownloadLabels().map(\.label) == ["A", "B", "C"])
        try db.moveDownloadLabel(from: 2, to: 0)
        #expect(try db.allDownloadLabels().map(\.label) == ["C", "A", "B"])
        var b = try #require(try db.allDownloadLabels().last)
        b.label = "BB"
        try db.updateDownloadLabel(b)
        try db.removeDownloadLabel(try #require(try db.allDownloadLabels().first))
        #expect(try db.allDownloadLabels().map(\.label) == ["A", "BB"])
    }
}

@Suite struct EhDatabaseMiscTests {
    @Test func historyUpdateAndTrim() throws {
        let db = try makeDB()
        db.maxHistoryCount = 3
        for gid in 1 ... 5 { try db.putHistoryInfo(sampleInfo(Int64(gid))) }
        #expect(try db.allHistory().map(\.gid) == [5, 4, 3])
        try db.putHistoryInfo(sampleInfo(3, title: "changed"))
        let h = try db.allHistory()
        #expect(h.map(\.gid) == [3, 5, 4])
        #expect(h[0].title == "Title") // 已存在只更新时间
        try db.putHistoryInfo([HistoryInfo(sampleInfo(9), time: 1), HistoryInfo(sampleInfo(10), time: 999_999)])
        #expect(try db.allHistory().map(\.gid) == [10, 3, 5])
        try db.deleteHistoryInfo(try #require(try db.allHistory().first))
        #expect(try db.allHistory().count == 2)
        try db.clearHistoryInfo()
        #expect(try db.allHistory().isEmpty)
    }

    @Test func localFavorites() throws {
        let db = try makeDB()
        try db.putLocalFavorite(sampleInfo(1, title: "Hello World"))
        try db.putLocalFavorites([sampleInfo(2, title: "Other's"), sampleInfo(1, title: "dup")])
        #expect(try db.allLocalFavorites().count == 2)
        #expect(try db.searchLocalFavorites("world").map(\.gid) == [1]) // LIKE 不区分 ASCII 大小写
        #expect(try db.searchLocalFavorites("'s").map(\.gid) == [2])
        #expect(try db.searchLocalFavorites(gid: 1)?.title == "Hello World")
        #expect(try db.searchLocalFavorites(gid: 3) == nil)
        #expect(try db.containLocalFavorites(gid: 2))
        try db.removeLocalFavorites(gids: [1, 2])
        #expect(try db.allLocalFavorites().isEmpty)
    }

    @Test func quickSearch() throws {
        let db = try makeDB()
        let a = try db.insertQuickSearch(QuickSearch(name: "a", keyword: "ka"))
        #expect(a.id != nil)
        #expect(a.time > 0)
        _ = try db.insertQuickSearch(QuickSearch(name: "b", keyword: "kb", time: 999_999))
        let inserted = try db.takeOverQuickSearchList([QuickSearch(name: "x", keyword: "ka"), QuickSearch(name: "c", keyword: "kc")])
        #expect(inserted.map(\.name) == ["c"])
        #expect(try db.allQuickSearch().map(\.name) == ["a", "c", "b"])
        try db.moveQuickSearch(from: 0, to: 2)
        #expect(try db.allQuickSearch().map(\.name) == ["c", "b", "a"])
        var c = try #require(try db.allQuickSearch().first)
        c.name = "cc"
        try db.updateQuickSearch(c)
        try db.deleteQuickSearch(try #require(try db.allQuickSearch().last))
        #expect(try db.allQuickSearch().map(\.name) == ["cc", "b"])
        let json = c.jsonObject
        #expect(QuickSearch(jsonObject: json).keyword == "kc")
    }

    @Test func blackListAndTags() throws {
        let clock = Clock(1_600_000_000_000)
        let db = try makeDB(clock)
        #expect(try db.insertBlackList(BlackList(badgayname: nil)) == nil)
        let b = try #require(try db.insertBlackList(BlackList.fromComment(user: "bad", comment: "xx")))
        #expect(b.mode == 1)
        #expect(try db.inBlackList("bad"))
        #expect(try !db.inBlackList("bad' OR '1'='1"))
        try db.deleteBlackList(b)
        #expect(try db.allBlackList().isEmpty)

        let t = try db.insertGalleryTags(GalleryTags(gid: 5, artist: "a1,a2", female: "f"))
        #expect(try db.inGalleryTags(gid: 5))
        try db.reader.read { (r: Database) throws in
            // greenDAO Date 列存毫秒整数
            let ms = try Int64.fetchOne(r, sql: "SELECT CREATE_TIME FROM Gallery_Tags WHERE GID = 5")
            #expect(ms == 1_600_000_000_001)
        }
        let q = try #require(try db.queryGalleryTags(gid: 5))
        #expect(q.create_time == t.create_time)
        #expect(q.artist == "a1,a2")
        let u = try db.updateGalleryTags(q)
        #expect(u.update_time! > q.update_time!)
        try db.deleteGalleryTags(u)
        #expect(try db.queryGalleryTags(gid: 5) == nil)
    }

    @Test func filtersAndBookmarks() throws {
        let db = try makeDB()
        let f = try db.addFilter(Filter(id: 5, mode: 0, text: "abc"))
        #expect(f.id != nil)
        let t = try db.triggerFilter(f)
        #expect(t.enable == false)
        #expect(try db.allFilters().first?.enable == false)
        try db.deleteFilter(t)
        #expect(try db.allFilters().isEmpty)

        try db.putBookmark(BookmarkInfo(sampleInfo(3), page: 12, time: 5))
        #expect(try db.bookmark(gid: 3)?.page == 12)
        try db.removeBookmark(gid: 3)
        #expect(try db.allBookmarks().isEmpty)
    }

    @Test func observation() async throws {
        let db = try makeDB()
        let stream = db.observeDownloads()
        var iterator = stream.makeAsyncIterator()
        let first = try await iterator.next()
        #expect(first?.isEmpty == true)
        try db.putDownloadInfo(DownloadInfo(sampleInfo(1), time: 1))
        let second = try await iterator.next()
        #expect(second?.map(\.gid) == [1])
    }
}
