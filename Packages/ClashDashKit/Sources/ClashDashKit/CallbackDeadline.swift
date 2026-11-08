import Foundation

/// Bounds callback-based work even when it never replies or ignores Task cancellation.
public enum CallbackDeadline {
    @MainActor public static func run<Value: Sendable>(
        timeout: TimeInterval,
        start: (@escaping @Sendable (Result<Value, Error>) -> Void) throws -> (@Sendable () -> Void)?
    ) async throws -> Value {
        let reply = PendingCallback<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard reply.install(continuation, timeout: timeout) else { return }
                do { reply.setCleanup(try start { reply.finish($0) }) }
                catch { reply.finish(.failure(error)) }
            }
        } onCancel: {
            reply.finish(.failure(CancellationError()))
        }
    }
}

private final class PendingCallback<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var outcome: Result<Value, Error>?
    private var timer: DispatchWorkItem?
    private var cleanup: (@Sendable () -> Void)?

    func install(_ continuation: CheckedContinuation<Value, Error>, timeout: TimeInterval) -> Bool {
        lock.lock()
        if let outcome {
            lock.unlock(); continuation.resume(with: outcome); return false
        }
        self.continuation = continuation
        let timer = DispatchWorkItem { [weak self] in self?.finish(.failure(URLError(.timedOut))) }
        self.timer = timer
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + max(0, timeout), execute: timer)
        return true
    }
    func setCleanup(_ cleanup: (@Sendable () -> Void)?) {
        lock.lock()
        if outcome != nil { lock.unlock(); cleanup?() }
        else { self.cleanup = cleanup; lock.unlock() }
    }
    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard outcome == nil else { lock.unlock(); return }
        outcome = result
        let pending = continuation, timer = timer, cleanup = cleanup
        continuation = nil; self.timer = nil; self.cleanup = nil
        lock.unlock()
        timer?.cancel(); cleanup?(); pending?.resume(with: result)
    }
}
