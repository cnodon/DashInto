import XCTest
@testable import ClashDashKit

@MainActor final class ConnectionFlowTests: XCTestCase {
    private func profile() -> Profile {
        Profile(name: "Example", isSubscription: true, sourceHost: "example.com", version: .init(id: UUID().uuidString, createdAt: Date(), contentHash: "test", summary: .init(nodes: [], groups: [], rules: [], providerCount: 0, warnings: [])))
    }
    private func settle(_ predicate: @escaping () -> Bool) async throws {
        for _ in 0..<500 { if predicate() { return }; try await Task.sleep(for: .milliseconds(2)) }
        XCTFail("Flow did not reach its expected terminal state")
    }
    func testSwitchWaitsForStopAndUsesExactImportedGeneration() async throws {
        let driver = FakeDriver(); driver.phase = .running
        let flow = ConnectionCoordinator(driver: driver, interval: .milliseconds(1), probe: { NetworkCheck(passed: 2) })
        let target = profile()
        flow.start(target) { driver.events.append("activate") }
        try await settle { flow.step == .ready }
        XCTAssertEqual(driver.events.prefix(3), ["stop", "activate", "start"])
        XCTAssertEqual(driver.started?.id, target.id)
        XCTAssertEqual(driver.started?.selectedVersion, target.selectedVersion)
        XCTAssertNotNil(flow.check)
    }
    func testCancelDuringAuthorizationCannotStartLater() async throws {
        let driver = FakeDriver(); driver.pauseAuthorization = true
        let flow = ConnectionCoordinator(driver: driver, interval: .milliseconds(1), probe: { NetworkCheck(passed: 2) })
        flow.start(profile()) {}
        try await settle { driver.authorization != nil }
        flow.cancel()
        driver.authorization?.resume(); driver.authorization = nil
        try await settle { flow.step == .idle }
        XCTAssertNil(driver.started)
        XCTAssertNil(flow.check)
        XCTAssertEqual(driver.phase, .stopped)
    }
    func testTunnelEstablishedWithFailedProbeIsLimitedNotDisconnected() async throws {
        let driver = FakeDriver()
        let flow = ConnectionCoordinator(driver: driver, interval: .milliseconds(1), probe: { NetworkCheck(passed: 0) })
        flow.start(profile()) {}
        try await settle { flow.step == .limited }
        XCTAssertEqual(driver.phase, .running)
        XCTAssertNil(flow.failure)
        XCTAssertFalse(flow.check!.successful)
    }
    func testWrongGenerationCannotBeReportedConnected() async throws {
        let driver = FakeDriver(); driver.wrongGeneration = true
        let flow = ConnectionCoordinator(driver: driver, interval: .milliseconds(1), attempts: 5, probe: { NetworkCheck(passed: 2) })
        flow.start(profile()) {}
        try await settle { flow.step == .failed }
        XCTAssertNil(flow.check)
        XCTAssertEqual(driver.phase, .stopped)
    }
    func testCancelledNetworkCheckCannotOverwriteNextAttempt() async throws {
        let driver = FakeDriver(); let probe = SuspendedProbe()
        let flow = ConnectionCoordinator(driver: driver, interval: .milliseconds(1), probe: { await probe.run() })
        flow.start(profile()) {}
        try await settle { flow.step == .checking }
        flow.cancel()
        try await settle { flow.step == .idle }
        await probe.finish()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(flow.step, .idle); XCTAssertNil(flow.check)
    }
    func testDeniedAuthorizationRetainsRecoverableTarget() async throws {
        let driver = FakeDriver(); driver.denied = true
        let flow = ConnectionCoordinator(driver: driver, probe: { NetworkCheck(passed: 2) })
        let target = profile()
        flow.start(target) {}
        try await settle { flow.step == .failed }
        XCTAssertEqual(flow.targetID, target.id)
        XCTAssertNotNil(flow.failure)
        driver.denied = false
        flow.start(target) {}
        // Reaching startup confirms retry is admitted.
        try await settle { driver.started != nil }
        flow.cancel()
    }
}

@MainActor private final class FakeDriver: ConnectionDriving {
    var phase: TunnelPhase = .stopped
    var runtime: RuntimeInfo?
    var lastError: String?
    var events: [String] = []
    var started: Profile?
    var pauseAuthorization = false
    var wrongGeneration = false
    var denied = false
    var authorization: CheckedContinuation<Void, Never>?
    func connect(profile: Profile) async throws {
        if pauseAuthorization { await withCheckedContinuation { authorization = $0 } }
        try Task.checkCancellation()
        if denied { throw DashError.message("VPN 授权未完成，请重试。") }
        events.append("start"); started = profile; phase = .running
        runtime = RuntimeInfo(sessionID: UUID().uuidString, generation: wrongGeneration ? "wrong" : profile.selectedVersion, startedAt: Date(), coreVersion: "test", mode: "rule", memoryBytes: 0, trafficJSON: "{}", statusJSON: "{}")
    }
    func disconnect() { phase = .stopped; runtime = nil }
    func waitUntilDisconnected() async throws { events.append("stop"); disconnect() }
    func refreshState() {}
    func updateRuntime() async {}
}
private actor SuspendedProbe {
    var continuation: CheckedContinuation<NetworkCheck, Never>?
    func run() async -> NetworkCheck { await withCheckedContinuation { continuation = $0 } }
    func finish() { continuation?.resume(returning: NetworkCheck(passed: 2)); continuation = nil }
}
