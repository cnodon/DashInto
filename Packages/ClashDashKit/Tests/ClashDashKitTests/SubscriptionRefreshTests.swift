import XCTest
@testable import ClashDashKit

@MainActor final class SubscriptionRefreshTests: XCTestCase {
    private let sample = """
    proxies:
      - {name: Route1, type: ss, server: 127.0.0.1, port: 19871, cipher: aes-128-gcm, password: synthetic}
    proxy-groups:
      - {name: Choose, type: select, proxies: [Route1]}
    rules: ["MATCH,Choose"]
    """
    private func fixture() async throws -> (URL, ProfileStore, Profile) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ProfileStore(root: root, keyProvider: RefreshTestKey())
        let library = try await store.importConfiguration(ConfigurationParser.prepare(sample), name: "Original",
            sourceURL: URL(string: "https://subscription.invalid/test"))
        return (root, store, try XCTUnwrap(library.activeProfile))
    }
    func testSchedulingSkipsFilesAndDisabledAndBacksOffFailedAttempts() async throws {
        let (root, _, original) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var profile = original
        let now = Date(timeIntervalSince1970: 2_000_000)
        profile.updatedAt = now.addingTimeInterval(-86400)
        XCTAssertEqual(SubscriptionRefreshInterval.daily.nextDue(for: profile), now)
        XCTAssertNil(SubscriptionRefreshInterval.disabled.nextDue(for: profile))
        profile.refreshState = .init(attemptedAt: now, outcome: .failed)
        XCTAssertEqual(SubscriptionRefreshInterval.daily.nextDue(for: profile), now.addingTimeInterval(1800))
        profile.isSubscription = false
        XCTAssertNil(SubscriptionRefreshInterval.daily.nextDue(for: profile))
    }
    func testSuccessKeepsSelectedProfileNameModeAndRunningRevision() async throws {
        let (root, store, original) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await store.rememberSelection(profileID: original.id, group: "Choose", member: "Route1")
        _ = try await store.rememberMode(profileID: original.id, mode: .global)
        let prepared = try ConfigurationParser.prepare(sample + "\n# updated")
        let service = SubscriptionRefresher(store: store) { _ in .init(configuration: prepared, usage: nil) }
        let library = try await service.refresh(profileID: original.id, retaining: [original.selectedVersion])
        let current = try XCTUnwrap(library.activeProfile)
        XCTAssertEqual(current.id, original.id); XCTAssertEqual(current.name, original.name)
        XCTAssertEqual(current.preferredMode, .global); XCTAssertEqual(current.selections?["Choose"], "Route1")
        XCTAssertNotEqual(current.selectedVersion, original.selectedVersion)
        XCTAssertEqual(current.refreshState?.outcome, .succeeded)
        _ = try await store.envelope(profileID: original.id, generation: original.selectedVersion)
    }
    func testFailedValidationKeepsConfigurationAndStoresOnlySafeStatus() async throws {
        let (root, store, original) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let service = SubscriptionRefresher(store: store) { _ in throw DashError.message("https://private.invalid/?token=secret") }
        do { _ = try await service.refresh(profileID: original.id); XCTFail("Expected failure") } catch { }
        let library = try await store.library()
        XCTAssertEqual(library.activeProfile?.selectedVersion, original.selectedVersion)
        XCTAssertEqual(library.activeProfile?.versions.count, 1)
        XCTAssertEqual(library.activeProfile?.refreshState?.outcome, .failed)
        let index = try String(contentsOf: root.appendingPathComponent("library.json"), encoding: .utf8)
        XCTAssertFalse(index.contains("secret"))
    }
    func testCancelledDownloadCannotCommitLateResult() async throws {
        let (root, store, original) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = RefreshGate()
        let prepared = try ConfigurationParser.prepare(sample + "\n# late")
        let service = SubscriptionRefresher(store: store) { _ in await gate.wait(); return .init(configuration: prepared, usage: nil) }
        let task = Task { try await service.refresh(profileID: original.id) }
        await gate.waitUntilStarted()
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { }
        await gate.release()
        try await Task.sleep(for: .milliseconds(20))
        let library = try await store.library()
        XCTAssertEqual(library.activeProfile?.selectedVersion, original.selectedVersion)
        XCTAssertEqual(library.activeProfile?.refreshState?.outcome, .cancelled)
    }
    func testDeletedSubscriptionIsNotRecreatedByLateUpdate() async throws {
        let (root, store, original) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = RefreshGate()
        let prepared = try ConfigurationParser.prepare(sample)
        let service = SubscriptionRefresher(store: store) { _ in await gate.wait(); return .init(configuration: prepared, usage: nil) }
        let task = Task { try await service.refresh(profileID: original.id) }
        await gate.waitUntilStarted()
        _ = try await store.delete(original.id)
        await gate.release()
        do { _ = try await task.value; XCTFail("Expected stale update rejection") } catch { }
        let library = try await store.library()
        XCTAssertTrue(library.profiles.isEmpty)
    }
    func testDuplicateAttemptIsRejectedAndRenameDuringDownloadSurvives() async throws {
        let (root, store, original) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = RefreshGate()
        let prepared = try ConfigurationParser.prepare(sample)
        let service = SubscriptionRefresher(store: store) { _ in await gate.wait(); return .init(configuration: prepared, usage: nil) }
        let task = Task { try await service.refresh(profileID: original.id) }
        await gate.waitUntilStarted()
        do { _ = try await service.refresh(profileID: original.id); XCTFail("Duplicate admitted") } catch { }
        _ = try await store.rename(profileID: original.id, name: "Renamed")
        await gate.release()
        let library = try await task.value
        XCTAssertEqual(library.activeProfile?.name, "Renamed")
        XCTAssertEqual(library.activeProfile?.versions.count, 1)
    }
    func testUnchangedRefreshDoesNotCreateRevisionOrSelectSavedOnlyProfile() async throws {
        let (root, store, original) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var state = try await store.library(); state.selectedProfileID = nil; try await store.saveLibrary(state)
        let prepared = try ConfigurationParser.prepare(sample)
        let service = SubscriptionRefresher(store: store) { _ in .init(configuration: prepared, usage: .parse("upload=1; download=2; total=100")) }
        let library = try await service.refresh(profileID: original.id)
        XCTAssertNil(library.selectedProfileID)
        XCTAssertEqual(library.profiles.first?.selectedVersion, original.selectedVersion)
        XCTAssertEqual(library.profiles.first?.usage?.downloaded, 2)
        XCTAssertEqual(library.profiles.first?.refreshState?.outcome, .succeeded)
    }
    func testNewerRevisionCannotBeOverwrittenByOlderInFlightRefresh() async throws {
        let (root, store, original) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = RefreshGate()
        let old = try ConfigurationParser.prepare(sample + "\n# old remote")
        let service = SubscriptionRefresher(store: store) { _ in await gate.wait(); return .init(configuration: old, usage: nil) }
        let task = Task { try await service.refresh(profileID: original.id) }
        await gate.waitUntilStarted()
        let newer = try await store.importConfiguration(ConfigurationParser.prepare(sample + "\n# newer"), name: original.name, replacing: original.id)
        await gate.release()
        do { _ = try await task.value; XCTFail("Stale update admitted") } catch { }
        let final = try await store.library()
        XCTAssertEqual(final.activeProfile?.selectedVersion, newer.activeProfile?.selectedVersion)
    }
    func testChangedProviderContentCreatesRevisionEvenWithIdenticalSubscriptionText() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(root: root, keyProvider: RefreshTestKey())
        var prepared = try ConfigurationParser.prepare("proxy-providers: {p: {type: http, url: 'https://example.invalid/p'}}\nrules: ['MATCH,DIRECT']")
        let path = try XCTUnwrap(prepared.resourceRequests.first?.relativePath)
        prepared.resources = [.init(relativePath: path, data: Data("proxies: []".utf8))]
        let first = try await store.importConfiguration(prepared, name: "Provider", sourceURL: URL(string: "https://example.invalid/sub"))
        let profile = try XCTUnwrap(first.activeProfile)
        prepared.resources = [.init(relativePath: path, data: Data("proxies: []\n# updated provider".utf8))]
        let updated = prepared
        let service = SubscriptionRefresher(store: store) { _ in .init(configuration: updated, usage: nil) }
        let final = try await service.refresh(profileID: profile.id)
        XCTAssertNotEqual(final.activeProfile?.selectedVersion, profile.selectedVersion)
    }
    func testHungPreparationTimesOutAndDoesNotPublishLateResult() async throws {
        let (root, store, original) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = RefreshGate()
        let prepared = try ConfigurationParser.prepare(sample)
        let service = SubscriptionRefresher(store: store, timeout: 0.03) { _ in await gate.wait(); return .init(configuration: prepared, usage: nil) }
        do { _ = try await service.refresh(profileID: original.id); XCTFail("Expected timeout") } catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        await gate.release()
        try await Task.sleep(for: .milliseconds(20))
        let library = try await store.library()
        XCTAssertEqual(library.activeProfile?.selectedVersion, original.selectedVersion)
        XCTAssertEqual(library.activeProfile?.refreshState?.outcome, .failed)
    }
    func testLegacyProfileAndNaturalNameSorting() async throws {
        let (root, _, original) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        json.removeValue(forKey: "refreshState")
        let profile = try JSONDecoder().decode(Profile.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(profile.refreshState)
        let names = ["Node 10", "Node 2", "Node 1"]
        XCTAssertEqual(ProxyNodeSortOrder.name.sorted(names, delays: [:]), ["Node 1", "Node 2", "Node 10"])
        XCTAssertEqual(ProxyNodeSortOrder.configuration.sorted(names, delays: [:]), names)
        XCTAssertEqual(ProxyNodeSortOrder.latency.sorted(names, delays: ["Node 10": -1, "Node 1": 30, "Node 2": 5]), ["Node 2", "Node 1", "Node 10"])
    }
}

private struct RefreshTestKey: KeyMaterialProviding { func key() throws -> Data { Data(repeating: 8, count: 32) } }
private actor RefreshGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async { if !released { await withCheckedContinuation { continuation = $0 } } }
    func waitUntilStarted() async {
        for _ in 0..<200 {
            if continuation != nil { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
