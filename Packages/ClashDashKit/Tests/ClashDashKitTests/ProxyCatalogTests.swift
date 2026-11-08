import XCTest
@testable import ClashDashKit

final class ProxyCatalogTests: XCTestCase {
    func testLatencySortKeepsFailuresAndUnknownLastAndTiesStable() {
        let names = ["Unknown", "Slow", "Timeout", "Tie B", "Zero", "Failed", "Tie A", "Fast"]
        let delays = ["Slow": 900, "Timeout": -1, "Failed": -2, "Tie A": 120, "Tie B": 120, "Fast": 30, "Zero": 0]
        XCTAssertEqual(ProxyNodeSortOrder.latency.sorted(names, delays: delays),
                       ["Zero", "Fast", "Tie B", "Tie A", "Slow", "Unknown", "Timeout", "Failed"])
        XCTAssertEqual(ProxyNodeSortOrder.configuration.sorted(names, delays: delays), names)
        XCTAssertEqual(ProxyNodeSortOrder.latency.sorted(names, delays: [:]), names)
    }
    func testLatencySortUsesNewResultsWithoutDroppingNodes() {
        let names = ["A", "B", "C"]
        XCTAssertEqual(ProxyNodeSortOrder.latency.sorted(names, delays: ["B": 80]), ["B", "A", "C"])
        XCTAssertEqual(ProxyNodeSortOrder.latency.sorted(names, delays: ["B": 80, "C": 20]), ["C", "B", "A"])
        XCTAssertEqual(ProxyNodeSortOrder.latency.sorted(names, delays: ["B": -1, "C": 20]), ["C", "A", "B"])
    }
    func testNestedGroupBatchExpandsUniqueNodesAndSkipsActionsAndCycles() {
        let nodes = [ProxyNode(name: "A", kind: "ss"), ProxyNode(name: "B", kind: "vless")]
        let groups = [ProxyGroup(name: "Outer", kind: "select", members: ["Inner", "B", "DIRECT", "PASS-RULE", "Unknown"]),
                      ProxyGroup(name: "Inner", kind: "url-test", members: ["A", "Outer", "Dynamic"])]
        XCTAssertEqual(ProxySelection.delayTargets(["Outer", "Inner", "A"], nodes: nodes, groups: groups,
            runtimeKinds: ["Dynamic": "AnyTLS", "PASS-RULE": "PassRule"]), ["A", "Dynamic", "B"])
        XCTAssertTrue(ProxySelection.delayTargets(["DIRECT", "PASS-RULE"], nodes: nodes, groups: groups, runtimeKinds: [:]).isEmpty)
    }
    func testCorePassRuleAndLocalActionsNeverBecomeRemoteNodes() {
        let nodes = [ProxyNode(name: "Actual", kind: "vless")]
        let groups = [ProxyGroup(name: "Select", kind: "select", members: ["Actual"])]
        let runtime = ["Actual": "Vless", "PASS-RULE": "PassRule", "Custom pass": "pass-rule",
                       "Custom direct": "Direct", "DIRECT": "Direct", "REJECT": "Reject",
                       "Custom DNS": "DNS", "Select": "Selector", "Provider-only": "Trojan"]
        XCTAssertEqual(ProxySelection.testableNames(nodes: nodes, groups: groups, runtimeKinds: runtime), ["Actual", "Provider-only"])
        XCTAssertEqual(ProxySelection.testableNames(nodes: nodes, groups: groups, runtimeKinds: [:]), ["Actual"])
    }
}
