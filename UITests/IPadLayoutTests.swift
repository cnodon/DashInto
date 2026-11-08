import XCTest
import UIKit

final class IPadLayoutTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad layout coverage")
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    private func launch(_ arguments: [String] = []) -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-library=" + UUID().uuidString] + arguments
        app.launch()
        return app
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testSidebarDestinationsImportAndRotationPreserveNavigation() {
        let app = launch()
        XCTAssertTrue(app.buttons["sidebar-0"].waitForExistence(timeout: 10))
        for index in 0...4 { XCTAssertTrue(app.buttons["sidebar-\(index)"].isHittable) }
        XCTAssertTrue(app.buttons["connectionButton"].isHittable)
        XCTAssertFalse(app.tabBars.firstMatch.isHittable)
        // iPadOS 18+ exposes the floating tab strip as buttons, not a TabBar.
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", "首页")).count, 1, "Sidebar must replace the system tab strip")
        capture(app, "iPadEmptyLandscape")
        app.buttons["sidebar-1"].tap()
        XCTAssertTrue(app.staticTexts["暂无订阅"].waitForExistence(timeout: 5))
        app.buttons["添加订阅"].tap()
        XCTAssertTrue(app.textFields["subscriptionURL"].waitForExistence(timeout: 5))
        app.buttons["取消"].tap()
        app.buttons["sidebar-3"].tap()
        XCTAssertTrue(app.staticTexts["设备类型"].waitForExistence(timeout: 5))
        capture(app, "iPadDeviceLandscape")
        app.buttons["sidebar-4"].tap()
        app.buttons["softwareUpdate"].tap()
        XCTAssertTrue(app.buttons["checkAppUpdate"].waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.buttons["sidebar-0"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["checkAppUpdate"].isHittable, "Rotation must preserve the pushed detail")
        capture(app, "iPadPortraitUpdate")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["sidebar-0"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["checkAppUpdate"].isHittable)
        app.buttons["sidebar-0"].tap()
        XCTAssertTrue(app.buttons["connectionButton"].isHittable)
    }

    func testProxySearchAndResultsSurviveRotation() {
        let app = launch(["--ui-test-delay-results"])
        XCTAssertTrue(app.buttons["showDelayResults"].waitForExistence(timeout: 12))
        let search = app.textFields["proxySearch"]
        search.tap(); search.typeText("示例可用")
        XCTAssertTrue(app.buttons["chooseProxy-示例可用"].exists)
        XCTAssertFalse(app.buttons["chooseProxy-示例失败"].exists)
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.buttons["sidebar-0"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(search.value as? String, "示例可用")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["sidebar-0"].waitForExistence(timeout: 5))
        XCTAssertEqual(search.value as? String, "示例可用")
        app.buttons["showDelayResults"].tap()
        XCTAssertTrue(app.navigationBars["测速结果"].waitForExistence(timeout: 5))
        capture(app, "iPadDelayResults")
        app.buttons["完成"].tap()
        XCTAssertTrue(app.buttons["chooseProxy-示例可用"].exists)
    }

    func testAccessibilityTextUsesSingleColumn() {
        let app = launch(["--ui-test-dashboard-preview", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        XCTAssertTrue(app.staticTexts["界面预览 · 示例数据"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["sidebar-0"].exists)
        let route = app.staticTexts["日本 · Tokyo 01"]
        let traffic = app.otherElements["liveTrafficCard"]
        XCTAssertGreaterThan(traffic.frame.minY, route.frame.maxY)
        capture(app, "iPadAccessibilityText")
    }

    func testConnectedDashboardUsesColumnsOnlyWhenSpaceAllows() {
        let app = launch(["--ui-test-dashboard-preview"])
        XCTAssertTrue(app.staticTexts["界面预览 · 示例数据"].waitForExistence(timeout: 8))
        let route = app.staticTexts["日本 · Tokyo 01"]
        let traffic = app.otherElements["liveTrafficCard"]
        XCTAssertTrue(route.exists); XCTAssertTrue(traffic.exists)
        XCTAssertGreaterThan(traffic.frame.minX, route.frame.midX)
        XCTAssertTrue(app.buttons["egressAddress"].isHittable)
        capture(app, "iPadDashboardLandscape")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.buttons["sidebar-0"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["egressAddress"].isHittable)
        capture(app, "iPadDashboardPortrait")
        app.terminate()
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launchArguments += ["-appearance", "dark"]
        app.launch()
        XCTAssertTrue(app.buttons["egressAddress"].waitForExistence(timeout: 8))
        capture(app, "iPadDashboardDark")
    }
}
