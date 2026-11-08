import Foundation
import Observation

@Observable @MainActor public final class DelayTestRunner {
    public private(set) var isRunning = false
    public private(set) var testingNames: Set<String> = []
    public private(set) var names: [String] = []
    public private(set) var results: [String: Int] = [:]
    public private(set) var resultDates: [String: Date] = [:]
    public private(set) var startedAt: Date?
    public private(set) var endedAt: Date?
    public var failedNames: [String] { names.filter { (results[$0] ?? 0) < 0 } }
    public var unfinishedNames: [String] { names.filter { results[$0] == nil } }
    public var timedOut: Int { results.values.filter { $0 == -1 }.count }
    public var errors: Int { results.values.filter { $0 < -1 }.count }
    public private(set) var completed = 0
    public private(set) var total = 0
    public private(set) var succeeded = 0
    public var failed: Int { completed - succeeded }
    public private(set) var interruption: String?
    public private(set) var finishedAt: Date?
    @ObservationIgnored private var workers: [Task<Void, Never>] = []
    @ObservationIgnored private var token = UUID()
    @ObservationIgnored private var nextIndex = 0
    @ObservationIgnored private let timeout: TimeInterval
    public init(timeout: TimeInterval = 15) { self.timeout = timeout }

    public func start(names: [String], isCurrent: @escaping @MainActor () -> Bool,
                      test: @escaping @MainActor (String) async throws -> Int,
                      receive: @escaping @MainActor (String, Int) -> Void) {
        guard !isRunning, isCurrent() else { return }
        var seen = Set<String>()
        let names = names.filter { seen.insert($0).inserted }
        guard !names.isEmpty else { return }
        token = UUID(); let id = token
        self.names = names; results = [:]; resultDates = [:]; startedAt = Date(); endedAt = nil
        total = names.count; completed = 0; succeeded = 0; nextIndex = 0; finishedAt = nil; interruption = nil; isRunning = true
        // Fixed workers avoid the Release-only TaskGroup failure seen in the device crash.
        // MainActor owns the cursor and results; each suspension is fenced by this run's token.
        workers = (0..<min(3, names.count)).map { _ in
            Task { @MainActor [weak self] in
                while let self, self.token == id, !Task.isCancelled {
                    guard isCurrent() else { self.cancel(reason: "连接已变化，测速已停止"); return }
                    guard self.nextIndex < names.count else { return }
                    let name = names[self.nextIndex]; self.nextIndex += 1
                    self.testingNames.insert(name)
                    let delay: Int
                    do {
                        delay = try await CallbackDeadline.run(timeout: self.timeout) { complete in
                            let task = Task { @MainActor in
                                do { complete(.success(try await test(name))) }
                                catch { complete(.failure(error)) }
                            }
                            return { task.cancel() }
                        }
                    } catch { delay = (error as? URLError)?.code == .timedOut ? -1 : -2 }
                    guard self.token == id, !Task.isCancelled else { return }
                    guard isCurrent() else { self.cancel(reason: "连接已变化，测速已停止"); return }
                    self.testingNames.remove(name); self.completed += 1
                    self.results[name] = delay; self.resultDates[name] = Date()
                    if delay >= 0 { self.succeeded += 1 }
                    receive(name, delay)
                    if self.completed == self.total {
                        self.finishedAt = Date(); self.endedAt = self.finishedAt; self.isRunning = false; self.workers = []
                        return
                    }
                }
            }
        }
    }
    public func cancel(reason: String? = nil) {
        if isRunning { interruption = reason ?? "已取消测速"; finishedAt = nil; endedAt = Date() }
        token = UUID()
        workers.forEach { $0.cancel() }; workers = []
        testingNames = []; isRunning = false
    }
    public func invalidate(reason: String) {
        cancel(reason: reason)
        if !names.isEmpty { interruption = reason; finishedAt = nil }
    }
    public func reset() {
        cancel()
        completed = 0; total = 0; succeeded = 0; finishedAt = nil; interruption = nil
        names = []; results = [:]; resultDates = [:]; startedAt = nil; endedAt = nil
    }
}
