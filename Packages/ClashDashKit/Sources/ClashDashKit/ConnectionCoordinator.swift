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
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var attempt = UUID()

    public init(driver: any ConnectionDriving, interval: Duration = .milliseconds(500), attempts: Int = 90,
                probe: @escaping @Sendable () async -> NetworkCheck = { await NetworkCheck.run() }) {
        self.driver = driver; self.interval = interval; self.attempts = attempts; self.probe = probe
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
                for index in 0..<attempts {
                    try valid(token); driver.refreshState()
                    if driver.phase == .running {
                        await driver.updateRuntime()
                        try valid(token)
                        if let runtime = driver.runtime, runtime.generation == profile.selectedVersion {
                            await checkNetwork(token: token, session: runtime.sessionID)
                            return
                        }
                    }
                    if index > 3, driver.phase == .stopped { throw DashError.message(driver.lastError ?? "VPN 未能启动。请确认系统 VPN 授权，并检查订阅后重试。") }
                    try await Task.sleep(for: interval)
                }
                throw DashError.message("网络核心未在限定时间内就绪。请重试或查看运行诊断。")
            } catch {
                guard token == attempt else { return }
                driver.disconnect()
                if error is CancellationError { step = .idle }
                else { failure = error.localizedDescription; step = .failed }
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
        task = Task { [weak self] in await self?.checkNetwork(token: token, session: runtime.sessionID) }
    }
    public func reconcile() {
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
        let result = await probe()
        guard token == attempt, !Task.isCancelled else { return }
        guard driver.phase == .running, driver.runtime?.sessionID == session else {
            step = .failed; failure = "检查期间连接已变化，请重新连接。"; return
        }
        check = result; checkedSession = session; failure = nil
        step = result.successful ? .ready : .limited
    }
}
