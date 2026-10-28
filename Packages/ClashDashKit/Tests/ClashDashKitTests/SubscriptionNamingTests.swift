import XCTest
@testable import ClashDashKit

final class SubscriptionNamingTests: XCTestCase {
    func testCustomNameWinsAndBlankUsesRelatedSourceWithoutCredentials() {
        let url = URL(string: "https://sub.example.com/path?token=test-secret")!
        XCTAssertEqual(SubscriptionNaming.resolve(input: "  我的出差线路  ", suggested: "Provider", sourceURL: url), "我的出差线路")
        XCTAssertEqual(SubscriptionNaming.resolve(sourceURL: url), "sub.example.com")
        XCTAssertEqual(SubscriptionNaming.resolve(input: " \n", suggested: "提供商名称", sourceURL: url), "提供商名称")
    }
    func testNamesAreUniqueAndHeaderTitleCanBeDecoded() {
        XCTAssertEqual(SubscriptionNaming.resolve(input: "My Name", existing: ["my name", "My Name (2)"]), "My Name (3)")
        let title = "base64:" + Data("出行订阅".utf8).base64EncodedString()
        XCTAssertEqual(SubscriptionNaming.resolve(suggested: title), "出行订阅")
        XCTAssertEqual(SubscriptionNaming.resolve(suggested: "base64:invalid", fallback: "我的节点"), "我的节点")
        XCTAssertEqual(SubscriptionNaming.resolve(input: "  A\nB\tC  "), "A B C")
        XCTAssertEqual(SubscriptionNaming.resolve(input: String(repeating: "名", count: 200)).count, 80)
    }
}
