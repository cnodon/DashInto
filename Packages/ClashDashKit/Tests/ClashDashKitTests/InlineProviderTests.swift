import XCTest
@testable import ClashDashKit

final class InlineProviderTests: XCTestCase {
    private func configuration(inline: Int, remote: Int) -> String {
        let local = (0..<inline).map { "i\($0): {type: inline, behavior: domain, payload: ['example.invalid']}" }
        let network = (0..<remote).map { "r\($0): {type: http, behavior: domain, url: 'https://example.invalid/r\($0).yaml'}" }
        return "rule-providers: {" + (local + network).joined(separator: ", ") + "}\nrules: ['MATCH,DIRECT']"
    }
    func testTwentyInlineRuleSetsAreNotRemoteDownloads() throws {
        let result = try ConfigurationParser.prepare(configuration(inline: 20, remote: 0))
        XCTAssertEqual(result.summary.inlineResourceCount, 20)
        XCTAssertEqual(result.summary.remoteResourceCount, 0)
        XCTAssertTrue(result.resourceRequests.isEmpty)
        XCTAssertTrue(result.runtime.contains("inline"))
        XCTAssertFalse(result.summary.warnings.contains { $0.contains("远程节点和规则资源") })
    }
    func testRemoteLimitStillAppliesSeparately() throws {
        let result = try ConfigurationParser.prepare(configuration(inline: 20, remote: 16))
        XCTAssertEqual(result.resourceRequests.count, 16)
        XCTAssertEqual(result.summary.inlineResourceCount, 20)
        XCTAssertThrowsError(try ConfigurationParser.prepare(configuration(inline: 1, remote: 17)))
        XCTAssertThrowsError(try ConfigurationParser.prepare(configuration(inline: 257, remote: 0)))
    }
}
