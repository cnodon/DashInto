#if DEBUG
import Foundation
import Network
import UIKit
import ClashDashKit

/// Opt-in physical-device laboratory. Omitted entirely from Release builds.
/// The one-time request is copied into Caches with devicectl; no credentials enter launch arguments or UI tests.
@MainActor enum DeviceValidation {
    private static var started = false
    private static let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("ClashDashValidation")
    private static var checks: [[String: Any]] = []
    private static var mode = ""
    private static var runID = ""
    private static var peakMemory: UInt64 = 0

    static func runIfRequested(_ model: AppModel) async {
        guard CommandLine.arguments.contains("--device-validation"), !started else { return }
        started = true
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        let requestFile = directory.appendingPathComponent("request.json")
        var stage = "read-request"
        do {
            let data = try Data(contentsOf: requestFile)
            try FileManager.default.removeItem(at: requestFile)
            let request = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            runID = request["runID"] as? String ?? ""
            guard UUID(uuidString: runID) != nil else { throw DashError.message("Invalid validation run") }
            mode = request["mode"] as? String ?? "direct"
            guard ["direct", "subscription"].contains(mode), !TunnelController.isSimulator else { throw DashError.message("Physical device required") }
            progress("prepare-import", model)
            stage = "prepare-import"
            let text: String
            let source: URL?
            let usage: SubscriptionUsage?
            if mode == "subscription" {
                guard let address = request["subscriptionURL"] as? String else { throw DashError.message("Missing subscription") }
                let url = try ImportAddress.subscriptionURL(from: address)
                stage = "download-subscription"; progress(stage, model)
                let downloaded = try await SubscriptionClient().download(url)
                text = downloaded.text; source = url; usage = downloaded.usage
            } else {
                guard let fixture = Bundle.main.url(forResource: "direct-diagnostic", withExtension: "yaml") else { throw DashError.message("Missing fixture") }
                text = try String(contentsOf: fixture, encoding: .utf8); source = nil; usage = nil
            }
            stage = "parse-subscription"; progress(stage, model)
            let parsed = try await Task.detached { try NativeConfigImporter.prepare(text) }.value
            stage = "prepare-resources"; progress(stage, model)
            let prepared = try await NativeResourcePreparer.shared.prepare(parsed)
            stage = "save-import"; progress(stage, model)
            let priorID = model.library.selectedProfileID
            let profile: Profile
            if request["reuseSelected"] as? Bool == true, let selected = model.activeProfile {
                profile = selected
            } else {
                let commit = try await model.save(prepared, name: mode == "subscription" ? "已验证订阅" : "iPhone 直连验证", url: source, usage: usage)
                guard let saved = commit.library.profiles.first(where: { $0.id == commit.profileID }) else { throw DashError.message("Save failed") }
                profile = saved
                checks.append(["check": "save-only-preserves-selection", "passed": model.library.selectedProfileID == priorID])
            }
            checks.append(["check": "import", "passed": true, "nodes": prepared.summary.nodes.count, "groups": prepared.summary.groups.count,
                           "rules": prepared.summary.rules.count, "geodataCount": prepared.geodata.count])
            stage = "connect"
            progress(stage, model)
            model.useAndConnect(profile)
            try await waitForFlow(model)
            checks.append(["check": "exact-import-generation", "passed": model.tunnel.runtime?.generation == profile.selectedVersion && model.tunnel.configuredProfileID == profile.id])
            if let check = model.connection.check { checks.append(["check": "default-routing-https", "passed": check.successful, "targetsPassed": check.passed]) }
            checks.append(["check": "packet-tunnel-and-ipc", "passed": true, "coreVersion": model.tunnel.runtime?.coreVersion ?? ""])
            var selectedNode: ProxyNode?
            if mode == "subscription" {
                stage = "select-global-node"; progress(stage, model)
                guard let node = prepared.summary.nodes.first(where: { $0.kind == "anytls" }) ?? prepared.summary.nodes.first else { throw DashError.message("No nodes") }
                selectedNode = node
                let data = try await model.tunnel.request("proxies")
                let catalog = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["proxies"] as? [String: [String: Any]] ?? [:]
                guard (catalog["GLOBAL"]?["all"] as? [String] ?? []).contains(node.name) else { throw DashError.message("GLOBAL membership missing") }
                _ = try await model.tunnel.request("select", parameters: ["group": "GLOBAL", "name": node.name])
                await model.setMode(.global)
                guard model.tunnel.runtime?.mode == "global" else { throw DashError.message("Mode not committed") }
                checks.append(["check": "global-node-selection", "passed": true, "protocol": node.kind])
            }
            stage = "system-https-through-tunnel"; progress(stage, model)
            let before = traffic(model)
            try await checkHTTPS("https://cp.cloudflare.com/generate_204", expected: 204, label: "https-204")
            try await checkHTTPS("https://www.apple.com/library/test/success.html", expected: 200, label: "https-apple")
            await model.tunnel.updateRuntime(); sample(model)
            let after = traffic(model)
            let delta = max(after - before, 0)
            checks.append(["check": "observed-tunnel-bytes", "passed": delta > 0, "bytes": delta])
            guard delta > 0 else { throw DashError.message("No packet-flow traffic observed") }
            stage = "system-udp-dns"; progress(stage, model)
            let dns = try await DeviceDNSProbe.query()
            checks.append(["check": "system-udp-dns", "passed": dns])
            guard dns else { throw DashError.message("System UDP DNS failed") }
            if let node = selectedNode {
                stage = "proxy-udp-dns"; progress(stage, model)
                let data = try await model.tunnel.request("validation-udp", parameters: ["name": node.name])
                let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                let passed = result["passed"] as? Bool == true
                checks.append(["check": "proxy-udp-dns", "passed": passed, "protocol": node.kind, "errorCode": result["errorCode"] as? String ?? ""])
                guard passed else { throw DashError.message("Proxy UDP DNS failed") }
                stage = "node-delay"; progress(stage, model)
                let delayData = try await model.tunnel.request("delay", parameters: ["name": node.name])
                let delay = (try JSONSerialization.jsonObject(with: delayData) as? [String: Any])?["delay"] as? Int ?? -1
                checks.append(["check": "node-delay", "passed": delay >= 0, "milliseconds": delay])
                guard delay >= 0 else { throw DashError.message("Node delay failed") }
                await model.setMode(.rule)
                guard model.tunnel.runtime?.mode == "rule" else { throw DashError.message("Rule mode not committed") }
                checks.append(["check": "rule-mode", "passed": true])
            }
            stage = "disconnect"; progress(stage, model)
            model.connection.cancel()
            try await waitForStop(model)
            checks.append(["check": "disconnect", "passed": model.tunnel.state == .disconnected])
            try await checkHTTPS("https://www.apple.com/library/test/success.html", expected: 200, label: "network-after-disconnect")
            stage = "reconnect"; progress(stage, model)
            model.useAndConnect(model.library.profiles.first { $0.id == profile.id } ?? profile)
            try await waitForFlow(model)
            try await checkHTTPS("https://www.apple.com/library/test/success.html", expected: 200, label: "https-after-reconnect")
            checks.append(["check": "reconnect", "passed": true])
            if request["leaveConnected"] as? Bool != true { model.connection.cancel(); try await waitForStop(model) }
            await model.refreshGroups()
            model.notice = "真机验证完成"
            write(stage: "completed", terminal: true, model: model)
        } catch {
            let ns = error as NSError
            var failure: [String: Any] = ["check": stage, "passed": false, "errorDomain": ns.domain, "errorCode": ns.code]
            // Only our authored, URL-free product errors; never serialize underlying transport errors.
            if case DashError.message(let message) = error, !message.contains("://"), message.count < 220 { failure["reason"] = message }
            if let message = model.connection.failure, !message.contains("://"), message.count < 300 { failure["connectionFailure"] = message }
            let root = await model.store.root.deletingLastPathComponent()
            if let startup = TunnelStartupStatus.read(from: root) {
                failure["startupPhase"] = startup.phase
                if let reason = startup.failure { failure["startupFailure"] = reason }
            }
            failure["sharedContainerAvailable"] = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: DashConstants.appGroup) != nil
            checks.append(failure)
            model.connection.cancel()
            model.notice = "真机验证未通过：\(stage)"
            write(stage: stage, terminal: true, model: model)
        }
    }
    private static func progress(_ stage: String, _ model: AppModel) {
        model.notice = "真机验证：\(stage)"; write(stage: stage, terminal: false, model: model)
    }
    private static func sample(_ model: AppModel) { peakMemory = max(peakMemory, model.tunnel.runtime?.memoryBytes ?? 0) }
    private static func traffic(_ model: AppModel) -> Int64 {
        let root = (try? JSONSerialization.jsonObject(with: Data((model.tunnel.runtime?.trafficJSON ?? "{}").utf8))) as? [String: Any] ?? [:]
        return ((root["upTotal"] as? NSNumber)?.int64Value ?? 0) + ((root["downTotal"] as? NSNumber)?.int64Value ?? 0)
    }
    private static func waitForFlow(_ model: AppModel) async throws {
        for _ in 0..<200 {
            sample(model)
            if [.ready, .limited].contains(model.connection.step) { await model.refreshGroups(); return }
            if model.connection.step == .failed { throw DashError.message("Connection flow failed") }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw DashError.message("Connection flow timed out")
    }
    private static func waitForStop(_ model: AppModel) async throws {
        for _ in 0..<40 {
            if model.connection.step == .idle && model.tunnel.phase == .stopped { return }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw DashError.message("Stop timed out")
    }
    private static func checkHTTPS(_ address: String, expected: Int, label: String) async throws {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData; config.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(from: URL(string: address + "?clashdash=" + UUID().uuidString)!)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        checks.append(["check": label, "passed": code == expected, "httpStatus": code, "bytes": data.count])
        guard code == expected else { throw DashError.message("Unexpected HTTP status") }
    }
    private static func write(stage: String, terminal: Bool, model: AppModel) {
        sample(model)
        let report: [String: Any] = ["platform": "physical iPhone Packet Tunnel", "appVersion": DashConstants.appVersion, "mode": mode, "runID": runID, "stage": stage,
            "terminal": terminal, "passed": terminal && stage == "completed" && checks.allSatisfy { $0["passed"] as? Bool == true },
            "checks": checks, "sampledPeakCoreMemoryBytes": peakMemory, "systemState": model.tunnel.state.rawValue,
            "timestamp": ISO8601DateFormatter().string(from: Date())]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var folder = directory; var values = URLResourceValues(); values.isExcludedFromBackup = true; try? folder.setResourceValues(values)
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("result.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }
}

private final class DeviceDNSProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Error>?
    private var connection: NWConnection?
    private let id = UInt16.random(in: 1...65535)
    static func query() async throws -> Bool { try await DeviceDNSProbe().run() }
    private func run() async throws -> Bool {
        try await withCheckedThrowingContinuation { pending in
            continuation = pending
            let connection = NWConnection(host: "1.1.1.1", port: 53, using: .udp); self.connection = connection
            let queue = DispatchQueue(label: "app.clashdash.validation.dns")
            connection.stateUpdateHandler = { [self] state in
                if case .ready = state {
                    var bytes: [UInt8] = [UInt8(id >> 8), UInt8(id & 255), 1, 0, 0, 1, 0, 0, 0, 0, 0, 0]
                    for part in ["www", "apple", "com"] { bytes.append(UInt8(part.utf8.count)); bytes.append(contentsOf: part.utf8) }
                    bytes.append(contentsOf: [0, 0, 1, 0, 1])
                    connection.send(content: Data(bytes), completion: .contentProcessed { [self] error in if let error { finish(.failure(error)) } })
                    connection.receiveMessage { [self] data, _, _, error in
                        if let error { finish(.failure(error)); return }
                        let bytes = [UInt8](data ?? Data())
                        let valid = bytes.count >= 12 && bytes[0] == UInt8(id >> 8) && bytes[1] == UInt8(id & 255) && bytes[2] & 128 != 0 && bytes[3] & 15 == 0 && (bytes[6] != 0 || bytes[7] != 0)
                        finish(.success(valid))
                    }
                } else if case .failed(let error) = state { finish(.failure(error)) }
            }
            queue.asyncAfter(deadline: .now() + 12) { [self] in finish(.failure(DashError.message("UDP DNS timeout"))) }
            connection.start(queue: queue)
        }
    }
    private func finish(_ value: Result<Bool, Error>) {
        lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
        connection?.stateUpdateHandler = nil; connection?.cancel(); pending?.resume(with: value)
    }
}
#endif
