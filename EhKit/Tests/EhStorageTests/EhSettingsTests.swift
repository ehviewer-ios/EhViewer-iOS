import Foundation
import Testing
@testable import EhStorage

private func withSettings(_ body: (EhSettings, UserDefaults) throws -> Void) rethrows {
    let suite = "ehsettings-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    try body(EhSettings(defaults: defaults), defaults)
}

@Suite struct EhSettingsTests {
    @Test func defaultsMatchAndroid() {
        withSettings { s, _ in
            #expect(s.theme == .light)
            #expect(s.gallerySite == .e)
            #expect(s.launchPage == .homepage)
            #expect(s.listMode == .detail)
            #expect(s.thumbSize == .middle)
            #expect(s.showTagTranslations)
            #expect(s.defaultCategories == 0x3FF)
            #expect(s.readingDirection == .rightToLeft)
            #expect(s.pageScaling == .fit)
            #expect(s.startPosition == .topRight)
            #expect(s.readingRefreshRate == .systemDefault)
            #expect(s.startTransferTime == 2)
            #expect(s.screenLightness == 50)
            #expect(s.multiThreadDownload == 3)
            #expect(s.preloadImage == 5)
            #expect(s.imageResolution == .auto)
            #expect(s.favCat == (0 ..< 10).map { "Favorites \($0)" })
            #expect(s.favCount == Array(repeating: 0, count: 10))
            #expect(s.recentFavCat == -1)
            #expect(s.defaultFavSlot == -2)
            #expect(s.readCacheSize == 160)
            #expect(s.builtInHosts && s.builtExHosts && s.domainFronting)
            #expect(!s.doH)
            #expect(s.appLanguage == "system")
            #expect(s.proxyType == .system)
            #expect(s.proxyPort == -1)
            #expect(s.historyInfoSize == 100)
            #expect(s.downloadOrderAsc)
            #expect(s.downloadPagination)
            #expect(s.excludedLanguages == nil)
            #expect(s.security == "")
        }
    }

    @Test func intFromStrStoredAsStringWithAndroidKeys() {
        withSettings { s, d in
            s.theme = .black
            s.readingDirection = .topToBottom
            s.multiThreadDownload = 7
            #expect(d.object(forKey: "theme") as? String == "2")
            #expect(d.object(forKey: "reading_direction") as? String == "2")
            #expect(d.object(forKey: "download_thread") as? String == "7")
            s.defaultCategories = 5
            #expect(d.object(forKey: "default_categories") as? Int == 5)
            s.showJpnTitle = true
            #expect(d.object(forKey: "show_jpn_title") as? Bool == true)
            s.enabledSecurity = true
            #expect(d.object(forKey: "enable_secure") as? Bool == true)
            #expect(s.readingFullscreen) // Android 的误写 bug 未保留
        }
    }

    @Test func sanitize() {
        withSettings { s, d in
            d.set("9", forKey: "reading_direction")
            #expect(s.readingDirection == .leftToRight)
            d.set("9", forKey: "page_scaling")
            #expect(s.pageScaling == .fit)
            d.set("9", forKey: "start_position")
            #expect(s.startPosition == .topLeft)
            d.set("75", forKey: "reading_refresh_rate")
            #expect(s.readingRefreshRate == .systemDefault)
            d.set("-1", forKey: "reading_refresh_rate")
            #expect(s.readingRefreshRate == .displayMax)
            d.set("garbage", forKey: "download_thread")
            #expect(s.multiThreadDownload == 3)
            d.set("-1", forKey: "history_info_size")
            #expect(s.historyInfoSize == 100)
            #expect(d.object(forKey: "history_info_size") as? String == "100") // 写回
            d.set("-5", forKey: "download_timeout")
            #expect(s.downloadTimeout == 0)
            d.set("980", forKey: "image_size")
            #expect(s.imageResolution == .x780)
            #expect(d.string(forKey: "image_size") == "780")
            d.set("abc", forKey: "default_categories") // 类型不符 → 默认值
            #expect(s.defaultCategories == 0x3FF)
            d.set("5", forKey: "gallery_site")
            #expect(s.gallerySite == .e)
        }
    }

    @Test func loginGatedAndMisc() {
        withSettings { s, _ in
            #expect(!s.showEhEvents)
            s.isLogin = true
            #expect(s.showEhEvents && s.showEhLimits)
            s.showEhEvents = false
            #expect(!s.showEhEvents)

            let id = s.userID
            #expect(id.count == 32)
            #expect(s.userID == id)

            s.favCat = (0 ..< 10).map { "F\($0)" }
            #expect(s.favCat[9] == "F9")
            s.displayName = "me"
            s.displayName = nil
            #expect(s.displayName == nil)

            s.fixDefaultValue(regionCode: "CN")
            #expect(s.contains(EhSettings.Key.builtInHosts))
            s.themeAutoSwitch = true
            s.applySystemDarkMode(true)
            #expect(s.theme == .dark)
        }
    }

    @Test func importAndroidPreferencesXML() throws {
        try withSettings { s, d in
            let xml = """
            <?xml version='1.0' encoding='utf-8' standalone='yes' ?>
            <map>
                <string name="theme">1</string>
                <boolean name="show_jpn_title" value="true" />
                <int name="default_categories" value="1019" />
                <long name="last_update_time" value="1700000000000" />
                <string name="excluded_languages">x1x1024</string>
                <string name="reading_direction">0</string>
                <string name="fav_cat_3">My &amp; Fav</string>
                <set name="some_set"><string>a</string><string>b</string></set>
                <boolean name="apply_nav_bar_theme_color" value="true" />
            </map>
            """
            let n = try s.importAndroidPreferences(xml: Data(xml.utf8))
            #expect(n == 7) // 省略项 last_update_time / apply_nav_bar_theme_color 被跳过
            #expect(s.theme == .dark)
            #expect(s.showJpnTitle)
            #expect(s.defaultCategories == 1019)
            #expect(s.excludedLanguages == "x1x1024")
            #expect(s.readingDirection == .leftToRight)
            #expect(s.favCat[3] == "My & Fav")
            #expect(d.object(forKey: "last_update_time") == nil)
        }
    }
}

@Suite struct EhFilterTests {
    @Test func titleUploaderTagNamespace() throws {
        let db = try makeDB()
        _ = try db.addFilter(Filter(mode: 0, text: "SPAM"))
        _ = try db.addFilter(Filter(mode: 1, text: "BadUser"))
        _ = try db.addFilter(Filter(mode: 2, text: "female:Guro"))
        _ = try db.addFilter(Filter(mode: 2, text: "yaoi"))
        _ = try db.addFilter(Filter(mode: 3, text: "Male"))
        let filter = try EhFilter(database: db)
        #expect(filter.needTags)

        #expect(!filter.filterTitle(GalleryInfo(gid: 1, title: "Some spam here")))
        #expect(filter.filterTitle(GalleryInfo(gid: 1, title: "clean")))
        #expect(filter.filterTitle(GalleryInfo(gid: 1, title: nil)))

        #expect(!filter.filterUploader(GalleryInfo(gid: 1, uploader: "BadUser")))
        #expect(filter.filterUploader(GalleryInfo(gid: 1, uploader: "baduser"))) // 区分大小写

        #expect(!filter.filterTag(GalleryInfo(gid: 1, simpleTags: ["female:guro"])))
        #expect(filter.filterTag(GalleryInfo(gid: 1, simpleTags: ["male:guro"]))) // 命名空间不同
        #expect(!filter.filterTag(GalleryInfo(gid: 1, simpleTags: ["guro"]))) // tag 无命名空间时只比名称
        #expect(!filter.filterTag(GalleryInfo(gid: 1, simpleTags: ["male:yaoi"]))) // 规则无命名空间
        #expect(filter.filterTag(GalleryInfo(gid: 1, simpleTags: nil)))

        #expect(!filter.filterTagNamespace(GalleryInfo(gid: 1, simpleTags: ["male:anything"])))
        #expect(filter.filterTagNamespace(GalleryInfo(gid: 1, simpleTags: ["male"])))

        #expect(filter.filter(GalleryInfo(gid: 1, title: "ok", uploader: "x", simpleTags: ["female:ok"])))
        #expect(filter.filter([GalleryInfo(gid: 1, title: "spam"), GalleryInfo(gid: 2, title: "ok")]).map(\.gid) == [2])
        #expect(!filter.filterBeforeTags(GalleryInfo(gid: 1, title: "spam")))
        #expect(filter.filterAfterTags(GalleryInfo(gid: 1, title: "spam")))
    }

    @Test func triggerDeleteAndBlackList() throws {
        let db = try makeDB()
        let filter = try EhFilter(database: db)
        #expect(!filter.needTags)
        let f = try filter.addFilter(Filter(mode: 0, text: "Foo", enable: false))
        #expect(f.enable == true) // addFilter 强制启用
        #expect(filter.titleFilterList.first?.text == "foo")
        #expect(!filter.filterTitle(GalleryInfo(gid: 1, title: "FOO bar")))
        let off = try filter.triggerFilter(f)
        #expect(off.enable == false)
        #expect(filter.filterTitle(GalleryInfo(gid: 1, title: "FOO bar")))
        try filter.deleteFilter(off)
        #expect(filter.titleFilterList.isEmpty)
        #expect(try db.allFilters().isEmpty)

        _ = try filter.addToBlackList(BlackList.fromComment(user: "troll", comment: "..."))
        #expect(filter.isBlacklisted("troll"))
        #expect(!filter.isBlacklisted(nil))
        let comments = [("troll", "a"), ("nice", "b")]
        #expect(filter.filterComments(comments) { $0.0 }.map(\.0) == ["nice"])
        try filter.removeFromBlackList(try #require(try db.allBlackList().first))
        #expect(!filter.isBlacklisted("troll"))
    }
}

@Suite struct AppDirectoriesTests {
    @Test func layout() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dirs = AppDirectories(root: root)
        let download = try #require(dirs.defaultDownloadDir)
        #expect(download.path.hasSuffix("Documents/download"))
        #expect(FileManager.default.fileExists(atPath: download.path))
        #expect(dirs.tempDir?.path.hasSuffix("Caches/temp") == true)
        #expect(dirs.archiverDir?.lastPathComponent == "archiver")
        #expect(dirs.imageCacheDir?.lastPathComponent == "image")
        #expect(dirs.spiderInfoCacheDir?.lastPathComponent == "spider_info")
        #expect(dirs.filesDir("tag-translations")?.path.hasSuffix("Application Support/tag-translations") == true)
        #expect(dirs.databaseURL.lastPathComponent == "eh.db")
        #expect(dirs.createTempFile(extension: "zip")?.pathExtension == "zip")

        let old = try #require(dirs.saveParseErrorBody("<html/>", now: Date(timeIntervalSince1970: 0)))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: old.path)
        let fresh = try #require(dirs.saveParseErrorBody("<html/>"))
        dirs.deleteOldParseErrorFiles()
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))

        // 同名文件占位时返回 nil
        try Data().write(to: dirs.caches.appendingPathComponent("thumb"))
        #expect(dirs.thumbCacheDir == nil)

        let db = try EhDatabase(url: dirs.databaseURL)
        try db.putLocalFavorite(sampleInfo(1))
        try db.close()
        #expect(try EhDatabase(url: dirs.databaseURL).containLocalFavorites(gid: 1))
    }
}
