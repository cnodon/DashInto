import Foundation
import Clash
import ClashDashKit
import CryptoKit

let root = URL(fileURLWithPath: CommandLine.arguments[1])
var checks: [[String: Any]] = []
func check(_ name: String, _ operation: () throws -> Void) {
    do { try operation(); checks.append(["name": name, "passed": true]) }
    catch { checks.append(["name": name, "passed": false, "errorType": String(describing: type(of: error))]) }
}
func require(_ condition: Bool) throws { if !condition { throw NSError(domain: "ImportProbe", code: 1) } }
func b64(_ value: String) -> String { Data(value.utf8).base64EncodedString() }
let uuid = "b831381d-6324-4d53-ad4f-8cda48b30811"
let corpus = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("Fixtures/Imports/ShadowrocketExports.json"))) as! [String: Any]
for (index, item) in (corpus["records"] as! [[String: Any]]).enumerated() {
    let expected = item["expect"] as! String
    check("Shadowrocket exporter record \(index + 1): \(expected)") {
        let result: PreparedConfiguration
        do {
            result = try NativeConfigImporter.prepare(item["exported"] as! String)
        } catch {
            try require(expected != "accepted"); return
        }
        try require(expected == "accepted" && result.summary.nodes.count == 1)
    }
}
let ss = "ss://\(b64("aes-128-gcm:sample"))@198.51.100.50:8388#SS"
let trojan = "trojan://sample@198.51.100.50:443?sni=sni.invalid#Trojan"
check("Base64 Shadowrocket subscription bundle") {
    let result = try NativeConfigImporter.prepare(b64(ss + "\n" + trojan))
    try require(result.summary.nodes.map(\.kind) == ["ss", "trojan"])
    try require(result.summary.groups.count == 1 && result.summary.rules.count == 1)
}
check("Mixed records preserve supported nodes and disclose omissions") {
    let result = try NativeConfigImporter.prepare(ss + "\nhttp3://unsupported.invalid:443#Unsupported")
    try require(result.summary.nodes.count == 1)
    try require(result.summary.warnings.contains { $0.contains("跳过 1") })
}
check("Clash full policy survives conversion") {
    let text = "proxies: [{name: T, type: trojan, server: example.invalid, port: 443, password: sample}]\nproxy-groups: [{name: Policy, type: select, proxies: [T, DIRECT]}]\nrules: ['DOMAIN,example.invalid,DIRECT', 'MATCH,Policy']\ndns: {nameserver: [https://cloudflare-dns.com/dns-query]}"
    let result = try NativeConfigImporter.prepare(text)
    try require(result.summary.groups.first?.name == "Policy")
    try require(result.summary.rules.count == 2 && result.original == text)
}
check("Sing-box outbounds import with explicit policy warning") {
    let text = "{\"outbounds\":[{\"type\":\"trojan\",\"tag\":\"T\",\"server\":\"example.invalid\",\"server_port\":443,\"password\":\"sample\",\"tls\":{\"enabled\":true,\"server_name\":\"sni.invalid\"}}]}"
    let result = try NativeConfigImporter.prepare(text)
    try require(result.summary.nodes.first?.kind == "trojan")
    try require(result.summary.warnings.contains { $0.contains("不会迁移") })
}
check("Surge proxy section") {
    let result = try NativeConfigImporter.prepare("[Proxy]\nT = trojan, example.invalid, 443, password=sample, sni=sni.invalid\n")
    try require(result.summary.nodes.first?.kind == "trojan")
}
check("VMess WebSocket TLS") {
    let object: [String: Any] = ["v":"2", "ps":"VM", "add":"example.invalid", "port":"443", "id":uuid, "aid":"0", "scy":"auto", "net":"ws", "host":"cdn.invalid", "path":"/ws", "tls":"tls", "sni":"sni.invalid"]
    let text = "vmess://" + (try JSONSerialization.data(withJSONObject: object)).base64EncodedString()
    let result = try NativeConfigImporter.prepare(text)
    try require(result.summary.nodes.first?.kind == "vmess" && result.runtime.contains("ws-opts"))
}
check("HTML and unsupported content do not become a usable profile") {
    for input in ["<html>login</html>", "juicity://sample@example.invalid:443", "not a subscription"] {
        do { _ = try NativeConfigImporter.prepare(input); throw NSError(domain: "UnexpectedImport", code: 1) }
        catch let error as NSError where error.domain == "UnexpectedImport" { throw error }
        catch {}
    }
}
let report: [String: Any] = ["checks": checks, "passed": checks.allSatisfy { $0["passed"] as? Bool == true }, "supportedImportSchemes": NativeConfigImporter.supportedSchemes]
let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
try data.write(to: root.appendingPathComponent(".build/ImportLab/result.json"))
print(String(decoding: data, as: UTF8.self))
if checks.contains(where: { $0["passed"] as? Bool == false }) { exit(1) }

// Opt-in private fixture: only counts and format names are written to the report.
if CommandLine.arguments.count > 2 {
    let privateRoot = URL(fileURLWithPath: CommandLine.arguments[2])
    let payloads = try FileManager.default.contentsOfDirectory(at: privateRoot, includingPropertiesForKeys: [.isRegularFileKey]).filter {
        ($0.lastPathComponent == "subscription.yaml" || $0.lastPathComponent.hasPrefix("download-")) &&
        (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }
    var liveReports: [[String: Any]] = []
    let preparer = NativeResourcePreparer(root: privateRoot.appendingPathComponent("ResourceCache"))
    for file in payloads.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        do {
            let text = try String(contentsOf: file, encoding: .utf8)
            let parsed = try NativeConfigImporter.prepare(text)
            let ready = try await preparer.prepare(parsed)
            let state = ProfileStore(root: privateRoot.appendingPathComponent("EncryptedProfiles"), keyProvider: LabKey(url: privateRoot.appendingPathComponent(".validation-key")))
            let library = try await state.importConfiguration(ready, name: "Local validation")
            let profile = library.profiles.last!
            let envelope = try await state.envelope(profileID: profile.id, generation: profile.selectedVersion)
            try require(envelope.original == text)
            let folder = privateRoot.appendingPathComponent(file.lastPathComponent + ".runtime")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try ready.runtime.write(to: folder.appendingPathComponent("normalized.yaml"), atomically: true, encoding: .utf8)
            for descriptor in envelope.geodata ?? [] { try await state.materializeGeodata(profileID: profile.id, descriptor: descriptor, directory: folder) }
            let item: [String: Any] = ["fixture": file.lastPathComponent, "passed": true, "format": ready.summary.sourceFormat ?? "unknown", "nodes": ready.summary.nodes.count, "groups": ready.summary.groups.count, "rules": ready.summary.rules.count, "geodata": ready.geodata.map(\.relativePath), "encryptedRoundtrip": true]
            liveReports.append(item); print("PRIVATE_FIXTURE", String(decoding: try JSONSerialization.data(withJSONObject: item, options: .sortedKeys), as: UTF8.self))
        } catch {
            let ns = error as NSError
            liveReports.append(["fixture": file.lastPathComponent, "passed": false, "errorType": String(describing: type(of: error)), "errorCode": ns.code])
            print("PRIVATE_FIXTURE_FAILED", file.lastPathComponent, String(describing: type(of: error)), ns.code)
        }
    }
    try JSONSerialization.data(withJSONObject: liveReports, options: [.prettyPrinted, .sortedKeys]).write(to: privateRoot.appendingPathComponent("validation-report.json"))
    if liveReports.contains(where: { $0["passed"] as? Bool == false }) { exit(1) }
}
private struct LabKey: KeyMaterialProviding {
    let url: URL
    func key() throws -> Data {
        if FileManager.default.fileExists(atPath: url.path) { return try Data(contentsOf: url) }
        let data = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return data
    }
}
