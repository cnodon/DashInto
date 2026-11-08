import XCTest
@testable import ClashDashKit

@MainActor final class DelayReportTests: XCTestCase {
    func testMixedResultsRetainDatesAndRetryOnlyFailures() async throws {
        let runner = DelayTestRunner()
        runner.start(names: ["ok", "timeout", "error"], isCurrent: { true }, test: {
            $0 == "ok" ? 41 : $0 == "timeout" ? -1 : -2
        }, receive: { _, _ in })
        for _ in 0..<200 where runner.isRunning { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(runner.succeeded, 1)
        XCTAssertEqual(runner.timedOut, 1)
        XCTAssertEqual(runner.errors, 1)
        XCTAssertEqual(runner.resultDates.count, 3)
        XCTAssertEqual(runner.failedNames, ["timeout", "error"])
        XCTAssertTrue(runner.unfinishedNames.isEmpty)
        XCTAssertNotNil(runner.endedAt)
        let retry = runner.failedNames
        var tested: [String] = []
        runner.start(names: retry, isCurrent: { true }, test: { name in tested.append(name); return 10 }, receive: { _, _ in })
        for _ in 0..<200 where runner.isRunning { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(Set(tested), Set(retry))
        XCTAssertEqual(runner.succeeded, 2)
        XCTAssertTrue(runner.failedNames.isEmpty)
    }
    func testCancelRetainsPartialResultsAndIdentifiesUnfinishedWork() async throws {
        let runner = DelayTestRunner()
        var blocked: [CheckedContinuation<Int, Never>] = []
        runner.start(names: ["ok", "slow1", "slow2", "queued"], isCurrent: { true }, test: { name in
            if name == "ok" { return 11 }
            return await withCheckedContinuation { blocked.append($0) }
        }, receive: { _, _ in })
        for _ in 0..<200 where runner.completed < 1 { try await Task.sleep(for: .milliseconds(5)) }
        runner.cancel()
        let count = runner.completed
        XCTAssertEqual(runner.results["ok"], 11)
        XCTAssertEqual(runner.unfinishedNames, ["slow1", "slow2", "queued"])
        XCTAssertNil(runner.finishedAt)
        XCTAssertNotNil(runner.endedAt)
        blocked.forEach { $0.resume(returning: 9) }
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(runner.completed, count)
        runner.reset()
        XCTAssertTrue(runner.results.isEmpty)
        XCTAssertTrue(runner.resultDates.isEmpty)
        XCTAssertTrue(runner.names.isEmpty)
    }
    func testNetworkChangeMarksCompletedReportStaleWithoutLosingEvidence() async throws {
        let runner = DelayTestRunner()
        runner.start(names: ["node"], isCurrent: { true }, test: { _ in 50 }, receive: { _, _ in })
        for _ in 0..<200 where runner.isRunning { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotNil(runner.finishedAt)
        runner.invalidate(reason: "网络已切换")
        XCTAssertNil(runner.finishedAt)
        XCTAssertEqual(runner.interruption, "网络已切换")
        XCTAssertEqual(runner.results["node"], 50)
        XCTAssertNotNil(runner.resultDates["node"])
    }
    func testOldRuntimePayloadRemainsCompatibleWithNetworkRevision() throws {
        let data = Data(#"{"sessionID":"s","generation":"g","startedAt":0,"coreVersion":"test","mode":"rule","memoryBytes":0,"trafficJSON":"{}","statusJSON":"{}"}"#.utf8)
        let runtime = try JSONDecoder().decode(RuntimeInfo.self, from: data)
        XCTAssertNil(runtime.networkRevision)
        var revised = runtime; revised.networkRevision = 4
        XCTAssertEqual(try JSONDecoder().decode(RuntimeInfo.self, from: JSONEncoder().encode(revised)).networkRevision, 4)
    }
}
