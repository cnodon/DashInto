import Foundation
import Observation

@Observable @MainActor public final class DelayTestRunner {
    public private(set) var isRunning = false
    public private(set) var testingNames: Set<String> = []
    public private(set) var completed = 0
    public private(set) var total = 0
    public private(set) var finishedAt: Date?
    @ObservationIgnored private var workers: [Task<Void, Never>] = []
    @ObservationIgnored private var token = UUID()
    @ObservationIgnored private var nextIndex = 0
    public init() {}

    public func start(names: [String], isCurrent: @escaping @MainActor () -> Bool,
                      test: @escaping @MainActor (String) async throws -> Int,
                      receive: @escaping @MainActor (String, Int) -> Void) {
        guard !isRunning, isCurrent() else { return }
        var seen = Set<String>()
        let names = names.filter { seen.insert($0).inserted }
        guard !names.isEmpty else { return }
        token = UUID(); let id = token
        total = names.count; completed = 0; nextIndex = 0; finishedAt = nil; isRunning = true
        // Fixed workers avoid the Release-only TaskGroup failure seen in the device crash.
        // MainActor owns the cursor and results; each suspension is fenced by this run's token.
        workers = (0..<min(3, names.count)).map { _ in
            Task { @MainActor [weak self] in
                while let self, self.token == id, !Task.isCancelled {
                    guard isCurrent() else { self.cancel(); return }
                    guard self.nextIndex < names.count else { return }
                    let name = names[self.nextIndex]; self.nextIndex += 1
                    self.testingNames.insert(name)
                    let delay: Int
                    do { delay = try await test(name) }
                    catch { delay = -2 }
                    guard self.token == id, !Task.isCancelled else { return }
                    guard isCurrent() else { self.cancel(); return }
                    self.testingNames.remove(name); self.completed += 1
                    receive(name, delay)
                    if self.completed == self.total {
                        self.finishedAt = Date(); self.isRunning = false; self.workers = []
                        return
                    }
                }
            }
        }
    }
    public func cancel() {
        token = UUID()
        workers.forEach { $0.cancel() }; workers = []
        testingNames = []; isRunning = false
    }
}
