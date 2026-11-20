import XCTest
import UIKit

/// README 的功能截图，不是回归测试，默认跳过。生成方法见 scripts/readme-shots.sh。
///
/// 截图中不能出现成人内容：只打开非 H（Non-H）分类中的风景类画廊，浏览页的列表也限定为 Non-H 分类。
/// 阅读与下载会消耗少量图片额度，下载演示用 8 页的画廊；纵向阅读与阅读设置读取下载好的这本，不再消耗额度。
///
/// - 测试按名称顺序运行，后面的截图用到前面的下载
/// - testPad… 只在 iPad 上运行，其余只在 iPhone 上运行
/// - 布局、主题、阅读方向用启动参数临时覆盖（如 `-list_mode 1`），不改动保存的设置
final class ReadmeScreenshots: XCTestCase {
    /// Non-H 分类的 landscape 搜索结果（f_cats 是排除的分类：全部 1023 减去 Non-H 256）
    private let listURL = "https://e-hentai.org/?f_cats=767&f_search=landscape"
    /// 风景画集（Non-H）：详情页与阅读器
    private let detailURL = "https://e-hentai.org/g/2463208/f39d140ec6/"
    /// 风景图（Non-H，8 页）：下载列表、纵向阅读、阅读设置
    private let downloadURL = "https://e-hentai.org/g/3316027/8c4fbe8822/"

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["README_SHOTS"] == "1",
                          "README 截图：设置环境变量 TEST_RUNNER_README_SHOTS=1 时才运行")
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        try XCTSkipIf(name.contains("testPad") != isPad, isPad ? "iPhone 截图" : "iPad 截图")
        continueAfterFailure = false
        addUIInterruptionMonitor(withDescription: "系统弹窗") { alert in
            for title in ["允许", "Allow", "好", "OK"] where alert.buttons[title].exists {
                alert.buttons[title].tap()
                return true
            }
            return false
        }
    }

    private func launch(_ args: String...) {
        app = XCUIApplication()
        app.launchArguments = args
        app.launch()
    }

    // MARK: 浏览、搜索建议

    func test01Browse() {
        launch("-EHOpenURL", listURL)
        XCTAssertTrue(firstGallery.waitForExistence(timeout: 30))
        sleep(10) // 等缩略图
        shot("01-browse")

        // 标签建议（中文翻译）：清空搜索框后输入
        tapSearchButton()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 12))
        field.typeText("love live")
        let translated = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'LoveLive'")).firstMatch
        _ = translated.waitForExistence(timeout: 20)
        sleep(1)
        shot("02-search")
    }

    // MARK: 详情、阅读器

    func test02Detail() {
        launch("-EHOpenURL", detailURL)
        waitForDetail()
        shot("03-detail")
        element("gallery-detail").swipeUp(velocity: .slow)
        sleep(4) // 等预览图
        shot("04-detail-more")
    }

    func test03Reader() {
        launch("-EHOpenURL", detailURL)
        openReader()
        setReaderChrome(visible: true)
        shot("05-reader")
    }

    // MARK: 下载

    func test04Downloads() {
        // 8 页的风景图：下载完成
        launch("-EHOpenURL", downloadURL, "-EHStartDownload", "YES")
        allowNotifications() // 第一次开始下载时请求通知权限
        XCTAssertTrue(element("gallery-detail").waitForExistence(timeout: 30))
        app.tabBars.buttons["下载"].tap()
        let row = app.buttons.matching(identifier: "download-item").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        sleep(3)
        shot("06-downloads-progress")
        let done = app.staticTexts["已完成"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 120), "下载没有完成")

        // 画集（147 页）：下载几页后暂停，展示进行中的状态
        launch("-EHOpenURL", detailURL, "-EHStartDownload", "YES")
        XCTAssertTrue(element("gallery-detail").waitForExistence(timeout: 30))
        app.tabBars.buttons["下载"].tap()
        let pause = app.buttons["暂停"].firstMatch
        XCTAssertTrue(pause.waitForExistence(timeout: 30))
        sleep(4)
        pause.tap()
        sleep(2)
        shot("07-downloads")
    }

    // MARK: 我的、设置、互传

    func test05Me() {
        launch("-EHInitialTab", "me")
        sleep(3)
        shot("08-me")
    }

    func test06Network() {
        launch("-EHDebugRoute", "settings:network")
        sleep(3)
        shot("09-network")
    }

    func test07Transfer() {
        launch("-EHDebugRoute", "transfer")
        sleep(3)
        shot("10-transfer")
    }

    // MARK: 网格、长按菜单、深色模式

    func test08Grid() {
        launch("-EHOpenURL", listURL, "-list_mode", "1")
        XCTAssertTrue(firstGallery.waitForExistence(timeout: 30))
        sleep(10) // 等缩略图
        shot("11-grid")
    }

    func test09ContextMenu() {
        launch("-EHOpenURL", listURL)
        XCTAssertTrue(firstGallery.waitForExistence(timeout: 30))
        sleep(8) // 等缩略图
        firstGallery.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["阅读"].waitForExistence(timeout: 10), "没有出现长按菜单")
        sleep(2) // 等菜单动画
        shot("12-context-menu")
    }

    func test10Dark() {
        launch("-EHOpenURL", detailURL, "-theme", "1")
        waitForDetail()
        shot("13-dark")
    }

    // MARK: 纵向阅读、阅读设置（读取 test04 下载好的画廊）

    func test11VerticalReader() {
        launch("-EHOpenURL", downloadURL, "-reading_direction", "2")
        openReader()
        hideReaderClock()
        setReaderChrome(visible: false)
        shot("14-vertical")
    }

    func test12ReaderSettings() {
        launch("-EHOpenURL", downloadURL)
        openReader()
        setReaderChrome(visible: true)
        app.buttons["设置"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["阅读设置"].waitForExistence(timeout: 5))
        sleep(2)
        shot("15-reader-settings")
    }

    /// 下载设置：其中有“切到后台后继续下载”（iOS 26+）
    func test13DownloadSettings() {
        launch("-EHDebugRoute", "settings:download")
        let toggle = app.switches["切到后台后继续下载"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        if !toggle.isHittable { app.swipeUp(velocity: .slow) }
        sleep(2)
        shot("16-download-settings")
    }

    // MARK: iPad（横屏）

    func testPadBrowse() {
        XCUIDevice.shared.orientation = .landscapeLeft
        launch("-EHOpenURL", listURL, "-list_mode", "1")
        XCTAssertTrue(firstGallery.waitForExistence(timeout: 30))
        sleep(12) // 等缩略图
        shot("pad-browse")
    }

    func testPadDetail() {
        XCUIDevice.shared.orientation = .landscapeLeft
        launch("-EHOpenURL", detailURL)
        waitForDetail()
        shot("pad-detail")
    }

    // MARK: 工具

    private var firstGallery: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "gallery-item").firstMatch
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// 等详情页的标签与封面加载完
    private func waitForDetail() {
        XCTAssertTrue(element("gallery-detail").waitForExistence(timeout: 30))
        let tag = app.buttons.matching(NSPredicate(format: "label CONTAINS '：'")).firstMatch
        XCTAssertTrue(tag.waitForExistence(timeout: 30))
        sleep(5) // 等封面
    }

    /// 在详情页点“阅读”，关闭第一次打开时的操作提示
    private func openReader() {
        XCTAssertTrue(element("gallery-detail").waitForExistence(timeout: 30))
        let read = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '阅读' OR label BEGINSWITH '继续阅读'")).firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 30))
        read.tap()
        sleep(10) // 等第一页
        if app.staticTexts["轻点任意处开始阅读"].exists {
            app.tap()
            sleep(1)
        }
    }

    /// 轻点中间显示或隐藏工具栏（“更多”按钮在工具栏上）
    private func setReaderChrome(visible: Bool) {
        let more = app.buttons["更多"].firstMatch
        if (more.exists && more.isHittable) != visible {
            app.tap()
            sleep(2)
        }
    }

    /// 隐藏工具栏时，阅读器角落显示真实时间，与状态栏固定的 9:41 不一致：在阅读设置中关闭“显示时间”（保存在模拟器中）
    private func hideReaderClock() {
        setReaderChrome(visible: true)
        app.buttons["设置"].firstMatch.tap()
        let bar = app.navigationBars["阅读设置"]
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        let toggle = app.switches["显示时间"].firstMatch
        // 从面板下部往上拖：先把面板拉到全高，再滚动列表
        for _ in 0..<6 where !(toggle.exists && toggle.isHittable) {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)))
            sleep(1)
        }
        XCTAssertTrue(toggle.isHittable, "找不到“显示时间”")
        if toggle.value as? String == "1" {
            // 开关在行的右端，点行的中间不会切换
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
            sleep(1)
        }
        XCTAssertEqual(toggle.value as? String, "0", "没能关闭“显示时间”")
        bar.buttons["完成"].tap()
        sleep(1)
    }

    /// 点按系统权限弹窗中的“允许”
    private func allowNotifications() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons.matching(NSPredicate(format: "label IN {'允许', 'Allow'}")).firstMatch
        if allow.waitForExistence(timeout: 15) { allow.tap() }
    }

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

    private func shot(_ name: String) {
        // 横屏时截图的像素按竖屏方向保存、靠方向标记显示，导出后会转错方向：重绘成正向的图片
        let image = XCUIScreen.main.screenshot().image
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        let upright = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in image.draw(at: .zero) }
        let a = XCTAttachment(image: upright)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
