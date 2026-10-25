import XCTest

final class ClashDashUITests: XCTestCase {
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-library=" + UUID().uuidString]
        app.launch(); return app
    }
    private func preview(_ app: XCUIApplication, name: String, nodes: Int = 1) {
        app.tabBars.buttons["订阅"].tap()
        app.buttons["添加订阅"].firstMatch.tap()
        app.buttons["粘贴节点或配置"].tap()
        let editor = app.textViews["nodeContent"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.tap()
        let content = (1...nodes).map { "ss://YWVzLTEyOC1nY206dGVzdA@127.0.0.1:\(19870 + $0)#Route\($0)" }.joined(separator: "\n")
        editor.typeText(content)
        app.buttons["readPastedContent"].tap()
        let field = app.textFields["profileName"]
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        field.tap(); field.press(forDuration: 1.1)
        if app.menuItems["全选"].waitForExistence(timeout: 1) { app.menuItems["全选"].tap() }
        else { field.tap(withNumberOfTaps: 3, numberOfTouches: 1) }
        // Clear the full default name regardless of keyboard language.
        let old = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count) + name + "\n")
        XCTAssertTrue(app.buttons["useAndConnect"].isHittable)
        XCTAssertTrue(app.buttons["saveProfile"].isHittable)
    }
    func testFiveTabsEmptySubscriptionAndUpdateEntry() {
        let app = launch()
        for title in ["首页", "订阅", "代理", "本机信息", "设置"] { XCTAssertTrue(app.tabBars.buttons[title].exists) }
        XCTAssertFalse(app.navigationBars["连接"].exists)
        app.tabBars.buttons["订阅"].tap()
        XCTAssertTrue(app.staticTexts["暂无订阅"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "添加订阅").count, 1)
        XCTAssertFalse(app.staticTexts["已验证订阅"].exists)
        app.tabBars.buttons["本机信息"].tap()
        XCTAssertTrue(app.staticTexts["设备类型"].waitForExistence(timeout: 5))
        app.tabBars.buttons["设置"].tap()
        app.buttons["softwareUpdate"].tap()
        XCTAssertTrue(app.buttons["checkAppUpdate"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["updateRepository"].value as? String, "cnodon/DashInto")
        XCTAssertTrue(app.navigationBars["软件更新"].exists)
    }
    func testImportUseConnectAndOfflineRoutePersistence() {
        let app = launch()
        preview(app, name: "First", nodes: 2)
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "ImportPreview040"; attachment.lifetime = .keepAlways; add(attachment)
        app.buttons["useAndConnect"].tap()
        XCTAssertTrue(app.buttons["connectionButton"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["First"].waitForExistence(timeout: 8))
        // Simulator must show an actionable platform limitation, never fake VPN success.
        XCTAssertTrue(app.staticTexts["connectionStatus"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.staticTexts["connectionStatus"].label, "连接未完成")
        XCTAssertFalse(app.alerts.firstMatch.exists)
        app.tabBars.buttons["代理"].tap()
        app.buttons["routeGroup-节点选择"].tap()
        app.buttons.containing(.staticText, identifier: "Route2").firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Route2"].firstMatch.waitForExistence(timeout: 3))
        app.terminate(); app.launch()
        app.tabBars.buttons["代理"].tap()
        XCTAssertTrue(app.staticTexts["Route2"].waitForExistence(timeout: 8))
        let selected = XCTAttachment(screenshot: app.screenshot()); selected.name = "OfflineRoute040"; selected.lifetime = .keepAlways; add(selected)
    }
    func testSaveOnlyKeepsSelectionAndExactSecondImportConnects() {
        let app = launch()
        preview(app, name: "First")
        app.buttons["useAndConnect"].tap()
        XCTAssertTrue(app.staticTexts["First"].waitForExistence(timeout: 8))
        preview(app, name: "Second")
        app.buttons["saveProfile"].tap()
        XCTAssertTrue(app.buttons["saveProfile"].waitForNonExistence(timeout: 8))
        app.tabBars.buttons["首页"].tap()
        XCTAssertTrue(app.buttons["connectionButton"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["First"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Second"].exists)
        app.tabBars.buttons["订阅"].tap()
        XCTAssertTrue(app.buttons["saveProfile"].waitForNonExistence(timeout: 8))
        let use = app.buttons["useProfile-Second"]
        for _ in 0..<4 where !use.isHittable { app.swipeUp() }
        use.tap()
        XCTAssertTrue(app.buttons["connectionButton"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Second"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts["First"].exists)
    }
    func testFirstSaveOnlyDoesNotSelectAndInvalidURLKeepsInput() {
        let app = launch()
        preview(app, name: "Saved")
        app.buttons["saveProfile"].tap()
        XCTAssertTrue(app.buttons["saveProfile"].waitForNonExistence(timeout: 8))
        app.tabBars.buttons["首页"].tap()
        XCTAssertTrue(app.buttons["connectionButton"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.buttons["connectionButton"].label, "选择订阅")
        XCTAssertFalse(app.staticTexts["Saved"].exists)
        app.tabBars.buttons["订阅"].tap(); app.buttons["添加订阅"].firstMatch.tap()
        let field = app.textFields["subscriptionURL"]
        field.tap(); field.typeText("http://example.com/sub")
        app.buttons["readSubscription"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "HTTPS")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "http://example.com/sub")
        app.buttons["取消"].tap()
        XCTAssertTrue(app.staticTexts["Saved"].waitForExistence(timeout: 5))
    }
}
