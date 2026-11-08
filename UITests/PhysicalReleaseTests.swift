import XCTest

final class PhysicalReleaseTests: XCTestCase {
    func testApprovedSubscriptionImportRefreshConnectAndDelay() throws {
        guard ProcessInfo.processInfo.environment["CLASHDASH_PHYSICAL_RELEASE"] == "1",
              let address = ProcessInfo.processInfo.environment["CLASHDASH_TEST_SUBSCRIPTION_URL"] else {
            throw XCTSkip("Explicit user-authorized private subscription run only")
        }
        let name = ProcessInfo.processInfo.environment["CLASHDASH_TEST_SUBSCRIPTION_NAME"] ?? "测试订阅"
        let app = XCUIApplication(bundleIdentifier: "app.clashdash.ios"); app.activate()
        app.tabBars.buttons["订阅"].tap()
        if !app.buttons["profileDetail-" + name].exists {
            app.buttons["添加订阅"].tap()
            let field = app.textFields["profileName"]
            field.tap(); field.typeText(name + "\n")
            let source = app.textFields["subscriptionURL"]
            source.tap(); source.typeText(address + "\n")
            app.buttons["readSubscription"].tap()
            if address.hasPrefix("http://") {
                let alert = app.alerts["使用未加密的订阅？"]
                XCTAssertTrue(alert.waitForExistence(timeout: 5))
                alert.buttons["继续导入"].tap()
            }
            let save = app.buttons["saveProfile"]
            XCTAssertTrue(save.waitForExistence(timeout: 150), "Download, resource preparation and core validation must reach preview")
            XCTAssertEqual(app.textFields["profileName"].value as? String, name)
            save.tap()
        }
        let detail = app.buttons["profileDetail-" + name]
        XCTAssertTrue(detail.waitForExistence(timeout: 15))
        detail.tap()
        let refresh = app.buttons["更新订阅"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 5)); refresh.tap()
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: refresh)], timeout: 90) == .completed)
        XCTAssertFalse(app.alerts["操作未完成"].exists, "Refreshing an approved HTTP subscription must also work")
        let use = app.buttons.matching(NSPredicate(format: "label == '使用并连接' OR label == '切换并重连'")).firstMatch
        XCTAssertTrue(use.exists); use.tap()
        let status = app.staticTexts["connectionStatus"]
        XCTAssertTrue(waitLabel(status, "已连接", timeout: 100), "VPN plus real network checks must complete")
        defer {
            if app.state == .runningForeground {
                app.tabBars.buttons["首页"].tap()
                let disconnect = app.buttons["connectionButton"]
                for _ in 0..<4 where !disconnect.isHittable { app.swipeDown() }
                if disconnect.label == "断开连接" { disconnect.tap() }
            }
        }
        XCTAssertTrue(app.buttons["homeSubscription"].label.contains(name))
        app.tabBars.buttons["代理"].tap()
        let all = app.buttons["testAllProxies"]
        XCTAssertTrue(all.waitForExistence(timeout: 15)); XCTAssertTrue(all.isEnabled); all.tap()
        let summary = app.staticTexts["delayTestSummary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 120), "Real batch must finish")
        XCTAssertFalse(summary.label.contains("0 / 0"))
        XCTAssertEqual(app.state, .runningForeground)
        app.tabBars.buttons["首页"].tap()
        let sites = app.buttons["refreshWebsites"]
        for _ in 0..<4 where !sites.isHittable { app.swipeUp() }
        XCTAssertTrue(sites.waitForExistence(timeout: 5))
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: sites)], timeout: 30) == .completed)
        for site in ["Google", "YouTube", "OpenAI", "Claude"] { XCTAssertTrue(app.buttons["website-" + site].isEnabled) }
    }
    func testExistingSubscriptionConnectsAndDisconnects() throws {
        guard ProcessInfo.processInfo.environment["CLASHDASH_PHYSICAL_RELEASE"] == "1" else {
            throw XCTSkip("Explicit physical Release run only; preserves the existing user library")
        }
        let app = XCUIApplication(bundleIdentifier: "app.clashdash.ios"); app.activate()
        XCTAssertTrue(app.buttons["connectionButton"].waitForExistence(timeout: 15))
        let button = app.buttons["connectionButton"]
        if button.label == "断开连接" {
            button.tap()
            XCTAssertTrue(waitLabel(button, "连接", timeout: 20))
        }
        XCTAssertTrue(["连接", "重新连接"].contains(button.label))
        button.tap()
        let status = app.staticTexts["connectionStatus"]
        XCTAssertTrue(waitLabel(status, "已连接", timeout: 90), "Release must establish VPN and pass both network probes")
        XCTAssertEqual(button.label, "断开连接")
        let refresh = app.buttons["refreshWebsites"]
        for _ in 0..<3 where !refresh.isHittable { app.swipeUp() }
        XCTAssertTrue(refresh.waitForExistence(timeout: 5))
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: refresh)], timeout: 25) == .completed)
        for name in ["Google", "YouTube", "OpenAI", "Claude"] {
            let site = app.buttons["website-" + name]
            XCTAssertTrue(site.exists)
            XCTAssertTrue(site.isEnabled, "Each request must produce a real terminal result, including restricted or timeout")
        }
        XCTAssertTrue(app.buttons["egressAddress"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "PhysicalReleaseConnected040"; shot.lifetime = .keepAlways; add(shot)
        app.tabBars.buttons["代理"].tap()
        XCTAssertTrue(app.textFields["proxySearch"].waitForExistence(timeout: 5))
        app.tabBars.buttons["首页"].tap()
        XCTAssertTrue(app.buttons["connectionButton"].waitForExistence(timeout: 5))
        for _ in 0..<3 where !button.isHittable { app.swipeDown() }
        app.buttons["connectionButton"].tap()
        XCTAssertTrue(waitLabel(status, "未连接", timeout: 20))
        XCTAssertEqual(app.buttons["connectionButton"].label, "连接")
    }
    func testBatchDelayOnInstalledRelease() throws {
        guard ProcessInfo.processInfo.environment["CLASHDASH_PHYSICAL_RELEASE"] == "1" else { throw XCTSkip("Explicit physical Release run only") }
        let app = XCUIApplication(bundleIdentifier: "app.clashdash.ios"); app.activate()
        app.tabBars.buttons["首页"].tap()
        let connect = app.buttons["connectionButton"]
        XCTAssertTrue(connect.waitForExistence(timeout: 15))
        for _ in 0..<3 where !connect.isHittable { app.swipeDown() }
        if ["连接", "重新连接"].contains(connect.label) {
            connect.tap()
            XCTAssertTrue(waitLabel(app.staticTexts["connectionStatus"], "已连接", timeout: 90))
        }
        XCTAssertEqual(connect.label, "断开连接")
        defer {
            if app.state == .runningForeground {
                app.tabBars.buttons["首页"].tap()
                let button = app.buttons["connectionButton"]
                for _ in 0..<3 where !button.isHittable { app.swipeDown() }
                if button.label == "断开连接" { button.tap() }
            }
        }
        app.tabBars.buttons["代理"].tap()
        let all = app.buttons["testAllProxies"]
        XCTAssertTrue(all.waitForExistence(timeout: 10))
        XCTAssertTrue(all.isEnabled)
        all.tap()
        let summary = app.staticTexts["delayTestSummary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 240), "Release batch must finish without terminating the app")
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(summary.label.hasPrefix("已完成 "))
        XCTAssertFalse(summary.label.contains("0 / 0"))
        let firstSummary = summary.label
        all.tap()
        XCTAssertTrue(summary.waitForExistence(timeout: 240))
        XCTAssertEqual(summary.label, firstSummary)
        XCTAssertEqual(app.state, .runningForeground)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "PhysicalBatchDelay043"; shot.lifetime = .keepAlways; add(shot)
    }
    private func waitLabel(_ element: XCUIElement, _ label: String, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == true AND label == %@", label)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
