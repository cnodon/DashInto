import Foundation
import Observation

public enum TunnelPhase: Sendable { case stopped, starting, running, stopping }

@MainActor public protocol ConnectionDriving: AnyObject {
    var phase: TunnelPhase { get }
    var runtime: RuntimeInfo? { get }
    var lastError: String? { get }
    func connect(profile: Profile) async throws
    func waitUntilDisconnected() async throws
    func disconnect()
    func refreshState()
    func updateRuntime() async
}

/// Shares a pending snapshot between startup and foreground polling. A new connection epoch
/// gets a new request; completion of an older request cannot evict the newer flight.
@MainActor public final class RuntimeSnapshotLoader {
    private var flight: (epoch: Int, id: UUID, task: Task<RuntimeInfo, Error>)?
    public init() {}
    public func load(epoch: Int, operation: @escaping @MainActor () async throws -> RuntimeInfo) async throws -> RuntimeInfo {
        try Task.checkCancellation()
        let current: (epoch: Int, id: UUID, task: Task<RuntimeInfo, Error>)
        if let flight, flight.epoch == epoch { current = flight }
        else {
            flight?.task.cancel()
            current = (epoch, UUID(), Task { try await operation() })
            flight = current
        }
        defer { if flight?.id == current.id { flight = nil } }
        let result = try await current.task.value
        try Task.checkCancellation()
        return result
    }
}

public struct NetworkCheck: Sendable, Equatable {
    public let passed: Int
    public let total: Int
    public let date: Date
    public init(passed: Int, total: Int = 2, date: Date = Date()) {
        self.passed = passed; self.total = total; self.date = date
    }
    public var successful: Bool { passed == total && total > 0 }
    public var title: String { successful ? "网络检查通过" : "网络检查未全部通过（\(passed)/\(total)）" }
    public static func run() async -> Self {
        let targets = [("https://www.apple.com/library/test/success.html", 200), ("https://www.cloudflare.com/cdn-cgi/trace", 200)]
        let passed = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for (address, status) in targets {
                group.addTask {
                    let configuration = URLSessionConfiguration.ephemeral
                    configuration.timeoutIntervalForRequest = 10; configuration.timeoutIntervalForResource = 12
                    configuration.urlCache = nil
                    let session = URLSession(configuration: configuration)
                    defer { session.invalidateAndCancel() }
                    do {
                        var request = URLRequest(url: URL(string: address)!)
                        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                        let (bytes, response) = try await session.bytes(for: request)
                        guard (response as? HTTPURLResponse)?.statusCode == status, response.url?.scheme == "https" else { return false }
                        var body = Data()
                        for try await byte in bytes { body.append(byte); if body.count >= 4096 { break } }
                        let text = String(decoding: body, as: UTF8.self)
                        return address.contains("apple.com") ? text.contains("Success") : text.contains("ip=") && text.contains("tls=")
                    } catch { return false }
                }
            }
            var count = 0
            for await value in group { if value { count += 1 } }
            return count
        }
        return Self(passed: passed)
    }
}

public enum ConnectionStep: String, Sendable {
    case idle, stopping, preparing, authorizing, starting, checking, ready, limited, failed
    public var inProgress: Bool { [.stopping, .preparing, .authorizing, .starting, .checking].contains(self) }
    public var title: String {
        switch self {
        case .idle: "未连接"
        case .stopping: "正在断开"
        case .preparing: "正在准备订阅"
        case .authorizing: "正在设置 VPN"
        case .starting: "正在启动网络核心"
        case .checking: "正在检查网络"
        case .ready: "已连接"
        case .limited: "VPN 已建立"
        case .failed: "连接未完成"
        }
    }
}

/// Owns the connection task independently of the import sheet. Every late result is fenced by attempt + session.
@Observable @MainActor public final class ConnectionCoordinator {
    public private(set) var step: ConnectionStep = .idle
    public private(set) var failure: String?
    public private(set) var check: NetworkCheck?
    public private(set) var targetID: UUID?
    public private(set) var checkedSession: String?
    @ObservationIgnored private let driver: any ConnectionDriving
    @ObservationIgnored private let probe: @Sendable () async -> NetworkCheck
    @ObservationIgnored private let interval: Duration
    @ObservationIgnored private let attempts: Int
    @ObservationIgnored private let startupTimeout: TimeInterval
    @ObservationIgnored private let checkTimeout: TimeInterval
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var attempt = UUID()

    public init(driver: any ConnectionDriving, interval: Duration = .milliseconds(500), attempts: Int = 90, startupTimeout: TimeInterval = 60, checkTimeout: TimeInterval = 15,
                probe: @escaping @Sendable () async -> NetworkCheck = { await NetworkCheck.run() }) {
        self.driver = driver; self.interval = interval; self.attempts = attempts; self.probe = probe
        self.startupTimeout = startupTimeout; self.checkTimeout = checkTimeout
    }

    public func start(_ profile: Profile, activate: @escaping @MainActor () async throws -> Void) {
        // Keep one start/stop transaction. Cancel is always available while a transaction runs.
        guard !step.inProgress else { return }
        task?.cancel(); attempt = UUID(); let token = attempt
        targetID = profile.id; failure = nil; check = nil; checkedSession = nil
        step = driver.phase == .stopped ? .preparing : .stopping
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await driver.waitUntilDisconnected()
                try valid(token)
                step = .preparing
                try await activate()
                try valid(token)
                step = .authorizing
                try await driver.connect(profile: profile)
                try valid(token)
                step = .starting
                let session = try await bounded(timeout: startupTimeout) { [self] in
                    for index in 0..<self.attempts {
                        try self.valid(token); self.driver.refreshState()
                        if self.driver.phase == .running {
                            await self.driver.updateRuntime()
                            try self.valid(token)
                            if let runtime = self.driver.runtime, runtime.generation == profile.selectedVersion { return runtime.sessionID }
                        }
                        if index > 3, self.driver.phase == .stopped { throw DashError.message(self.driver.lastError ?? "VPN 未能启动。请检查系统授权与网络后重试。") }
                        try await Task.sleep(for: self.interval)
                    }
                    throw DashError.message("网络核心未在限定时间内就绪，请重试。")
                }
                await checkNetwork(token: token, session: session)
            } catch {
                guard token == attempt else { return }
                driver.disconnect()
                if error is CancellationError { step = .idle }
                else { failure = (error as? URLError)?.code == .timedOut ? "网络核心启动超时，请重试或查看运行诊断。" : error.localizedDescription; step = .failed }
            }
        }
    }
    public func cancel() {
        task?.cancel(); attempt = UUID(); let token = attempt
        check = nil; checkedSession = nil; failure = nil; step = .stopping
        driver.disconnect()
        task = Task { [weak self] in
            guard let self else { return }
            do { try await driver.waitUntilDisconnected(); try valid(token); step = .idle }
            catch { guard token == attempt else { return }; failure = "断开尚未完成，请查看系统 VPN 状态。"; step = .failed }
        }
    }
    public func retryCheck() {
        guard !step.inProgress, driver.phase == .running, let runtime = driver.runtime else { return }
        task?.cancel(); attempt = UUID(); let token = attempt
        step = .checking
        task = Task { [weak self] in await self?.checkNetwork(token: token, session: runtime.sessionID) }
    }
    /// Invalidates health evidence without tearing down a tunnel that is recovering.
    public func networkChanged() {
        check = nil; checkedSession = nil
        if step == .checking || !step.inProgress {
            task?.cancel(); attempt = UUID(); step = .idle; failure = nil
        }
    }
    public func reconcile() {
        if driver.phase != .running && (step == .checking || checkedSession != nil) {
            networkChanged()
            if driver.phase == .stopped, let error = driver.lastError { failure = error; step = .failed }
            return
        }
        guard !step.inProgress else { return }
        if driver.phase == .stopped {
            if checkedSession != nil {
                check = nil; checkedSession = nil; step = .idle
                if let error = driver.lastError { failure = error; step = .failed }
            }
        } else if driver.phase == .running, let runtime = driver.runtime, checkedSession != runtime.sessionID {
            retryCheck()
        }
    }
    private func valid(_ token: UUID) throws {
        try Task.checkCancellation()
        guard token == attempt else { throw CancellationError() }
    }
    private func checkNetwork(token: UUID, session: String) async {
        guard token == attempt, !Task.isCancelled else { return }
        step = .checking; check = nil
        let result: NetworkCheck
        do { result = try await bounded(timeout: checkTimeout) { [probe] in await probe() } }
        catch {
            guard token == attempt, !Task.isCancelled else { return }
            guard driver.phase == .running, driver.runtime?.sessionID == session else { networkChanged(); return }
            check = nil; checkedSession = session; step = .limited
            failure = "网络检查未完成，可重试检查；VPN 仍保持连接。"
            return
        }
        guard token == attempt, !Task.isCancelled else { return }
        guard driver.phase == .running, driver.runtime?.sessionID == session else {
            networkChanged(); return
        }
        check = result; checkedSession = session; failure = nil
        step = result.successful ? .ready : .limited
    }
    private func bounded<T: Sendable>(timeout: TimeInterval, operation: @escaping @MainActor () async throws -> T) async throws -> T {
        try await CallbackDeadline.run(timeout: timeout) { complete in
            let child = Task { @MainActor in
                do { complete(.success(try await operation())) }
                catch { complete(.failure(error)) }
            }
            return { child.cancel() }
        }
    }

}
