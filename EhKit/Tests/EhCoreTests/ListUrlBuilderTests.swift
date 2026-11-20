import Testing
@testable import EhCore

@Suite struct ListUrlBuilderTests {
    @Test func homepage() {
        #expect(ListUrlBuilder().build(site: .e) == "https://e-hentai.org/")
        #expect(ListUrlBuilder().build(site: .ex) == "https://exhentai.org/")
    }

    @Test func keywordCategoryAndPage() {
        var b = ListUrlBuilder()
        b.category = EhCategory.doujinshi.rawValue | EhCategory.manga.rawValue
        b.keyword = "female:big breasts \"中文\""
        b.pageIndex = 3
        #expect(b.build(site: .ex) == "https://exhentai.org/?f_cats=1017&f_search=female%3Abig+breasts+%22%E4%B8%AD%E6%96%87%22&page=3")
    }

    @Test func blankKeywordIgnored() {
        var b = ListUrlBuilder()
        b.keyword = "   "
        #expect(b.build(site: .e) == "https://e-hentai.org/")
    }

    @Test func advanceSearch() {
        var b = ListUrlBuilder()
        b.keyword = "a"
        b.advanceSearch = ListUrlBuilder.AdvanceSearchTable.SNAME | ListUrlBuilder.AdvanceSearchTable.STAGS
            | ListUrlBuilder.AdvanceSearchTable.SH | ListUrlBuilder.AdvanceSearchTable.SFT
        b.minRating = 4
        b.pageFrom = 10
        #expect(b.build(site: .e) ==
            "https://e-hentai.org/?f_search=a&advsearch=1&f_sname=on&f_stags=on&f_sh=on&f_sft=on&f_sr=on&f_srdd=4&f_sp=on&f_spf=10&f_spt=")

        var all = ListUrlBuilder()
        all.advanceSearch = 0x7ff
        #expect(all.build(site: .e) ==
            "https://e-hentai.org/?advsearch=1&f_sname=on&f_stags=on&f_sdesc=on&f_storr=on&f_sto=on&f_sdt1=on&f_sdt2=on&f_sh=on&f_sfl=on&f_sfu=on&f_sft=on")

        // 未启用高级搜索时忽略评分与页数
        var plain = ListUrlBuilder()
        plain.minRating = 3
        plain.pageTo = 5
        #expect(plain.build(site: .e) == "https://e-hentai.org/")
    }

    @Test func subscription() {
        var b = ListUrlBuilder(mode: .subscription)
        b.pageIndex = 1
        #expect(b.build(site: .ex) == "https://exhentai.org/watched?page=1")
    }

    @Test func uploaderTagFilter() {
        #expect(ListUrlBuilder(mode: .uploader, keyword: "some one").build(site: .e) == "https://e-hentai.org/uploader/some+one")
        #expect(ListUrlBuilder(mode: .uploader, keyword: "x", pageIndex: 2).build(site: .ex) == "https://exhentai.org/uploader/x/2")
        #expect(ListUrlBuilder(mode: .tag, keyword: "female:big breasts").build(site: .e) == "https://e-hentai.org/tag/female%3Abig+breasts")
        #expect(ListUrlBuilder(mode: .tag, keyword: "a", pageIndex: 5).build(site: .e) == "https://e-hentai.org/tag/a/5")
        #expect(ListUrlBuilder(mode: .filter, keyword: "a b").build(site: .e) == "https://e-hentai.org/?f_search=a+b")
        #expect(ListUrlBuilder(mode: .filter, keyword: "a", pageIndex: 2).build(site: .e) == "https://e-hentai.org/?page=2&f_search=a")
    }

    @Test func fixedUrls() {
        #expect(ListUrlBuilder(mode: .whatsHot).build(site: .e) == "https://e-hentai.org/popular")
        #expect(ListUrlBuilder(mode: .whatsHot).build(site: .ex) == "https://exhentai.org/popular")
        #expect(ListUrlBuilder(mode: .imageSearch).build(site: .e) == "https://upld.e-hentai.org/image_lookup.php")
        #expect(ListUrlBuilder(mode: .imageSearch).build(site: .ex) == "https://upld.exhentai.org/upld/image_lookup.php")
    }

    @Test func topList() {
        var b = ListUrlBuilder(mode: .topList)
        b.follow = "tl=11"
        #expect(b.build(site: .ex) == "https://e-hentai.org/toplist.php?tl=11")
        b.pageIndex = 3
        #expect(b.build(site: .e) == "https://e-hentai.org/toplist.php?tl=11&p=3")
        b.pageIndex = 200
        #expect(b.build(site: .e) == "127.0.0.1:8888")
    }

    @Test func pageActionsAndJump() {
        let hrefs = ListPageHrefs(firstHref: "F", prevHref: "P", nextHref: "N", lastHref: "L")
        let b = ListUrlBuilder()
        #expect(b.build(pageAction: .first, hrefs: hrefs) == "F")
        #expect(b.build(pageAction: .prev, hrefs: hrefs) == "P")
        #expect(b.build(pageAction: .next, hrefs: hrefs) == "N")
        #expect(b.build(pageAction: .somewhere, hrefs: hrefs) == "N")
        #expect(b.build(pageAction: .last, hrefs: hrefs) == "L")

        #expect(b.jumpHrefBuild("https://e-hentai.org/?f_search=a&next=123", appendParam: "seek=2024-01-02")
            == "https://e-hentai.org/?f_search=a&next=123&seek=2024-01-02")
        #expect(b.jumpHrefBuild("https://e-hentai.org/?next=1&seek=2023-01-02", appendParam: "jump=1y")
            == "https://e-hentai.org/?next=1&jump=1y")
        #expect(b.jumpHrefBuild("https://e-hentai.org/?next=1&jump=3d", appendParam: "seek=2020-05-06")
            == "https://e-hentai.org/?next=1&seek=2020-05-06")
    }

    @Test func setQueryRoundTrip() {
        var b = ListUrlBuilder()
        b.category = EhCategory.doujinshi.rawValue | EhCategory.nonH.rawValue
        b.keyword = "female:big breasts 中文"
        b.advanceSearch = ListUrlBuilder.DEFAULT_ADVANCE
        b.minRating = 3
        b.pageFrom = 5
        b.pageTo = 50
        let parsed = GalleryListUrlParser.parse(b.build(site: .e))
        #expect(parsed == b)
    }

    @Test func setQueryLegacyCategoryFlags() {
        var b = ListUrlBuilder()
        b.setQuery("f_doujinshi=1&f_manga=1&f_western=0&f_search=abc&f_sr=on&f_srdd=4")
        #expect(b.category == EhCategory.doujinshi.rawValue | EhCategory.manga.rawValue)
        #expect(b.keyword == "abc")
        // 未开启 advsearch 时忽略高级选项
        #expect(b.advanceSearch == -1)
        #expect(b.minRating == -1)

        b.setQuery(nil)
        #expect(b == ListUrlBuilder())
    }

    @Test func setKeywordResets() {
        var b = ListUrlBuilder()
        b.advanceSearch = 3
        b.minRating = 2
        b.set(keyword: "artist:x")
        #expect(b.mode == .tag)
        #expect(b.keyword == "artist:x")
        #expect(b.advanceSearch == -1 && b.minRating == -1 && b.category == -1)
        #expect(b.equalKeyWord("artist:x"))
        #expect(!ListUrlBuilder().equalKeyWord(nil))
    }
}

@Suite struct FavListUrlBuilderTests {
    @Test func build() {
        #expect(FavListUrlBuilder().build(site: .e) == "https://e-hentai.org/favorites.php")
        #expect(FavListUrlBuilder(favCat: 3).build(site: .ex) == "https://exhentai.org/favorites.php?favcat=3")
        #expect(FavListUrlBuilder(index: 2, keyword: "a b", favCat: 9).build(site: .e)
            == "https://e-hentai.org/favorites.php?favcat=9&f_search=a+b&sn=on&st=on&sf=on&page=2")
        // 本地收藏 / 越界编号不附加 favcat
        #expect(FavListUrlBuilder(favCat: FavListUrlBuilder.FAV_CAT_LOCAL).build(site: .e) == "https://e-hentai.org/favorites.php")
        #expect(FavListUrlBuilder(favCat: 10).build(site: .e) == "https://e-hentai.org/favorites.php")
    }

    @Test func helpers() {
        #expect(FavListUrlBuilder.isValidFavCat(0))
        #expect(!FavListUrlBuilder.isValidFavCat(-1))
        #expect(FavListUrlBuilder(favCat: -2).isLocalFavCat)
        let b = FavListUrlBuilder()
        #expect(b.build(pageAction: .last, hrefs: ListPageHrefs(lastHref: "L")) == "L")
        #expect(b.jumpHrefBuild("https://e-hentai.org/favorites.php?favcat=0&next=1", appendParam: "jump=2w")
            == "https://e-hentai.org/favorites.php?favcat=0&next=1&jump=2w")
    }
}
