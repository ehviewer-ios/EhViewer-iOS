import Foundation
import GRDB

/// 建表与升级。SQL 逐字复制自 Android greenDAO 生成的 `createTable` 与 `EhDB.upgradeDB`。
/// 版本号存 `PRAGMA user_version`（与 Android SQLiteOpenHelper 一致），当前为 `DaoMaster.SCHEMA_VERSION = 8`。
enum EhDatabaseSchema {
    /// 对应 `DaoMaster.SCHEMA_VERSION`
    static let version = 8

    static func createAllTables(_ db: Database, ifNotExists: Bool) throws {
        let c = ifNotExists ? "IF NOT EXISTS " : ""
        // GalleryTagsDao
        try db.execute(sql: "CREATE TABLE \(c)\"Gallery_Tags\" (" +
            "\"GID\" INTEGER PRIMARY KEY NOT NULL ," +
            "\"ROWS\" TEXT," +
            "\"ARTIST\" TEXT," +
            "\"COSPLAYER\" TEXT," +
            "\"CHARACTER\" TEXT," +
            "\"FEMALE\" TEXT," +
            "\"GROUP\" TEXT," +
            "\"LANGUAGE\" TEXT," +
            "\"MALE\" TEXT," +
            "\"MISC\" TEXT," +
            "\"MIXED\" TEXT," +
            "\"OTHER\" TEXT," +
            "\"PARODY\" TEXT," +
            "\"RECLASS\" TEXT," +
            "\"CREATE_TIME\" INTEGER," +
            "\"UPDATE_TIME\" INTEGER," +
            "\"LOCATION\" TEXT);")
        // DownloadsDao
        try db.execute(sql: "CREATE TABLE \(c)\"DOWNLOADS\" (" +
            "\"GID\" INTEGER PRIMARY KEY NOT NULL ," +
            "\"TOKEN\" TEXT," +
            "\"TITLE\" TEXT," +
            "\"TITLE_JPN\" TEXT," +
            "\"THUMB\" TEXT," +
            "\"CATEGORY\" INTEGER NOT NULL ," +
            "\"POSTED\" TEXT," +
            "\"UPLOADER\" TEXT," +
            "\"RATING\" REAL NOT NULL ," +
            "\"SIMPLE_LANGUAGE\" TEXT," +
            "\"STATE\" INTEGER NOT NULL ," +
            "\"LEGACY\" INTEGER NOT NULL ," +
            "\"TIME\" INTEGER NOT NULL ," +
            "\"LABEL\" TEXT," +
            "\"ARCHIVE_URI\" TEXT);")
        // DownloadLabelDao
        try db.execute(sql: "CREATE TABLE \(c)\"DOWNLOAD_LABELS\" (" +
            "\"_id\" INTEGER PRIMARY KEY ," +
            "\"LABEL\" TEXT," +
            "\"TIME\" INTEGER NOT NULL );")
        // DownloadDirnameDao
        try db.execute(sql: "CREATE TABLE \(c)\"DOWNLOAD_DIRNAME\" (" +
            "\"GID\" INTEGER PRIMARY KEY NOT NULL ," +
            "\"DIRNAME\" TEXT);")
        // HistoryDao
        try db.execute(sql: "CREATE TABLE \(c)\"HISTORY\" (" +
            "\"GID\" INTEGER PRIMARY KEY NOT NULL ," +
            "\"TOKEN\" TEXT," +
            "\"TITLE\" TEXT," +
            "\"TITLE_JPN\" TEXT," +
            "\"THUMB\" TEXT," +
            "\"CATEGORY\" INTEGER NOT NULL ," +
            "\"POSTED\" TEXT," +
            "\"UPLOADER\" TEXT," +
            "\"RATING\" REAL NOT NULL ," +
            "\"SIMPLE_LANGUAGE\" TEXT," +
            "\"MODE\" INTEGER NOT NULL ," +
            "\"TIME\" INTEGER NOT NULL );")
        // QuickSearchDao
        try db.execute(sql: "CREATE TABLE \(c)\"QUICK_SEARCH\" (" +
            "\"_id\" INTEGER PRIMARY KEY ," +
            "\"NAME\" TEXT," +
            "\"MODE\" INTEGER NOT NULL ," +
            "\"CATEGORY\" INTEGER NOT NULL ," +
            "\"KEYWORD\" TEXT," +
            "\"ADVANCE_SEARCH\" INTEGER NOT NULL ," +
            "\"MIN_RATING\" INTEGER NOT NULL ," +
            "\"PAGE_FROM\" INTEGER NOT NULL ," +
            "\"PAGE_TO\" INTEGER NOT NULL ," +
            "\"TIME\" INTEGER NOT NULL );")
        // BlackListDao
        try db.execute(sql: "CREATE TABLE \(c)\"Black_List\" (" +
            "\"_id\" INTEGER PRIMARY KEY AUTOINCREMENT ," +
            "\"BADGAYNAME\" TEXT," +
            "\"REASON\" TEXT," +
            "\"ANGRYWITH\" TEXT," +
            "\"ADD_TIME\" TEXT," +
            "\"MODE\" INTEGER);")
        try db.execute(sql: "CREATE INDEX \(c)IDX_Black_List_BADGAYNAME ON Black_List" +
            " (\"BADGAYNAME\");")
        // LocalFavoritesDao
        try db.execute(sql: "CREATE TABLE \(c)\"LOCAL_FAVORITES\" (" +
            "\"GID\" INTEGER PRIMARY KEY NOT NULL ," +
            "\"TOKEN\" TEXT," +
            "\"TITLE\" TEXT," +
            "\"TITLE_JPN\" TEXT," +
            "\"THUMB\" TEXT," +
            "\"CATEGORY\" INTEGER NOT NULL ," +
            "\"POSTED\" TEXT," +
            "\"UPLOADER\" TEXT," +
            "\"RATING\" REAL NOT NULL ," +
            "\"SIMPLE_LANGUAGE\" TEXT," +
            "\"TIME\" INTEGER NOT NULL );")
        // BookmarksBao
        try db.execute(sql: "CREATE TABLE \(c)\"BOOKMARKS\" (" +
            "\"GID\" INTEGER PRIMARY KEY NOT NULL ," +
            "\"TOKEN\" TEXT," +
            "\"TITLE\" TEXT," +
            "\"TITLE_JPN\" TEXT," +
            "\"THUMB\" TEXT," +
            "\"CATEGORY\" INTEGER NOT NULL ," +
            "\"POSTED\" TEXT," +
            "\"UPLOADER\" TEXT," +
            "\"RATING\" REAL NOT NULL ," +
            "\"SIMPLE_LANGUAGE\" TEXT," +
            "\"PAGE\" INTEGER NOT NULL ," +
            "\"TIME\" INTEGER NOT NULL );")
        // FilterDao
        try db.execute(sql: "CREATE TABLE \(c)\"FILTER\" (" +
            "\"_id\" INTEGER PRIMARY KEY ," +
            "\"MODE\" INTEGER NOT NULL ," +
            "\"TEXT\" TEXT," +
            "\"ENABLE\" INTEGER);")
    }

    static func userVersion(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
    }

    static func setUserVersion(_ db: Database, _ v: Int) throws {
        try db.execute(sql: "PRAGMA user_version = \(v)")
    }

    /// 打开数据库时调用：新库建表；旧库升级；更新的库报错。
    /// 对应 `DBOpenHelper.onCreate / onUpgrade`。
    static func prepare(_ db: Database) throws {
        let v = try userVersion(db)
        if v == 0 {
            try createAllTables(db, ifNotExists: true)
            try setUserVersion(db, version)
        } else if v < version {
            try upgrade(db, from: v)
            try setUserVersion(db, version)
        } else if v > version {
            throw EhStorageError.unsupportedVersion(v)
        }
        try ensureLatestColumns(db)
    }

    /// 对应 `EhDB.upgradeDB`（switch 贯穿）。
    /// 与 Android 的差异：Android 的 case 1 被注释掉，v1 库不做任何处理；这里 v1 直接建出带 ENABLE 的 FILTER 表。
    static func upgrade(_ db: Database, from oldVersion: Int) throws {
        if oldVersion <= 1 {
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS \"FILTER\" (" +
                "\"_id\" INTEGER PRIMARY KEY ," +
                "\"MODE\" INTEGER NOT NULL ," +
                "\"TEXT\" TEXT," +
                "\"ENABLE\" INTEGER);")
        }
        if oldVersion == 2 { // 2 to 3, add ENABLE column to table FILTER
            try db.execute(sql: "CREATE TABLE " + "\"FILTER2\" (" +
                "\"_id\" INTEGER PRIMARY KEY ," +
                "\"MODE\" INTEGER NOT NULL ," +
                "\"TEXT\" TEXT," +
                "\"ENABLE\" INTEGER);")
            try db.execute(sql: "INSERT INTO \"FILTER2\" (" +
                "_id, MODE, TEXT, ENABLE)" +
                "SELECT _id, MODE, TEXT, 1 FROM [FILTER];")
            try db.execute(sql: "DROP TABLE [FILTER]")
            try db.execute(sql: "ALTER TABLE FILTER2 RENAME TO [FILTER]")
        }
        if oldVersion <= 3 { // 3 to 4, add PAGE_FROM and PAGE_TO column to QUICK_SEARCH
            try db.execute(sql: "CREATE TABLE " + "\"QUICK_SEARCH2\" (" +
                "\"_id\" INTEGER PRIMARY KEY ," +
                "\"NAME\" TEXT," +
                "\"MODE\" INTEGER NOT NULL ," +
                "\"CATEGORY\" INTEGER NOT NULL ," +
                "\"KEYWORD\" TEXT," +
                "\"ADVANCE_SEARCH\" INTEGER NOT NULL ," +
                "\"MIN_RATING\" INTEGER NOT NULL ," +
                "\"PAGE_FROM\" INTEGER NOT NULL ," +
                "\"PAGE_TO\" INTEGER NOT NULL ," +
                "\"TIME\" INTEGER NOT NULL );")
            if try db.tableExists("QUICK_SEARCH") {
                try db.execute(sql: "INSERT INTO \"QUICK_SEARCH2\" (" +
                    "_id, NAME, MODE, CATEGORY, KEYWORD, ADVANCE_SEARCH, MIN_RATING, PAGE_FROM, PAGE_TO, TIME)" +
                    "SELECT _id, NAME, MODE, CATEGORY, KEYWORD, ADVANCE_SEARCH, MIN_RATING, -1, -1, TIME FROM QUICK_SEARCH;")
                try db.execute(sql: "DROP TABLE QUICK_SEARCH")
            }
            try db.execute(sql: "ALTER TABLE QUICK_SEARCH2 RENAME TO QUICK_SEARCH")
        }
        if oldVersion <= 4 {
            try db.execute(sql: "DROP TABLE IF EXISTS \"Black_List\"")
            try db.execute(sql: "CREATE TABLE " + "\"Black_List\" (" +
                "\"_id\" INTEGER PRIMARY KEY AUTOINCREMENT ," +
                "\"BADGAYNAME\" TEXT," +
                "\"REASON\" TEXT," +
                "\"ANGRYWITH\" TEXT," +
                "\"ADD_TIME\" TEXT," +
                "\"MODE\" INTEGER);")
        }
        if oldVersion <= 5 {
            try db.execute(sql: "DROP TABLE IF EXISTS \"Gallery_Tags\"")
            try db.execute(sql: "CREATE TABLE " + "\"Gallery_Tags\" (" +
                "\"GID\" INTEGER PRIMARY KEY NOT NULL ," +
                "\"ROWS\" TEXT," +
                "\"ARTIST\" TEXT," +
                "\"COSPLAYER\" TEXT," +
                "\"CHARACTER\" TEXT," +
                "\"FEMALE\" TEXT," +
                "\"GROUP\" TEXT," +
                "\"LANGUAGE\" TEXT," +
                "\"MALE\" TEXT," +
                "\"MISC\" TEXT," +
                "\"MIXED\" TEXT," +
                "\"OTHER\" TEXT," +
                "\"PARODY\" TEXT," +
                "\"RECLASS\" TEXT," +
                "\"CREATE_TIME\" INTEGER," +
                "\"UPDATE_TIME\" INTEGER);")
        }
        if oldVersion <= 6 { // 6 to 7, add ARCHIVE_URI column to DOWNLOADS table
            try? db.execute(sql: "ALTER TABLE \"DOWNLOADS\" ADD COLUMN \"ARCHIVE_URI\" TEXT")
        }
        if oldVersion <= 7 { // 7 to 8, add LOCATION column to Gallery_Tags
            try? db.execute(sql: "ALTER TABLE \"Gallery_Tags\" ADD COLUMN \"LOCATION\" TEXT")
        }
        // 缺失的表（极旧的库）补建
        try createAllTables(db, ifNotExists: true)
    }

    /// 防御性补列 / 补表。对应 `getAllDownloadInfo` / `exportDB` 中的 "ALTER TABLE ... ADD COLUMN ARCHIVE_URI"。
    static func ensureLatestColumns(_ db: Database) throws {
        try createAllTables(db, ifNotExists: true)
        if try !db.columns(in: "DOWNLOADS").contains(where: { $0.name.uppercased() == "ARCHIVE_URI" }) {
            try db.execute(sql: "ALTER TABLE \"DOWNLOADS\" ADD COLUMN \"ARCHIVE_URI\" TEXT")
        }
        if try !db.columns(in: "Gallery_Tags").contains(where: { $0.name.uppercased() == "LOCATION" }) {
            try db.execute(sql: "ALTER TABLE \"Gallery_Tags\" ADD COLUMN \"LOCATION\" TEXT")
        }
    }
}

public enum EhStorageError: Error, Sendable, Equatable, LocalizedError {
    /// 数据库版本比当前支持的更新（对应 Android `cant_read_the_file`）
    case unsupportedVersion(Int)
    /// 无法读取导入文件
    case cantReadFile(String)
    case exportFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedVersion(v): return "无法读取该文件（数据库版本 \(v) 高于支持的版本 \(EhDatabaseSchema.version)）"
        case let .cantReadFile(msg): return "无法读取该文件：\(msg)"
        case let .exportFailed(msg): return "导出失败：\(msg)"
        }
    }
}
