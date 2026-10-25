import XCTest
@testable import ClashDashKit

final class DashboardTests: XCTestCase {
    func testQuotaMissingIsNotZeroAndOveruseClamps() {
        XCTAssertNil(SubscriptionBalance(usage: .parse("total=100; download=20")))
        XCTAssertNil(SubscriptionBalance(usage: .parse("total=0; upload=0; download=0")))
        let balance = SubscriptionBalance(usage: .parse("total=100; upload=10; download=20"))
        XCTAssertEqual(balance?.remaining, 70)
        XCTAssertEqual(balance?.fraction, 0.7)
        XCTAssertEqual(SubscriptionBalance(usage: .parse("total=100; upload=10; download=100"))?.remaining, 0)
    }
    func testNestedNodeResolutionRejectsMissingSelectionAndCycles() {
        var groups = [ProxyGroup(name: "A", kind: "select", members: ["B"], selected: "B"), ProxyGroup(name: "B", kind: "url-test", members: ["Tokyo"], selected: "Tokyo")]
        XCTAssertEqual(ProxySelection.resolvedLeaf(group: "A", groups: groups), "Tokyo")
        groups[1].selected = nil
        XCTAssertNil(ProxySelection.resolvedLeaf(group: "A", groups: groups))
        groups[1] = ProxyGroup(name: "B", kind: "select", members: ["A"], selected: "A")
        XCTAssertNil(ProxySelection.resolvedLeaf(group: "A", groups: groups))
    }
    func testNodeRatesUseDeltasAndDeduplicateChainsWithoutInventingClosedTraffic() throws {
        var tracker = ConnectionTrafficTracker()
        let start = Date(timeIntervalSince1970: 1000)
        func snapshot(_ upload: Int, _ download: Int, id: String = "flow") throws -> Data {
            try JSONSerialization.data(withJSONObject: ["connections": [["id": id, "upload": upload, "download": download, "chains": ["Node", "Group", "Node"]]]])
        }
        try tracker.update(snapshot(100, 400), at: start)
        XCTAssertTrue(tracker.rates.isEmpty)
        try tracker.update(snapshot(200, 800), at: start.addingTimeInterval(2))
        XCTAssertEqual(tracker.rates["Node"]?.upload, 50)
        XCTAssertEqual(tracker.rates["Group"]?.download, 200)
        XCTAssertEqual(tracker.count, 1)
        try tracker.update(snapshot(5, 10), at: start.addingTimeInterval(4))
        XCTAssertEqual(tracker.rates["Node"]?.download, 0)
        try tracker.update(snapshot(500, 900, id: "new"), at: start.addingTimeInterval(6))
        XCTAssertTrue(tracker.rates.isEmpty)
        try tracker.update(snapshot(1000, 1500, id: "new"), at: start.addingTimeInterval(20))
        XCTAssertTrue(tracker.rates.isEmpty)
        XCTAssertThrowsError(try tracker.update(Data("{}".utf8)))
    }
    func testConnectivityDoesNotMislabelChallengesOrRestrictionsAsSuccess() {
        XCTAssertEqual(WebsiteProbeResult.classify(code: 204, body: ""), .available)
        XCTAssertEqual(WebsiteProbeResult.classify(code: 200, body: "<title>Just a moment...</title>"), .challenge)
        XCTAssertEqual(WebsiteProbeResult.classify(code: 403, body: "cf-chl-"), .challenge)
        XCTAssertEqual(WebsiteProbeResult.classify(code: 403, body: "Access denied"), .restricted)
        XCTAssertEqual(WebsiteProbeResult.classify(code: 429, body: ""), .restricted)
    }
    func testExitParsingAcceptsOnlyIPLiteral() {
        XCTAssertEqual(EgressResult.parse("ip=203.0.113.42\nloc=JP\n").address, "203.0.113.42")
        XCTAssertEqual(EgressResult.parse("ip=2001:db8::1\nloc=SG\n").address, "2001:db8::1")
        XCTAssertNil(EgressResult.parse("ip=<script>test</script>\nloc=long").address)
        XCTAssertNil(EgressResult.parse("ip=203.0.113.42\nloc=long").countryCode)
    }
    func testUpdateVersionsAndRepositoryBoundary() throws {
        let repository = try GitHubRepository("https://github.com/cnodon/DashInto.git/")
        XCTAssertEqual(repository.path, "cnodon/DashInto")
        for bad in ["https://github.com/owner/repo?token=x", "https://evil.test/owner/repo", "owner/repo/actions", "../repo", "owner/.."] {
            XCTAssertThrowsError(try GitHubRepository(bad))
        }
        XCTAssertLessThan(AppReleaseVersion(tag: "v0.4.0-build.9")!, AppReleaseVersion(tag: "v0.4.0-build.10")!)
        XCTAssertLessThan(AppReleaseVersion(tag: "v0.4.0-build.999")!, AppReleaseVersion(tag: "v0.5.0")!)
        XCTAssertNil(AppReleaseVersion(tag: "v0.4"))
        XCTAssertNil(AppReleaseVersion(tag: "v0.4.0-build.invalid"))
        func release(_ tag: String, draft: Bool = false, prerelease: Bool = false, url: String? = nil) -> GitHubRelease {
            GitHubRelease(tag_name: tag, html_url: url ?? "https://github.com/cnodon/DashInto/releases/tag/\(tag)", body: nil, draft: draft, prerelease: prerelease)
        }
        let releases = [release("v0.4.0"), release("v0.5.0-build.20", prerelease: true), release("v9.0.0", draft: true), release("v8.0.0", url: "https://evil.test/releases/tag/v8.0.0"), release("v7.0.0", url: "https://github.com/other/repo/releases/tag/v7.0.0")]
        XCTAssertEqual(GitHubUpdateClient.select(releases, repository: repository, includeDevelopment: true)?.tag_name, "v0.5.0-build.20")
        XCTAssertEqual(GitHubUpdateClient.select(releases, repository: repository, includeDevelopment: false)?.tag_name, "v0.4.0")
        XCTAssertNotNil(release("v0.4.0").trustedURL(repository: try GitHubRepository("CNODON/dashinto")))
        XCTAssertNil(GitHubUpdateClient.select([], repository: repository, includeDevelopment: true))
    }
    func testDuplicateConsolidationPreservesActiveRevisionResourcesAndPreferences() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(root: root, keyProvider: DashboardTestKey())
        let empty = try await store.library(); XCTAssertTrue(empty.profiles.isEmpty)
        var prepared = try ConfigurationParser.prepare("proxy-providers: {p: {type: http, url: 'https://example.com/p'}}\nrules: ['MATCH,DIRECT']")
        let payload = Data("proxies: []".utf8)
        prepared.resources = [.init(relativePath: prepared.resourceRequests[0].relativePath, data: payload)]
        let source = URL(string: "https://example.com/sub?token=test")!
        let first = try await store.commitImport(prepared, name: "我的订阅", sourceURL: source)
        let second = try await store.commitImport(prepared, name: "已验证订阅", sourceURL: source)
        _ = try await store.select(second.profileID)
        _ = try await store.rememberSelection(profileID: first.profileID, group: "Group", member: "Old")
        _ = try await store.rememberSelection(profileID: second.profileID, group: "Group", member: "Current")
        _ = try await store.rememberMode(profileID: second.profileID, mode: .global)
        let merged = try await store.consolidateValidationDuplicate(retainingProfileID: second.profileID)
        let profile = try XCTUnwrap(merged.activeProfile)
        XCTAssertEqual(merged.profiles.count, 1)
        XCTAssertEqual(profile.id, second.profileID)
        XCTAssertEqual(profile.selectedVersion, second.generation)
        XCTAssertEqual(profile.name, "我的订阅")
        XCTAssertEqual(profile.versions.count, 2)
        XCTAssertEqual(profile.selections?["Group"], "Current")
        XCTAssertEqual(profile.preferredMode, .global)
        let envelope = try await store.envelope(profileID: profile.id, generation: first.generation)
        let resource = try await store.resource(profileID: profile.id, descriptor: XCTUnwrap(envelope.resources?.first))
        XCTAssertEqual(resource, payload)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(first.profileID.uuidString).path))
        let again = try await store.consolidateValidationDuplicate()
        XCTAssertEqual(again.profiles.count, 1)
    }
    func testDifferentSubscriptionsWithLegacyNamesAreNeverMerged() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(root: root, keyProvider: DashboardTestKey())
        let prepared = try ConfigurationParser.prepare("rules: ['MATCH,DIRECT']")
        _ = try await store.commitImport(prepared, name: "我的订阅", sourceURL: URL(string: "https://example.com/sub?token=one"))
        _ = try await store.commitImport(prepared, name: "已验证订阅", sourceURL: URL(string: "https://example.com/sub?token=two"))
        let library = try await store.consolidateValidationDuplicate()
        XCTAssertEqual(library.profiles.count, 2)
        XCTAssertNil(library.selectedProfileID)
    }
}
private struct DashboardTestKey: KeyMaterialProviding { func key() throws -> Data { Data(repeating: 8, count: 32) } }
