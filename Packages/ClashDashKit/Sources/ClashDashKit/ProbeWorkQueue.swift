import Foundation

/// Bounds synchronous core probes, including calls still finishing after an App cancellation.
public final class ProbeWorkQueue: @unchecked Sendable {
    private let queue = OperationQueue()
    private let lock = NSLock()
    private let capacity: Int
    private var outstanding = 0

    public init(concurrency: Int = 3, capacity: Int = 6) {
        self.capacity = max(1, capacity)
        queue.name = "app.clashdash.probes"; queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = max(1, concurrency)
    }
    @discardableResult public func submit<Value: Sendable>(
        operation: @escaping @Sendable () -> Value,
        completion: @escaping @Sendable (Value) -> Void
    ) -> Bool {
        lock.lock()
        guard outstanding < capacity else { lock.unlock(); return false }
        outstanding += 1; lock.unlock()
        queue.addOperation { [self] in
            let value = operation()
            // Release admission before replying, so a callback can immediately submit the next node.
            lock.lock(); outstanding -= 1; lock.unlock()
            completion(value)
        }
        return true
    }
}
