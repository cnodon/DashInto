import XCTest
@testable import ClashDashKit

@MainActor final class DelayTestRunnerTests: XCTestCase {
    private func settle(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Delay test did not settle")
    }
    func testImmediateResultsAcrossRepeatedBatches() async throws {
        let runner = DelayTestRunner()
        let names = (0..<40).map(String.init)
        for _ in 0..<30 {
            var received: [String: Int] = [:]
            runner.start(names: names, isCurrent: { true }, test: { _ in 7 }, receive: { received[$0] = $1 })
            try await settle { !runner.isRunning }
            XCTAssertEqual(received.count, 40)
            XCTAssertEqual(runner.completed, 40)
            XCTAssertNotNil(runner.finishedAt)
        }
    }
    func testEveryUniqueNodeGetsResultWithAtMostThreeConcurrentTests() async throws {
        let runner = DelayTestRunner()
        var active = 0, peak = 0, received: [String: Int] = [:]
        let names = (0..<10).map(String.init) + ["1", "2"]
        runner.start(names: names, isCurrent: { true }, test: { name in
            active += 1; peak = max(peak, active)
            defer { active -= 1 }
            try await Task.sleep(for: .milliseconds(2))
            if name == "4" { throw DashError.message("test failure") }
            return name == "7" ? -1 : 42
        }, receive: { received[$0] = $1 })
        try await settle { !runner.isRunning }
        XCTAssertEqual(received.count, 10)
        XCTAssertEqual(runner.completed, 10)
        XCTAssertEqual(runner.total, 10)
        XCTAssertLessThanOrEqual(peak, 3)
        XCTAssertEqual(received["4"], -2)
        XCTAssertEqual(received["7"], -1)
        XCTAssertNotNil(runner.finishedAt)
    }
    func testCancelAndRestartIgnoreLateResultsFromPreviousRun() async throws {
        let runner = DelayTestRunner()
        var oldReply: CheckedContinuation<Int, Never>?
        var newReply: CheckedContinuation<Int, Never>?
        var received: [String] = []
        runner.start(names: ["old"], isCurrent: { true }, test: { _ in
            await withCheckedContinuation { oldReply = $0 }
        }, receive: { name, _ in received.append(name) })
        try await settle { oldReply != nil }
        runner.cancel()
        runner.start(names: ["new"], isCurrent: { true }, test: { _ in
            await withCheckedContinuation { newReply = $0 }
        }, receive: { name, _ in received.append(name) })
        try await settle { newReply != nil }
        oldReply?.resume(returning: 1)
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertTrue(runner.isRunning)
        XCTAssertTrue(received.isEmpty)
        newReply?.resume(returning: 2)
        try await settle { !runner.isRunning }
        XCTAssertEqual(received, ["new"])
        XCTAssertEqual(runner.completed, 1)
    }
    func testChangedSessionDiscardsResultsAndStopsQueue() async throws {
        let runner = DelayTestRunner()
        var current = true
        var replies: [CheckedContinuation<Int, Never>] = []
        var received = 0
        runner.start(names: ["1", "2", "3", "4"], isCurrent: { current }, test: { _ in
            await withCheckedContinuation { replies.append($0) }
        }, receive: { _, _ in received += 1 })
        try await settle { replies.count == 3 }
        current = false
        for reply in replies { reply.resume(returning: 5) }
        try await settle { !runner.isRunning }
        XCTAssertEqual(received, 0)
        XCTAssertEqual(runner.completed, 0)
        XCTAssertNil(runner.finishedAt)
    }
}
