import Foundation

public enum SubscriptionRefreshInterval: Int, CaseIterable, Sendable {
    case disabled = 0, sixHours = 21600, twelveHours = 43200, daily = 86400
    public var title: String {
        switch self {
        case .disabled: "关闭"
        case .sixHours: "每 6 小时"
        case .twelveHours: "每 12 小时"
        case .daily: "每天"
        }
    }
    public func nextDue(for profile: Profile) -> Date? {
        guard self != .disabled, profile.isSubscription else { return nil }
        let scheduled = profile.updatedAt.addingTimeInterval(TimeInterval(rawValue))
        // A failed, expired or interrupted attempt must not loop on every foreground event.
        let retry = profile.refreshState?.attemptedAt.addingTimeInterval(30 * 60) ?? .distantPast
        return max(scheduled, retry)
    }
}

public struct SubscriptionRefreshState: Codable, Hashable, Sendable {
    public enum Outcome: String, Codable, Sendable { case pending, succeeded, failed, cancelled }
    public var attemptedAt: Date
    public var outcome: Outcome
    public init(attemptedAt: Date = Date(), outcome: Outcome) { self.attemptedAt = attemptedAt; self.outcome = outcome }
}

public struct PreparedSubscription: Sendable {
    public let configuration: PreparedConfiguration
    public let usage: SubscriptionUsage?
    public init(configuration: PreparedConfiguration, usage: SubscriptionUsage?) { self.configuration = configuration; self.usage = usage }
}

/// Downloads and validates before publishing a new encrypted revision. Never controls the VPN.
@MainActor public final class SubscriptionRefresher {
    private let store: ProfileStore
    private let prepare: @Sendable (URL) async throws -> PreparedSubscription
    private var inFlight = Set<UUID>()
    private let timeout: TimeInterval
    public init(store: ProfileStore, timeout: TimeInterval = 90, prepare: @escaping @Sendable (URL) async throws -> PreparedSubscription) {
        self.store = store; self.timeout = timeout; self.prepare = prepare
    }
    public func refresh(profileID: UUID, retaining: [String] = []) async throws -> ProfileLibrary {
        guard inFlight.insert(profileID).inserted else { throw DashError.message("这份订阅正在更新。") }
        defer { inFlight.remove(profileID) }
        try Task.checkCancellation()
        let state = try await store.library()
        guard let profile = state.profiles.first(where: { $0.id == profileID }), profile.isSubscription else { throw DashError.message("此配置没有订阅地址。") }
        let envelope = try await store.envelope(profileID: profileID, generation: profile.selectedVersion)
        guard let source = envelope.sourceURL, let url = URL(string: source) else { throw DashError.message("订阅地址不可用。") }
        let attempt = SubscriptionRefreshState(outcome: .pending)
        _ = try await store.recordRefresh(profileID: profileID, expectedVersion: profile.selectedVersion, state: attempt)
        do {
            let prepared = try await CallbackDeadline.run(timeout: timeout) { [prepare] complete in
                let child = Task {
                    do { complete(.success(try await prepare(url))) }
                    catch { complete(.failure(error)) }
                }
                return { child.cancel() }
            }
            try Task.checkCancellation()
            // The actor checks cancellation and the expected generation again before committing.
            return try await store.importConfiguration(prepared.configuration, name: profile.name, sourceURL: url,
                replacing: profileID, usage: prepared.usage, selectIfEmpty: false, retaining: retaining, expectedVersion: profile.selectedVersion)
        } catch {
            let cancelled = Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
            _ = try? await store.recordRefresh(profileID: profileID, expectedVersion: profile.selectedVersion,
                state: .init(attemptedAt: attempt.attemptedAt, outcome: cancelled ? .cancelled : .failed))
            throw error
        }
    }
}
