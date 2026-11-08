import XCTest
@testable import ClashDashKit

final class ProxyRoutePathTests: XCTestCase {
    func testDirectMemberAndNestedManualRoute() {
        let groups = [ProxyGroup(name: "Root", kind: "select", members: ["Auto", "Region"]),
                      ProxyGroup(name: "Region", kind: "Selector", members: ["Node1", "Node2"]),
                      ProxyGroup(name: "Auto", kind: "url-test", members: ["Node2"])]
        XCTAssertEqual(ProxySelection.manualPath(to: "Node2", from: "Root", groups: groups),
                       [.init(group: "Root", member: "Region"), .init(group: "Region", member: "Node2")])
        XCTAssertEqual(ProxySelection.manualPath(to: "Node1", from: "Region", groups: groups), [.init(group: "Region", member: "Node1")])
        XCTAssertNil(ProxySelection.manualPath(to: "Missing", from: "Root", groups: groups))
    }
    func testAutomaticGroupCannotPretendToPinNodeAndCyclesTerminate() {
        let groups = [ProxyGroup(name: "Root", kind: "select", members: ["Loop", "Auto"]),
                      ProxyGroup(name: "Loop", kind: "select", members: ["Root"]),
                      ProxyGroup(name: "Auto", kind: "url-test", members: ["Node"])]
        XCTAssertNil(ProxySelection.manualPath(to: "Node", from: "Root", groups: groups))
        XCTAssertNil(ProxySelection.manualPath(to: "Node", from: "Auto", groups: groups))
    }
    func testCurrentManualBranchPreferredAndGlobalIsExplicit() {
        let groups = [ProxyGroup(name: "Root", kind: "select", members: ["A", "B"], selected: "B"),
                      ProxyGroup(name: "A", kind: "select", members: ["Node"]),
                      ProxyGroup(name: "B", kind: "select", members: ["Node"]),
                      ProxyGroup(name: "GLOBAL", kind: "select", members: ["Node", "Root"])]
        XCTAssertEqual(ProxySelection.manualPath(to: "Node", from: "Root", groups: groups)?.first?.member, "B")
        XCTAssertEqual(ProxySelection.manualPath(to: "Node", from: "GLOBAL", groups: groups), [.init(group: "GLOBAL", member: "Node")])
    }
}
