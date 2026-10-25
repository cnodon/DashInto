import XCTest

final class PhysicalReleaseTests: XCTestCase {
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
    private func waitLabel(_ element: XCUIElement, _ label: String, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == true AND label == %@", label)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
