import XCTest
@testable import ClashDashKit

final class ClashDashKitTests: XCTestCase {
    func testRunningVersionMetadataSurvivesSeveralSubscriptionUpdates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(root: root, keyProvider: TestKey())
        let initial = try await store.importConfiguration(ConfigurationParser.prepare(sample), name: "Running")
        let profile = try XCTUnwrap(initial.activeProfile)
        for index in 0..<6 {
            _ = try await store.importConfiguration(ConfigurationParser.prepare(sample + "\n# update \(index)"), name: profile.name,
                                                    replacing: profile.id, retaining: [profile.selectedVersion])
        }
        try await store.prune()
        let library = try await store.library()
        XCTAssertNotEqual(library.activeProfile?.selectedVersion, profile.selectedVersion)
        XCTAssertEqual(library.activeProfile?.versions.first(where: { $0.id == profile.selectedVersion })?.summary, profile.current?.summary)
        _ = try await store.envelope(profileID: profile.id, generation: profile.selectedVersion)
    }
    func testControlSocketFitsRealIOSContainerPathAndRejectsOverflow() throws {
        let container = URL(fileURLWithPath: "/private/var/mobile/Containers/Shared/AppGroup/" + UUID().uuidString)
        let old = container.appendingPathComponent("Runtime/" + UUID().uuidString + "/" + UUID().uuidString + "/clash.sock")
        XCTAssertGreaterThan(old.path.utf8.count, 103)
        let control = try TunnelPaths.controlDirectory(in: container)
        XCTAssertLessThanOrEqual(control.appendingPathComponent("clash.sock").path.utf8.count, 103)
        XCTAssertThrowsError(try TunnelPaths.controlDirectory(in: old))
    }
    func testExplicitImportCommitDoesNotSelectOrReplaceExistingChoice() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(root: root, keyProvider: TestKey())
        let first = try await store.commitImport(ConfigurationParser.prepare(sample), name: "First")
        XCTAssertNil(first.library.selectedProfileID)
        XCTAssertEqual(first.library.profiles.first?.id, first.profileID)
        _ = try await store.select(first.profileID)
        let second = try await store.commitImport(ConfigurationParser.prepare(sample), name: "Second")
        XCTAssertEqual(second.library.selectedProfileID, first.profileID)
        XCTAssertNotEqual(first.profileID, second.profileID)
        XCTAssertEqual(second.library.profiles.last?.selectedVersion, second.generation)
        _ = try await store.select(second.profileID)
        let saved = try await store.library()
        XCTAssertEqual(saved.activeProfile?.selectedVersion, second.generation)
    }
    func testSubscriptionInstallerLinksAndHTTPSBoundary() throws {
        let url = "https://example.com/sub?token=example%2Btoken"
        let encoded = url.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        XCTAssertEqual(try ImportAddress.subscriptionURL(from: "clash://install-config?url=" + encoded).absoluteString, url)
        let sub = "sub://" + Data(url.utf8).base64EncodedString()
        XCTAssertEqual(try ImportAddress.subscriptionURL(from: sub).absoluteString, url)
        XCTAssertEqual(try ImportAddress.subscriptionURL(from: "shadowrocket://add/" + sub).absoluteString, url)
        XCTAssertThrowsError(try ImportAddress.subscriptionURL(from: "http://example.com/sub"))
        XCTAssertThrowsError(try ImportAddress.subscriptionURL(from: "file:///etc/passwd"))
        XCTAssertThrowsError(try ImportAddress.subscriptionURL(from: "https://user:secret@example.com/sub"))
        XCTAssertTrue(ImportAddress.isNodeLink("ss://example"))
        XCTAssertFalse(ImportAddress.isNodeLink(url))
    }
    private let sample = """
    proxies:
      - {name: Tokyo, type: ss, server: example.com, port: 443, cipher: aes-128-gcm, password: private-secret}
    proxy-groups:
      - {name: Select, type: select, proxies: [Tokyo, DIRECT]}
    rules: [MATCH,Select]
    """.replacingOccurrences(of: "rules: [MATCH,Select]", with: "rules: ['MATCH,Select']")

    func testStandardConfigurationPreservesPoliciesAndHidesListeners() throws {
        let result = try ConfigurationParser.prepare(sample + "\nexternal-controller: 0.0.0.0:9090\nsecret: control-secret\nmixed-port: 7890\n")
        XCTAssertEqual(result.summary.nodes.map(\.name), ["Tokyo"])
        XCTAssertEqual(result.summary.groups.first?.members, ["Tokyo", "DIRECT"])
        XCTAssertEqual(result.summary.rules, ["MATCH,Select"])
        XCTAssertFalse(result.runtime.contains("0.0.0.0:9090"))
        XCTAssertFalse(result.runtime.contains("control-secret"))
        XCTAssertTrue(result.runtime.contains("mixed-port: 0"))
    }
    func testRejectsDuplicateKeys() { XCTAssertThrowsError(try ConfigurationParser.prepare(sample + "\nmode: rule\nmode: global")) }
    func testRejectsDeepFlowBeforeComposingAndAllowsQuotedBrackets() throws {
        XCTAssertThrowsError(try ConfigurationParser.prepare("rules: " + String(repeating: "[", count: 10000)))
        let result = try ConfigurationParser.prepare(sample + "\nhosts: {example.test: '" + String(repeating: "[", count: 100) + "'}")
        XCTAssertEqual(result.summary.nodes.count, 1)
    }
    func testRejectsDuplicateNodeNames() {
        XCTAssertThrowsError(try ConfigurationParser.prepare("proxies: [{name: A, type: ss}, {name: A, type: ss}]\nrules: ['MATCH,DIRECT']"))
    }
    func testRejectsCyclicGroups() {
        XCTAssertThrowsError(try ConfigurationParser.prepare("proxy-groups: [{name: A, type: select, proxies: [B]}, {name: B, type: select, proxies: [A]}]\nrules: ['MATCH,DIRECT']"))
    }
    func testRejectsMissingMember() {
        XCTAssertThrowsError(try ConfigurationParser.prepare("proxy-groups: [{name: A, type: select, proxies: [missing]}]\nrules: ['MATCH,DIRECT']"))
    }
    func testOmitsUnsupportedProcessRulesWithExplicitWarning() throws {
        let text = "rules: ['PROCESS-NAME,Safari,DIRECT', 'AND,((PROCESS-NAME,Safari),(NETWORK,TCP)),DIRECT', 'DOMAIN,example.com,DIRECT', 'MATCH,DIRECT']"
        let prepared = try ConfigurationParser.prepare(text)
        XCTAssertEqual(prepared.original, text)
        XCTAssertEqual(prepared.summary.rules, ["DOMAIN,example.com,DIRECT", "MATCH,DIRECT"])
        XCTAssertTrue(prepared.summary.warnings.contains { $0.contains("2 条") && $0.contains("进程规则") })
        XCTAssertFalse(prepared.runtime.contains("PROCESS-NAME"))
    }
    func testRejectsNonClashAndOversizedInput() {
        XCTAssertThrowsError(try ConfigurationParser.prepare("https://example.com"))
        XCTAssertThrowsError(try ConfigurationParser.prepare(String(repeating: "a", count: DashConstants.maximumConfigurationBytes + 1)))
    }
    func testProviderPathCannotEscapeContainer() throws {
        let text = "proxy-providers: {remote: {type: http, url: 'https://example.com/provider', path: '../../secret'}}\nrules: ['MATCH,DIRECT']"
        let result = try ConfigurationParser.prepare(text)
        XCTAssertFalse(result.runtime.contains("../../secret")); XCTAssertTrue(result.runtime.contains("providers/"))
    }
    func testRejectsInsecureProviderAndLocalPaths() {
        XCTAssertThrowsError(try ConfigurationParser.prepare("proxy-providers: {p: {type: http, url: 'http://example.com'}}\nrules: ['MATCH,DIRECT']"))
        XCTAssertThrowsError(try ConfigurationParser.prepare("proxy-providers: {p: {type: file, path: '/etc/passwd'}}\nrules: ['MATCH,DIRECT']"))
    }
    func testSubscriptionUsageMissingAndInvalidFields() {
        XCTAssertNil(SubscriptionUsage.parse(nil))
        let usage = SubscriptionUsage.parse("upload=10; download=20; total=100; expire=0; invalid=x")
        XCTAssertEqual(usage?.total, 100); XCTAssertEqual(usage?.downloaded, 20); XCTAssertNil(usage?.expiresAt)
        XCTAssertNil(SubscriptionUsage.parse("upload=-3; expire=hello"))
    }
    func testProviderResourcesAreVersionedEncryptedAndAuthenticated() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(root: root, keyProvider: TestKey())
        var prepared = try ConfigurationParser.prepare("proxy-providers: {p: {type: http, url: 'https://example.com/p', header: {User-Agent: [clash.meta]}}}\nrules: ['MATCH,DIRECT']")
        let request = try XCTUnwrap(prepared.resourceRequests.first)
        XCTAssertEqual(request.headers["User-Agent"], "clash.meta")
        XCTAssertFalse(prepared.runtime.contains("https://example.com/p"))
        XCTAssertTrue(prepared.runtime.contains("type: file"))
        let payload = Data("proxies: [{name: ProviderNode, type: ss, password: provider-secret}]".utf8)
        prepared.resources = [.init(relativePath: request.relativePath, data: payload)]
        let state = try await store.importConfiguration(prepared, name: "Provider")
        let profile = try XCTUnwrap(state.activeProfile)
        let envelope = try await store.envelope(profileID: profile.id, generation: profile.selectedVersion)
        let descriptor = try XCTUnwrap(envelope.resources?.first)
        let decrypted = try await store.resource(profileID: profile.id, descriptor: descriptor)
        XCTAssertEqual(decrypted, payload)
        let path = root.appendingPathComponent(profile.id.uuidString).appendingPathComponent(descriptor.blobName)
        var encrypted = try Data(contentsOf: path)
        XCTAssertFalse(String(decoding: encrypted, as: UTF8.self).contains("provider-secret"))
        encrypted[encrypted.count / 2] ^= 1; try encrypted.write(to: path)
        do { _ = try await store.resource(profileID: profile.id, descriptor: descriptor); XCTFail("Modified resource must fail authentication") } catch {}
    }
    func testIncompleteProviderUpdatePreservesSelectedVersion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(root: root, keyProvider: TestKey())
        let original = try await store.importConfiguration(ConfigurationParser.prepare(sample), name: "Original")
        let profile = try XCTUnwrap(original.activeProfile)
        let pending = try ConfigurationParser.prepare("proxy-providers: {p: {type: http, url: 'https://example.com/p'}}\nrules: ['MATCH,DIRECT']")
        do { _ = try await store.importConfiguration(pending, name: "Update", replacing: profile.id); XCTFail("Incomplete resource set must not activate") } catch {}
        let after = try await store.library()
        XCTAssertEqual(after.activeProfile?.selectedVersion, profile.selectedVersion)
        XCTAssertEqual(after.activeProfile?.versions.count, 1)
    }
    func testVersionedEncryptedStorageAndRollback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(root: root, keyProvider: TestKey())
        let prepared = try ConfigurationParser.prepare(sample)
        let first = try await store.importConfiguration(prepared, name: "Test", sourceURL: URL(string: "https://example.com/sub?token=sensitive"))
        let profile = try XCTUnwrap(first.activeProfile)
        let ciphertext = try Data(contentsOf: root.appendingPathComponent(profile.id.uuidString).appendingPathComponent(profile.selectedVersion + ".sealed"))
        XCTAssertNil(String(data: ciphertext, encoding: .utf8))
        XCTAssertFalse(String(decoding: ciphertext, as: UTF8.self).contains("private-secret"))
        let envelope = try await store.envelope(profileID: profile.id, generation: profile.selectedVersion)
        XCTAssertEqual(envelope.original, sample)
        try await store.markGood(profileID: profile.id, generation: profile.selectedVersion)
        let second = try await store.importConfiguration(try ConfigurationParser.prepare(sample + "\nmode: global"), name: "Test", replacing: profile.id)
        XCTAssertEqual(second.profiles.count, 1); XCTAssertEqual(second.activeProfile?.versions.count, 2)
        let restored = try await store.selectVersion(profileID: profile.id, generation: profile.selectedVersion)
        XCTAssertEqual(restored.activeProfile?.selectedVersion, profile.selectedVersion)
    }
    func testTamperedCiphertextAndTraversalAreRejected() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(root: root, keyProvider: TestKey())
        let state = try await store.importConfiguration(ConfigurationParser.prepare(sample), name: "Test")
        let profile = try XCTUnwrap(state.activeProfile)
        let path = root.appendingPathComponent(profile.id.uuidString).appendingPathComponent(profile.selectedVersion + ".sealed")
        var data = try Data(contentsOf: path); data[data.count / 2] ^= 1; try data.write(to: path)
        do { _ = try await store.envelope(profileID: profile.id, generation: profile.selectedVersion); XCTFail("Tampering must fail authentication") } catch {}
        do { _ = try await store.envelope(profileID: profile.id, generation: "../../escape"); XCTFail("Traversal must be rejected") } catch {}
    }
    func testRenamePreservesIdentityConfigurationAndSelections() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(root: root, keyProvider: TestKey())
        let state = try await store.importConfiguration(ConfigurationParser.prepare(sample), name: "Original")
        let profile = try XCTUnwrap(state.activeProfile)
        _ = try await store.rememberSelection(profileID: profile.id, group: "Select", member: "Tokyo")
        _ = try await store.rename(profileID: profile.id, name: "我的订阅")
        let renamed = try await store.library()
        XCTAssertEqual(renamed.activeProfile?.id, profile.id)
        XCTAssertEqual(renamed.activeProfile?.name, "我的订阅")
        XCTAssertEqual(renamed.activeProfile?.selectedVersion, profile.selectedVersion)
        XCTAssertEqual(renamed.activeProfile?.selections?["Select"], "Tokyo")
        let envelope = try await store.envelope(profileID: profile.id, generation: profile.selectedVersion)
        XCTAssertFalse(envelope.runtime.isEmpty)
    }
    func testSelectionsSurviveSubscriptionUpdateAndReload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(root: root, keyProvider: TestKey())
        let state = try await store.importConfiguration(ConfigurationParser.prepare(sample), name: "Preferences")
        let profile = try XCTUnwrap(state.activeProfile)
        _ = try await store.rememberSelection(profileID: profile.id, group: "Select", member: "Tokyo")
        _ = try await store.rememberMode(profileID: profile.id, mode: .global)
        _ = try await store.importConfiguration(ConfigurationParser.prepare(sample), name: "Preferences", replacing: profile.id)
        let reloaded = try await ProfileStore(root: root, keyProvider: TestKey()).library()
        XCTAssertEqual(reloaded.activeProfile?.selections?["Select"], "Tokyo")
        XCTAssertEqual(reloaded.activeProfile?.preferredMode, .global)
        _ = try await store.rememberMode(profileID: profile.id, mode: .direct)
        let direct = try await ProfileStore(root: root, keyProvider: TestKey()).library()
        XCTAssertEqual(direct.activeProfile?.preferredMode, .direct)
    }
    func testGeodataCopiesAndTamperDoesNotReplaceWorkingFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let publicFile = root.appendingPathComponent("database.dat")
        let data = Data(repeating: 3, count: 150_000); try data.write(to: publicFile)
        var prepared = try ConfigurationParser.prepare(sample)
        prepared.geodata = [.init(relativePath: "GeoIP.dat", sourceFileURL: publicFile, hash: try FileDigest.sha256(publicFile))]
        let store = ProfileStore(root: root.appendingPathComponent("Profiles"), keyProvider: TestKey())
        let state = try await store.importConfiguration(prepared, name: "Geo")
        let profile = try XCTUnwrap(state.activeProfile)
        let envelope = try await store.envelope(profileID: profile.id, generation: profile.selectedVersion)
        let descriptor = try XCTUnwrap(envelope.geodata?.first)
        let working = root.appendingPathComponent("Working"); try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
        try await store.materializeGeodata(profileID: profile.id, descriptor: descriptor, directory: working)
        XCTAssertEqual(try Data(contentsOf: working.appendingPathComponent("GeoIP.dat")), data)
        let blob = root.appendingPathComponent("Profiles").appendingPathComponent(profile.id.uuidString).appendingPathComponent(descriptor.blobName)
        try Data("tampered".utf8).write(to: blob)
        do { try await store.materializeGeodata(profileID: profile.id, descriptor: descriptor, directory: working); XCTFail("Bad database hash must fail") } catch {}
        XCTAssertEqual(try Data(contentsOf: working.appendingPathComponent("GeoIP.dat")), data)
    }
    func testPruningRetainsRunningGenerationAndVersionHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(root: root, keyProvider: TestKey())
        let initial = try await store.importConfiguration(ConfigurationParser.prepare(sample), name: "Versions")
        let profile = try XCTUnwrap(initial.activeProfile)
        for index in 0..<5 { _ = try await store.importConfiguration(ConfigurationParser.prepare(sample + "\n# version \(index)"), name: "Versions", replacing: profile.id) }
        let first = root.appendingPathComponent(profile.id.uuidString).appendingPathComponent(profile.selectedVersion + ".sealed")
        try await store.prune(retaining: [profile.selectedVersion])
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        try await store.prune()
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        let remaining = try await store.library()
        let latest = try XCTUnwrap(remaining.activeProfile)
        for version in latest.versions { _ = try await store.envelope(profileID: profile.id, generation: version.id) }
    }
}

private struct TestKey: KeyMaterialProviding { func key() throws -> Data { Data(repeating: 7, count: 32) } }
