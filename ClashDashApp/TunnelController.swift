import Foundation
import NetworkExtension
import Observation
import ClashDashKit

enum ConnectionState: String {
    case disconnected, connecting, connected, disconnecting, recovering, unavailable
    var title: String {
        switch self {
        case .disconnected: "未连接"
        case .connecting: "正在连接"
        case .connected: "已连接"
        case .disconnecting: "正在断开"
        case .recovering: "正在恢复"
        case .unavailable: "尚未配置"
        }
    }
    var isActive: Bool { [.connected, .connecting, .recovering].contains(self) }
}

@Observable @MainActor
final class TunnelController: ConnectionDriving {
    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }
    private(set) var state: ConnectionState = .disconnected
    private(set) var runtime: RuntimeInfo?
    private(set) var lastError: String?
    @ObservationIgnored private var manager: NETunnelProviderManager?
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private var epoch = 0
    @ObservationIgnored private var configurationEpoch = 0
    @ObservationIgnored private var startRequestedAt = Date.distantFuture
    @ObservationIgnored private var intentionalStop = false
    @ObservationIgnored private var startupID: String?
    var configuredGeneration: String? { (manager?.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration?["generation"] as? String }
    var configuredProfileID: UUID? {
        ((manager?.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration?["profileID"] as? String).flatMap(UUID.init(uuidString:))
    }
    var phase: TunnelPhase {
        switch state {
        case .connected: .running
        case .connecting, .recovering: .starting
        case .disconnecting: .stopping
        default: .stopped
        }
    }

    init() {
        observer = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshState() }
        }
    }
    func load() async throws {
        // iOS Simulator has no system Packet Tunnel preferences service.
        guard !Self.isSimulator else { state = .disconnected; return }
        let revision = configurationEpoch
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        guard revision == configurationEpoch else { return }
        manager = managers.first { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == DashConstants.tunnelBundleID }
        refreshState()
    }
    func connect(profile: Profile) async throws {
        guard !Self.isSimulator else { throw DashError.message("模拟器支持界面和配置导入预览。VPN 连接需要在已签名的 iPhone 上测试。") }
        configurationEpoch += 1
        lastError = nil; startRequestedAt = Date(); intentionalStop = false; runtime = nil
        startupID = UUID().uuidString
        if manager == nil { try await load() }
        try Task.checkCancellation()
        let target = manager ?? NETunnelProviderManager()
        let configuration = NETunnelProviderProtocol()
        configuration.providerBundleIdentifier = DashConstants.tunnelBundleID
        configuration.serverAddress = "DashInto"
        configuration.providerConfiguration = ["profileID": profile.id.uuidString, "generation": profile.selectedVersion, "startupID": startupID ?? ""]
        configuration.disconnectOnSleep = false
        configuration.includeAllNetworks = false
        target.protocolConfiguration = configuration
        target.localizedDescription = "DashInto"
        target.isEnabled = true
        manager = target
        try await target.saveToPreferences()
        try Task.checkCancellation()
        try await target.loadFromPreferences()
        try Task.checkCancellation()
        manager = target
        try target.connection.startVPNTunnel()
        refreshState()
    }
    func disconnect() { intentionalStop = true; startRequestedAt = .distantFuture; lastError = nil; manager?.connection.stopVPNTunnel(); refreshState() }
    func waitUntilDisconnected() async throws {
        disconnect()
        for _ in 0..<60 {
            refreshState()
            if state == .disconnected || state == .unavailable { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw DashError.message("断开连接超时，请检查系统 VPN 状态后重试。")
    }
    func refreshState() {
        guard let manager else { state = .disconnected; return }
        if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: DashConstants.appGroup),
           let record = TunnelStartupStatus.read(from: container), record.generation == configuredGeneration,
           record.date >= startRequestedAt, record.startupID == startupID, let error = record.failure { lastError = error }
        let previous = state
        switch manager.connection.status {
        case .connected: state = .connected
        case .connecting: state = .connecting
        case .disconnecting: state = .disconnecting
        case .reasserting: state = .recovering
        case .disconnected, .invalid: state = .disconnected; runtime = nil
        @unknown default: state = .unavailable
        }
        if previous != state {
            epoch += 1
            let errorEpoch = epoch
            if !intentionalStop, state == .disconnected, previous == .connecting || previous == .recovering || previous == .connected {
                manager.connection.fetchLastDisconnectError { [weak self] error in
                    guard let error else { return }
                    Task { @MainActor [weak self] in
                        guard let self, self.epoch == errorEpoch, self.state == .disconnected else { return }
                        self.lastError = error.localizedDescription
                    }
                }
            }
        }
    }
    func request(_ method: String, parameters: [String: String] = [:]) async throws -> Data {
        guard let session = manager?.connection as? NETunnelProviderSession, state == .connected else {
            throw DashError.message("请先连接 VPN。")
        }
        let request = TunnelRequest(method: method, parameters: parameters, sessionID: method == "snapshot" ? nil : runtime?.sessionID)
        let generation = configuredGeneration
        let requestEpoch = epoch
        let data = try JSONEncoder().encode(request)
        // A single callback gate handles provider replies and timeouts without double-resuming.
        return try await withCheckedThrowingContinuation { continuation in
            let gate = ReplyGate(continuation)
            DispatchQueue.main.asyncAfter(deadline: .now() + (["delay", "validation-udp"].contains(method) ? 20 : 8)) {
                gate.finish(.failure(DashError.message("扩展响应超时，请重试或查看诊断。")))
            }
            do {
                try session.sendProviderMessage(data) { response in
                    do {
                        guard let response, response.count <= 512 * 1024 else { throw DashError.message("扩展响应为空或超过大小限制。") }
                        let reply = try JSONDecoder().decode(TunnelReply.self, from: response)
                        guard reply.protocolVersion == DashConstants.protocolVersion, reply.requestID == request.requestID else {
                            throw DashError.message("扩展协议不匹配，请重新连接。")
                        }
                        guard self.epoch == requestEpoch, self.state == .connected, reply.generation == generation,
                              request.sessionID == nil || request.sessionID == reply.sessionID else {
                            throw DashError.message("连接已变化，请重试。")
                        }
                        if let error = reply.error { throw DashError.message(error) }
                        gate.finish(.success(reply.payload ?? Data("{}".utf8)))
                    } catch { gate.finish(.failure(error)) }
                }
            } catch { gate.finish(.failure(error)) }
        }
    }
    func updateRuntime() async {
        guard state == .connected else { return }
        let requestedEpoch = epoch
        do {
            let value = try await request("snapshot")
            guard requestedEpoch == epoch, state == .connected else { return }
            runtime = try JSONDecoder().decode(RuntimeInfo.self, from: value)
            lastError = nil
        } catch {
            guard requestedEpoch == epoch, state == .connected else { return }
            runtime = nil; lastError = error.localizedDescription
        }
    }
    func startPolling(_ onSample: @escaping @MainActor () -> Void) {
        stopPolling()
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refreshState()
                if self.state == .connected { await self.updateRuntime() }
                onSample()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
    func stopPolling() { polling?.cancel(); polling = nil }
}

private final class ReplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    init(_ continuation: CheckedContinuation<Data, Error>) { self.continuation = continuation }
    func finish(_ result: Result<Data, Error>) {
        lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
        pending?.resume(with: result)
    }
}
