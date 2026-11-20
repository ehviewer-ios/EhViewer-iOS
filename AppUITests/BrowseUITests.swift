import XCTest

/// 浏览、搜索、下载列表的交互回归测试。使用真实站点数据（需要网络），截图作为附件保存（见 scripts/ui-test.sh）
final class BrowseUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-EHDisableImages", "YES"]
        // 通知等系统权限弹窗
        addUIInterruptionMonitor(withDescription: "系统弹窗") { alert in
            for title in ["允许", "Allow", "好", "OK"] where alert.buttons[title].exists {
                alert.buttons[title].tap()
                return true
            }
            return false
        }
        app.launch()
    }

    // MARK: 问题 1：提交搜索后导航栏按钮恢复显示，搜索框保留搜索词

    func testSearchSubmitShowsToolbar() {
        XCTAssertTrue(firstGallery.waitForExistence(timeout: 30))
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        snap("1-home")
        search.tap()
        search.typeText("chinese")
        snap("1-typing")
        search.typeText("\n")

        let quick = app.navigationBars.buttons["快速搜索"]
        XCTAssertTrue(quick.waitForExistence(timeout: 10))
        XCTAssertTrue(firstGallery.waitForExistence(timeout: 30))
        snap("1-submitted")
        XCTAssertTrue(quick.isHittable, "搜索后快速搜索按钮不可点")
        XCTAssertEqual(app.searchFields.firstMatch.value as? String, "chinese")
        XCTAssertTrue(app.buttons["重置条件"].exists, "条件栏应显示重置")

        // 修改后取消：列表与搜索框恢复为已提交的搜索
        tapSearchButton()
        app.searchFields.firstMatch.typeText(" abc")
        snap("1-editing")
        cancelSearch()
        XCTAssertTrue(quick.waitForExistence(timeout: 5))
        snap("1-cancelled")
        XCTAssertEqual(app.searchFields.firstMatch.value as? String, "chinese")

        // 可以把当前搜索添加为快速搜索
        quick.tap()
        let add = app.buttons["添加当前搜索"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        XCTAssertTrue(add.isEnabled, "添加当前搜索不可用")
        snap("1-quick-search")
        tapFirst(["关闭", "Close", "完成"])
        sleep(1)

        // 点清除按钮（搜索框进入编辑状态）后取消：清除搜索，回到首页
        let clear = app.searchFields.firstMatch.buttons.firstMatch
        XCTAssertTrue(clear.exists, "搜索框没有清除按钮")
        clear.tap()
        sleep(1)
        snap("1-cleared-editing")
        cancelSearch()
        sleep(2)
        snap("1-cleared")
        XCTAssertFalse(app.buttons["重置条件"].exists, "清除后应回到首页")
        XCTAssertNotEqual(app.searchFields.firstMatch.value as? String, "chinese")
        XCTAssertTrue(firstGallery.waitForExistence(timeout: 30))
    }

    // MARK: 首次搜索点搜索历史：搜索生效，搜索框显示历史中的搜索词

    func testHistorySearchInFreshLaunch() {
        // 先搜索一次，确保历史中有记录
        XCTAssertTrue(firstGallery.waitForExistence(timeout: 30))
        tapSearchButton()
        app.searchFields.firstMatch.typeText("chinese\n")
        XCTAssertTrue(app.navigationBars.buttons["快速搜索"].waitForExistence(timeout: 10))

        // 重新启动：搜索框为空时点历史记录
        app.terminate()
        app.launch()
        XCTAssertTrue(firstGallery.waitForExistence(timeout: 30))
        tapSearchButton()
        let history = app.staticTexts["chinese"].firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        snap("4-history")
        history.tap()
        XCTAssertTrue(app.navigationBars.buttons["快速搜索"].waitForExistence(timeout: 10))
        XCTAssertTrue(firstGallery.waitForExistence(timeout: 30))
        snap("4-history-searched")
        XCTAssertEqual(app.searchFields.firstMatch.value as? String, "chinese")
        XCTAssertTrue(app.buttons["重置条件"].exists, "点历史后搜索没有生效")
    }

    // MARK: 标签建议只填入搜索框，不提交

    func testTagSuggestionFillsWithoutSubmitting() {
        XCTAssertTrue(firstGallery.waitForExistence(timeout: 30))
        tapSearchButton()
        app.searchFields.firstMatch.typeText("chines")
        let suggestion = app.staticTexts["汉语"].firstMatch
        XCTAssertTrue(suggestion.waitForExistence(timeout: 10))
        suggestion.tap()
        sleep(1)
        snap("5-filled")
        // 仍在编辑：导航栏按钮隐藏，可以继续输入
        XCTAssertFalse(app.navigationBars.buttons["快速搜索"].exists, "点标签建议不应提交搜索")
        XCTAssertEqual(app.searchFields.firstMatch.value as? String, "l:\"chinese$\" ")
        app.searchFields.firstMatch.typeText("-zzqqxx\n")
        XCTAssertTrue(app.navigationBars.buttons["快速搜索"].waitForExistence(timeout: 10))
        XCTAssertTrue(firstGallery.waitForExistence(timeout: 30))
        snap("5-submitted")
        XCTAssertEqual(app.searchFields.firstMatch.value as? String, "l:\"chinese$\" -zzqqxx")
    }

    // MARK: 问题 3、4：标签搜索可追加条件；标签搜索结果中打开的详情页在最上层

    func testTagSearchEditableAndOpensDetail() {
        XCTAssertTrue(firstGallery.waitForExistence(timeout: 30))
        firstGallery.tap()
        XCTAssertTrue(element("gallery-detail").waitForExistence(timeout: 10))
        let tag = app.buttons.matching(NSPredicate(format: "label CONTAINS '：'")).firstMatch
        XCTAssertTrue(tag.waitForExistence(timeout: 30))
        snap("2-detail")
        tag.tap()
        let searchTag = app.buttons["搜索此标签"]
        XCTAssertTrue(searchTag.waitForExistence(timeout: 5))
        searchTag.tap()

        XCTAssertTrue(firstGallery.waitForExistence(timeout: 30))
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        let tagQuery = search.value as? String ?? ""
        snap("2-tag-list")
        XCTAssertTrue(tagQuery.contains(":"), "搜索框应为标签搜索语法：\(tagQuery)")

        // 打开结果：详情页不能被列表盖住
        firstGallery.tap()
        XCTAssertTrue(element("gallery-detail").waitForExistence(timeout: 10))
        sleep(2)
        snap("2-result-detail")
        XCTAssertTrue(element("gallery-detail").exists)
        XCTAssertFalse(element("gallery-list").exists, "详情页被列表盖住")

        // 返回标签列表，在标签后追加条件（点按搜索框中间，光标也应在末尾）
        goBack()
        XCTAssertTrue(firstGallery.waitForExistence(timeout: 10))
        tapSearchButton()
        // 追加一个不影响结果的排除词（第一个标签可能是任意标签）
        app.searchFields.firstMatch.typeText(" -zzqqxx")
        snap("2-refining")
        app.searchFields.firstMatch.typeText("\n")
        XCTAssertTrue(app.navigationBars.buttons["快速搜索"].waitForExistence(timeout: 10))
        XCTAssertTrue(firstGallery.waitForExistence(timeout: 30))
        snap("2-refined")
        XCTAssertEqual(app.searchFields.firstMatch.value as? String, tagQuery + " -zzqqxx")
        XCTAssertTrue(app.buttons["重置条件"].exists, "条件栏应显示重置")

        firstGallery.tap()
        XCTAssertTrue(element("gallery-detail").waitForExistence(timeout: 10))
        sleep(2)
        snap("2-refined-detail")
        XCTAssertFalse(element("gallery-list").exists, "详情页被列表盖住")
    }

    // MARK: 问题 2：下载列表点击封面进入详情

    func testDownloadCoverOpensDetail() {
        XCTAssertTrue(firstGallery.waitForExistence(timeout: 30))
        firstGallery.press(forDuration: 1.2)
        // 长按菜单中的“下载”（标签栏也有同名按钮）
        let download = app.collectionViews.buttons["下载"]
        if download.waitForExistence(timeout: 3) {
            download.tap()
        } else {
            app.buttons["在下载中查看"].tap()
        }
        sleep(1)
        app.tabBars.buttons["下载"].tap()
        let row = app.buttons.matching(identifier: "download-item").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        snap("3-downloads")
        // 封面在行的左侧（84 × 120）
        row.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 30, dy: 50)).tap()
        XCTAssertTrue(element("gallery-detail").waitForExistence(timeout: 10))
        snap("3-cover-detail")
        goBack()
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        // 点击行的其他位置：阅读（未开始下载的项目为详情）
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.3)).tap()
        sleep(2)
        snap("3-row-tap")
    }

    // MARK: 搜索栏随滚动收起；翻到列表很后面时用导航栏的搜索按钮直接修改搜索词

    func testSearchButtonWhenScrolled() {
        XCTAssertTrue(firstGallery.waitForExistence(timeout: 30))
        snap("7-home-top")
        scrollFar()
        snap("7-home-scrolled")
        tapSearchButton()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        snap("7-home-search")
        field.typeText("chinese\n")
        XCTAssertTrue(app.navigationBars.buttons["快速搜索"].waitForExistence(timeout: 10))
        XCTAssertTrue(firstGallery.waitForExistence(timeout: 30))
        snap("7-submitted")
        XCTAssertTrue(app.buttons["重置条件"].isHittable, "新的搜索结果应从顶部开始")
        XCTAssertEqual(app.searchFields.firstMatch.value as? String, "chinese")

        // 翻到搜索结果很后面：搜索按钮打开的搜索栏显示当前搜索词
        scrollFar()
        snap("7-results-scrolled")
        tapSearchButton()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(app.searchFields.firstMatch.value as? String, "chinese")
        snap("7-results-search")
        // 取消：留在原来的位置，搜索不变
        cancelSearch()
        sleep(1)
        snap("7-results-cancelled")
        let reset = app.buttons["重置条件"]
        XCTAssertFalse(reset.exists && reset.isHittable, "取消后应留在原来的位置")
        XCTAssertTrue(app.navigationBars.buttons["快速搜索"].exists)

        // 再次打开，追加条件后提交
        tapSearchButton()
        app.searchFields.firstMatch.typeText(" -zzqqxx")
        snap("7-results-editing")
        app.searchFields.firstMatch.typeText("\n")
        XCTAssertTrue(app.navigationBars.buttons["快速搜索"].waitForExistence(timeout: 10))
        XCTAssertTrue(firstGallery.waitForExistence(timeout: 30))
        snap("7-refined")
        XCTAssertEqual(app.searchFields.firstMatch.value as? String, "chinese -zzqqxx")
        XCTAssertTrue(app.buttons["重置条件"].isHittable, "新的搜索结果应从顶部开始")

        // 收藏、下载、历史同样有搜索按钮
        for tab in ["收藏", "下载", "历史"] {
            app.tabBars.buttons[tab].tap()
            XCTAssertTrue(app.navigationBars.buttons["搜索"].waitForExistence(timeout: 5), "\(tab)页没有搜索按钮")
            snap("7-tab-\(tab)")
            app.navigationBars.buttons["搜索"].tap()
            XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5))
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "\(tab)页搜索按钮没有打开搜索栏")
            cancelSearch()
            sleep(1)
            XCTAssertFalse(app.keyboards.firstMatch.exists, "\(tab)页取消后搜索栏没有收起")
        }
    }

    // MARK: 下载列表按标签搜索：建议来自下载中的标签，点按填入，提交后保留搜索词

    func testDownloadSearchByTag() {
        XCTAssertTrue(firstGallery.waitForExistence(timeout: 30))
        app.tabBars.buttons["下载"].tap()
        let row = app.buttons.matching(identifier: "download-item").firstMatch
        if !row.waitForExistence(timeout: 5) {
            // 没有下载时先下载首页第一个画廊
            app.tabBars.buttons["浏览"].tap()
            firstGallery.press(forDuration: 1.2)
            app.collectionViews.buttons["下载"].tap()
            app.tabBars.buttons["下载"].tap()
            XCTAssertTrue(row.waitForExistence(timeout: 10))
        }
        sleep(5) // 缺少的标签通过 gdata 补齐

        let field = app.searchFields.firstMatch
        field.tap()
        field.typeText("a")
        let suggestion = app.buttons.matching(identifier: "download-tag-suggestion").firstMatch
        XCTAssertTrue(suggestion.waitForExistence(timeout: 10), "没有标签建议")
        snap("6-suggestions")
        suggestion.tap()
        sleep(1)
        let filled = app.searchFields.firstMatch.value as? String ?? ""
        XCTAssertTrue(filled.contains(":") || filled.hasPrefix("\""), "应填入标签语法：\(filled)")
        XCTAssertFalse(app.navigationBars.buttons["选择"].exists, "点标签建议不应提交")
        snap("6-filled")

        app.searchFields.firstMatch.typeText("\n")
        XCTAssertTrue(app.navigationBars.buttons["选择"].waitForExistence(timeout: 5), "提交后导航栏按钮应恢复")
        XCTAssertTrue(row.waitForExistence(timeout: 5), "按下载中出现过的标签搜索，结果不应为空")
        sleep(1)
        snap("6-submitted")
        XCTAssertEqual(app.searchFields.firstMatch.value as? String, filled.trimmingCharacters(in: .whitespaces))
        XCTAssertTrue(app.buttons["清除筛选"].exists)

        app.buttons["清除筛选"].tap()
        sleep(1)
        XCTAssertFalse(app.buttons["清除筛选"].exists)
        XCTAssertNotEqual(app.searchFields.firstMatch.value as? String, filled.trimmingCharacters(in: .whitespaces))
    }

    // MARK: 工具

    /// 当前页面的第一个画廊
    private var firstGallery: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "gallery-item").firstMatch
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// 开始搜索：搜索栏可见时点搜索栏，否则（列表已滚动、搜索栏收起）点导航栏的搜索按钮
    private func tapSearchButton() {
        let field = app.searchFields.firstMatch
        if field.exists, field.isHittable {
            field.tap()
        } else {
            let button = app.navigationBars.buttons["搜索"]
            XCTAssertTrue(button.waitForExistence(timeout: 5), "找不到搜索按钮")
            button.tap()
        }
    }

    /// 在当前画廊列表中快速向下翻很多屏（会触发加载后几页）
    private func scrollFar() {
        let list = element("gallery-list")
        for _ in 0..<8 { list.swipeUp(velocity: .fast) }
        sleep(1)
    }

    private func goBack() {
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    private func cancelSearch() {
        tapFirst(["取消", "Cancel", "关闭", "Close"])
    }

    private func tapFirst(_ titles: [String]) {
        for title in titles {
            let b = app.buttons[title].firstMatch
            if b.exists, b.isHittable {
                b.tap()
                return
            }
        }
        XCTFail("找不到按钮：\(titles)")
    }

    private func snap(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
