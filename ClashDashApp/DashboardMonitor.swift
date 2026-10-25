import Foundation
import Observation
import ClashDashKit

@Observable @MainActor
final class DashboardMonitor {
    var connectionCount: Int?
    var nodeRates: [String: NodeTrafficRate]?
    var sites: [WebsiteProbeResult] = []
    var egress: EgressResult?
    var checking = false
    private var sessionID: String?
    @ObservationIgnored private var tracker = ConnectionTrafficTracker()
    @ObservationIgnored private var metricsTask: Task<Void, Never>?
    @ObservationIgnored private var probeTask: Task<Void, Never>?
    @ObservationIgnored private var lastMetricsAt = Date.distantPast
    @ObservationIgnored private var probeToken = UUID()
    @ObservationIgnored private var metricsToken = UUID()

    func sample(_ tunnel: TunnelController) {
        guard let session = tunnel.runtime?.sessionID else { reset(); return }
        if sessionID != session {
            reset(); sessionID = session
            refreshNetwork(tunnel)
        }
        guard metricsTask == nil, Date().timeIntervalSince(lastMetricsAt) >= 2 else { return }
        lastMetricsAt = Date()
        metricsToken = UUID(); let token = metricsToken
        metricsTask = Task { [weak self] in
            guard let self else { return }
            defer { if metricsToken == token { metricsTask = nil } }
            do {
                let data = try await tunnel.request("connections")
                guard !Task.isCancelled, metricsToken == token, tunnel.runtime?.sessionID == session, sessionID == session else { return }
                let hadBaseline = tracker.hasBaseline
                try tracker.update(data)
                connectionCount = tracker.count
                nodeRates = hadBaseline ? tracker.rates : nil
            } catch {
                guard metricsToken == token, sessionID == session else { return }
                connectionCount = nil; nodeRates = nil; tracker = ConnectionTrafficTracker()
            }
        }
    }
    func refreshNetwork(_ tunnel: TunnelController) {
        guard let session = tunnel.runtime?.sessionID, !checking else { return }
        probeToken = UUID(); let token = probeToken
        checking = true; sites = []; egress = nil
        probeTask = Task { [weak self] in
            guard let self else { return }
            enum Result: Sendable { case site(WebsiteProbeResult), ip(EgressResult) }
            await withTaskGroup(of: Result.self) { tasks in
                for (name, address) in DashboardNetworkProbe.targets {
                    tasks.addTask { .site(await DashboardNetworkProbe.website(name: name, address: address)) }
                }
                tasks.addTask { .ip(await DashboardNetworkProbe.egress()) }
                for await result in tasks {
                    guard !Task.isCancelled, self.probeToken == token, tunnel.runtime?.sessionID == session else { tasks.cancelAll(); return }
                    switch result {
                    case .site(let value): self.sites.append(value)
                    case .ip(let value): self.egress = value
                    }
                }
            }
            guard probeToken == token else { return }
            checking = false; probeTask = nil
        }
    }
    /// Route changes invalidate results from the previous route even in the same VPN session.
    func invalidateNetwork() {
        probeToken = UUID(); probeTask?.cancel(); probeTask = nil
        checking = false; sites = []; egress = nil
    }
    func suspend() {
        metricsToken = UUID(); metricsTask?.cancel(); metricsTask = nil; tracker = ConnectionTrafficTracker()
        nodeRates = nil; connectionCount = nil
        if checking { invalidateNetwork() }
    }
    private func reset() {
        guard sessionID != nil || checking || connectionCount != nil else { return }
        suspend(); invalidateNetwork(); sessionID = nil; lastMetricsAt = .distantPast
    }
}
