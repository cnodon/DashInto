import XCTest
@testable import ClashDashKit

@MainActor final class RuntimeSnapshotTests: XCTestCase {
    private func runtime(_ name: String) -> RuntimeInfo {
        RuntimeInfo(sessionID: name, generation: name, startedAt: Date(), coreVersion: "test", mode: "rule", memoryBytes: 0, trafficJSON: "{}", statusJSON: "{}")
    }
    private func settle(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Snapshot request did not arrive")
    }
    func testStartupAndPollingShareOnePendingRequest() async throws {
        let loader = RuntimeSnapshotLoader()
        var calls = 0
        var reply: CheckedContinuation<RuntimeInfo, Error>?
        let operation: @MainActor () async throws -> RuntimeInfo = {
            calls += 1
            return try await withCheckedThrowingContinuation { reply = $0 }
        }
        let first = Task { try await loader.load(epoch: 1, operation: operation) }
        try await settle { reply != nil }
        let second = Task { try await loader.load(epoch: 1, operation: operation) }
        // Allow the second caller to join while the provider reply is held.
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(calls, 1)
        reply?.resume(returning: runtime("one"))
        let a = try await first.value, b = try await second.value
        XCTAssertEqual(a.sessionID, b.sessionID)
    }
    func testOldCompletionDoesNotEvictNewConnectionRequest() async throws {
        let loader = RuntimeSnapshotLoader()
        var replies: [Int: CheckedContinuation<RuntimeInfo, Error>] = [:]
        var calls = 0
        func request(_ epoch: Int) -> Task<RuntimeInfo, Error> {
            Task { try await loader.load(epoch: epoch) {
                calls += 1
                return try await withCheckedThrowingContinuation { replies[epoch] = $0 }
            } }
        }
        let old = request(1)
        try await settle { replies[1] != nil }
        let current = request(2)
        try await settle { replies[2] != nil }
        replies[1]?.resume(returning: runtime("old"))
        _ = try? await old.value
        let joining = request(2)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(calls, 2)
        replies[2]?.resume(returning: runtime("new"))
        let a = try await current.value, b = try await joining.value
        XCTAssertEqual(a.sessionID, "new")
        XCTAssertEqual(b.sessionID, "new")
    }
    func testFailureAllowsNextSnapshotRetry() async throws {
        let loader = RuntimeSnapshotLoader()
        do {
            _ = try await loader.load(epoch: 1) { throw DashError.message("timeout") }
            XCTFail("Expected failure")
        } catch {}
        let result = try await loader.load(epoch: 1) { self.runtime("retry") }
        XCTAssertEqual(result.sessionID, "retry")
    }
}
