import XCTest
@testable import ClashDashKit

@MainActor final class CallbackDeadlineTests: XCTestCase {
    func testMissingCallbackHasBoundedWait() async {
        let start = ContinuousClock.now
        do {
            let _: Int = try await CallbackDeadline.run(timeout: 0.02) { _ in nil }
            XCTFail("A missing callback must time out")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
    }
    func testSynchronousAndDuplicateRepliesOnlyCompleteOnce() async throws {
        let value: Int = try await CallbackDeadline.run(timeout: 1) { reply in
            reply(.success(17)); reply(.success(99)); return nil
        }
        XCTAssertEqual(value, 17)
    }
    func testCancellationReleasesCallbackWaitAndIgnoresLateReply() async throws {
        var callback: (@Sendable (Result<Int, Error>) -> Void)?
        let request = Task { @MainActor in
            try await CallbackDeadline.run(timeout: 60) { reply in callback = reply; return nil }
        }
        while callback == nil { await Task.yield() }
        request.cancel()
        let start = ContinuousClock.now
        do { _ = try await request.value; XCTFail("Cancellation must interrupt the wait") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        callback?(.success(99))
    }
    func testAlreadyCanceledWorkIsNotSent() async {
        var sent = false
        let request = Task { @MainActor in
            try await CallbackDeadline.run(timeout: 1) { reply in sent = true; reply(.success(1)); return nil }
        }
        request.cancel()
        do { _ = try await request.value; XCTFail("Must honor cancellation before send") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(sent)
    }
    func testSendErrorIsPropagated() async {
        do {
            let _: Int = try await CallbackDeadline.run(timeout: 1) { _ in throw URLError(.notConnectedToInternet) }
            XCTFail("Send failure must propagate")
        } catch { XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet) }
    }
}
