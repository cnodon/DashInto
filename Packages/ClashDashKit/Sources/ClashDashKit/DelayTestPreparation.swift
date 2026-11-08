import Foundation
import Observation

/// Makes readiness work visible and cancelable before any per-node test is submitted.
@Observable @MainActor public final class DelayTestPreparation {
    public private(set) var isPreparing = false
    public private(set) var failure: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var token = UUID()
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 20) { self.timeout = timeout }

    public func start(prepare: @escaping @MainActor () async throws -> [String],
                      ready: @escaping @MainActor ([String]) -> Void) {
        guard !isPreparing else { return }
        token = UUID(); let id = token
        failure = nil; isPreparing = true
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let names = try await CallbackDeadline.run(timeout: timeout) { complete in
                    let operation = Task { @MainActor in
                        do { complete(.success(try await prepare())) }
                        catch { complete(.failure(error)) }
                    }
                    return { operation.cancel() }
                }
                guard token == id, !Task.isCancelled else { return }
                isPreparing = false; task = nil
                guard !names.isEmpty else { failure = "当前没有可测速的代理节点，请检查订阅或刷新节点列表。"; return }
                ready(names)
            } catch {
                guard token == id, !Task.isCancelled else { return }
                isPreparing = false; task = nil
                failure = (error as? URLError)?.code == .timedOut
                    ? "读取测速状态超时，请重试或重新连接。" : error.localizedDescription
            }
        }
    }

    public func cancel(reason: String? = nil) {
        token = UUID(); task?.cancel(); task = nil
        isPreparing = false; failure = reason
    }
}
