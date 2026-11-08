import XCTest
@testable import ClashDashKit

final class ProbeWorkQueueTests: XCTestCase {
    private final class Activity: @unchecked Sendable {
        let lock = NSLock()
        var active = 0, peak = 0
        func begin() { lock.lock(); active += 1; peak = max(peak, active); lock.unlock() }
        func end() { lock.lock(); active -= 1; lock.unlock() }
        var maximum: Int { lock.lock(); defer { lock.unlock() }; return peak }
    }
    func testReplacementBatchWaitsWithoutExceedingThreeCoreCalls() async {
        let queue = ProbeWorkQueue()
        let activity = Activity(), hold = DispatchSemaphore(value: 0)
        let started = expectation(description: "Three old probes started"); started.expectedFulfillmentCount = 3
        let finished = expectation(description: "Old and replacement batches finish"); finished.expectedFulfillmentCount = 6
        for index in 0..<6 {
            XCTAssertTrue(queue.submit(operation: {
                activity.begin()
                if index < 3 { started.fulfill() }
                _ = hold.wait(timeout: .now() + 2)
                activity.end()
                return index
            }, completion: { _ in finished.fulfill() }))
        }
        XCTAssertFalse(queue.submit(operation: { 7 }, completion: { _ in XCTFail("Capacity must be bounded") }))
        await fulfillment(of: [started], timeout: 1)
        for _ in 0..<6 { hold.signal() }
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(activity.maximum, 3)
    }
    func testReplyCanImmediatelySubmitNextNodeWithoutFalseBusyError() async {
        let queue = ProbeWorkQueue(concurrency: 1, capacity: 1)
        let finished = expectation(description: "Follow-up accepted inside reply")
        XCTAssertTrue(queue.submit(operation: { 1 }, completion: { _ in
            XCTAssertTrue(queue.submit(operation: { 2 }, completion: { value in
                XCTAssertEqual(value, 2); finished.fulfill()
            }))
        }))
        await fulfillment(of: [finished], timeout: 2)
    }
}
