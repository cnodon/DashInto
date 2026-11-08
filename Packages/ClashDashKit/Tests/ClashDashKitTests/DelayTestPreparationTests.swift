import XCTest
@testable import ClashDashKit

@MainActor final class DelayTestPreparationTests: XCTestCase {
    private func settle(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Preparation did not settle")
    }
    func testPreparationIsVisibleImmediatelyAndStartsFreshCatalogOnlyOnce() async throws {
        let preparation = DelayTestPreparation()
        let runner = DelayTestRunner()
        var reply: CheckedContinuation<[String], Never>?
        var attempts = 0, results: [String] = []
        let prepare: @MainActor () async throws -> [String] = {
            attempts += 1
            return await withCheckedContinuation { reply = $0 }
        }
        let ready: @MainActor ([String]) -> Void = { names in
            runner.start(names: names, isCurrent: { true }, test: { _ in 24 }, receive: { name, _ in results.append(name) })
        }
        preparation.start(prepare: prepare, ready: ready)
        XCTAssertTrue(preparation.isPreparing)
        preparation.start(prepare: prepare, ready: ready)
        try await settle { reply != nil }
        reply?.resume(returning: ["new provider node", "other"])
        try await settle { results.count == 2 }
        XCTAssertEqual(attempts, 1)
        XCTAssertFalse(preparation.isPreparing)
        XCTAssertEqual(runner.completed, 2)
        XCTAssertEqual(Set(results), Set(["new provider node", "other"]))
    }
    func testCanceledPreparationCannotStartLateBatchAfterRetry() async throws {
        let preparation = DelayTestPreparation()
        var reply: CheckedContinuation<[String], Never>?
        var batches: [[String]] = []
        preparation.start(prepare: { await withCheckedContinuation { reply = $0 } }, ready: { batches.append($0) })
        try await settle { reply != nil }
        preparation.cancel(reason: "Canceled")
        preparation.start(prepare: { ["new"] }, ready: { batches.append($0) })
        reply?.resume(returning: ["old"])
        try await settle { !preparation.isPreparing }
        XCTAssertEqual(batches, [["new"]])
        XCTAssertNil(preparation.failure)
    }
    func testMissingRuntimeResponseTimesOutWithoutStartingTests() async throws {
        let preparation = DelayTestPreparation(timeout: 0.02)
        var reply: CheckedContinuation<[String], Never>?
        var starts = 0
        preparation.start(prepare: { await withCheckedContinuation { reply = $0 } }, ready: { _ in starts += 1 })
        try await settle { !preparation.isPreparing }
        XCTAssertTrue(preparation.failure?.contains("超时") == true)
        reply?.resume(returning: ["late"])
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(starts, 0)
    }
    func testEmptyCatalogAndConnectionFailureAreVisibleAndRetryable() async throws {
        let preparation = DelayTestPreparation()
        var starts = 0
        preparation.start(prepare: { [] }, ready: { _ in starts += 1 })
        try await settle { !preparation.isPreparing }
        XCTAssertTrue(preparation.failure?.contains("没有可测速") == true)
        preparation.start(prepare: { throw DashError.message("连接已变化") }, ready: { _ in starts += 1 })
        try await settle { !preparation.isPreparing }
        XCTAssertEqual(preparation.failure, "连接已变化")
        XCTAssertEqual(starts, 0)
        preparation.start(prepare: { ["node"] }, ready: { _ in starts += 1 })
        try await settle { !preparation.isPreparing }
        XCTAssertEqual(starts, 1)
        XCTAssertNil(preparation.failure)
    }
}
