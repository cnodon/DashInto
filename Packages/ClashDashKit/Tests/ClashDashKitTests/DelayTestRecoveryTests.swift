import XCTest
@testable import ClashDashKit

@MainActor final class DelayTestRecoveryTests: XCTestCase {
    func testNewSubscriptionDoesNotInheritOldSummaryOrLateResults() async throws {
        let runner = DelayTestRunner()
        var oldReply: CheckedContinuation<Int, Never>?
        var results: [String] = []
        runner.start(names: ["old"], isCurrent: { true }, test: { _ in
            await withCheckedContinuation { oldReply = $0 }
        }, receive: { name, _ in results.append(name) })
        while oldReply == nil { await Task.yield() }
        runner.reset()
        XCTAssertEqual(runner.total, 0)
        XCTAssertNil(runner.finishedAt)
        XCTAssertNil(runner.interruption)
        runner.start(names: ["new"], isCurrent: { true }, test: { _ in 10 }, receive: { name, _ in results.append(name) })
        oldReply?.resume(returning: 12)
        for _ in 0..<100 where runner.isRunning { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(results, ["new"])
        XCTAssertEqual(runner.completed, 1)
        XCTAssertEqual(runner.succeeded, 1)
    }
    func testMissingReplyTimesOutAndRemainingNodesStillFinish() async throws {
        let runner = DelayTestRunner(timeout: 0.03)
        var stalled: CheckedContinuation<Int, Never>?
        var results: [String: Int] = [:]
        runner.start(names: ["stalled", "fast", "next", "last"], isCurrent: { true }, test: { name in
            if name == "stalled" { return await withCheckedContinuation { stalled = $0 } }
            return 42
        }, receive: { results[$0] = $1 })
        for _ in 0..<100 where runner.isRunning { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(runner.isRunning)
        XCTAssertEqual(runner.completed, 4)
        XCTAssertEqual(results["stalled"], -1)
        XCTAssertEqual(results["last"], 42)
        XCTAssertEqual(runner.failed, 1)
        XCTAssertEqual(runner.succeeded, 3)
        stalled?.resume(returning: 5)
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(results["stalled"], -1, "Late replies must not replace the timeout")
    }

    func testCancelStopsCooperativeRequestAndAllowsImmediateRetry() async throws {
        let runner = DelayTestRunner()
        var started = false, canceled = false
        var values: [Int] = []
        runner.start(names: ["old"], isCurrent: { true }, test: { _ in
            started = true
            do { try await Task.sleep(for: .seconds(60)) }
            catch { canceled = true; throw error }
            return 99
        }, receive: { _, value in values.append(value) })
        while !started { await Task.yield() }
        runner.cancel()
        runner.start(names: ["new"], isCurrent: { true }, test: { _ in 12 }, receive: { _, value in values.append(value) })
        for _ in 0..<100 where runner.isRunning || !canceled { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(canceled)
        XCTAssertEqual(values, [12])
        XCTAssertEqual(runner.completed, 1)
    }
}
