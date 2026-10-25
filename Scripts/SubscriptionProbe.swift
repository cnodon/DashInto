// Opt-in real subscription experiment. Only protocol labels, counts and outcomes leave this process.
import Foundation
import Network
import Clash
import Darwin

final class SubscriptionPlatform: NSObject, ClashPlatformInterfaceProtocol {
    let monitor = ApplePhysicalPathMonitor()
    let lock = NSLock()
    var path: PhysicalPathSnapshot?
    var listener: (any ClashInterfaceUpdateListenerProtocol)?
    func prepare() throws {
        let ready = DispatchSemaphore(value: 0)
        monitor.updateHandler = { [weak self] value in
            guard let self else { return }
            self.lock.lock(); self.path = value; let listener = self.listener; self.lock.unlock()
            if value.isReady { ready.signal() }
            listener?.updateDefaultInterface(value.interfaceName, interfaceIndex: Int32(bitPattern: value.interfaceIndex), isExpensive: value.expensive,
                                             isConstrained: value.constrained, supportsIPv4: value.supportsIPv4, supportsIPv6: value.supportsIPv6)
        }
        monitor.start(queue: DispatchQueue(label: "clashdash.lab.path"))
        guard ready.wait(timeout: .now() + 8) == .success else { throw NSError(domain: "NoPhysicalNetwork", code: 1) }
    }
    func writeLog(_ message: String?) {}
    func underNetworkExtension() -> Bool { false }
    func usePlatformAutoDetectControl() -> Bool { false }
    func autoDetectControl(_ fd: Int32) throws {
        lock.lock(); let index = path?.interfaceIndex ?? 0; lock.unlock()
        try PhysicalEgressBinding.apply(.decision(interfaceIndex: index), to: fd)
    }
    func openTun(_ options: (any ClashTunOptionsProtocol)?, ret0_: UnsafeMutablePointer<Int32>?) throws { throw NSError(domain: "NoSystemTunnelInLab", code: 1) }
    func startDefaultInterfaceMonitor(_ listener: (any ClashInterfaceUpdateListenerProtocol)?) throws {
        lock.lock(); self.listener = listener; let current = path; lock.unlock()
        guard let current else { throw NSError(domain: "NoPhysicalNetwork", code: 2) }
        listener?.updateDefaultInterface(current.interfaceName, interfaceIndex: Int32(bitPattern: current.interfaceIndex), isExpensive: current.expensive,
                                         isConstrained: current.constrained, supportsIPv4: current.supportsIPv4, supportsIPv6: current.supportsIPv6)
    }
    func closeDefaultInterfaceMonitor(_ listener: (any ClashInterfaceUpdateListenerProtocol)?) throws { lock.lock(); self.listener = nil; lock.unlock() }
    func getInterfaces() throws -> any ClashNetworkInterfaceIteratorProtocol {
        lock.lock(); let current = path; lock.unlock()
        return SubscriptionInterfaces(PhysicalInterfaceInventory.build(raw: PhysicalInterfaceInventory.enumerate(), available: current?.availableInterfaces ?? [],
            pathIsExpensive: current?.expensive ?? false, defaultInterfaceIndex: current?.interfaceIndex ?? 0, ownTunnelAddresses: []))
    }
}
final class SubscriptionInterfaces: NSObject, ClashNetworkInterfaceIteratorProtocol {
    var values: ArraySlice<PhysicalInterfaceInventory.Record>
    let count: Int32
    init(_ records: [PhysicalInterfaceInventory.Record]) { values = records[...]; count = Int32(records.count) }
    func len() -> Int32 { count }
    func hasNext() -> Bool { !values.isEmpty }
    func next() -> ClashNetworkInterface? {
        guard let value = values.popFirst() else { return nil }
        let result = ClashNetworkInterface(); result.name = value.name; result.index = Int32(bitPattern: value.index)
        result.mtu = value.mtu; result.flags = value.flags.rawValue; result.type = value.type.rawValue
        result.metered = value.metered; result.addresses = SubscriptionStrings(value.addresses); return result
    }
}
final class SubscriptionStrings: NSObject, ClashStringIteratorProtocol {
    var values: ArraySlice<String>; let count: Int32
    init(_ input: [String]) { values = input[...]; count = Int32(input.count) }
    func len() -> Int32 { count }
    func hasNext() -> Bool { !values.isEmpty }
    func next() -> String { values.popFirst() ?? "" }
}

@main struct SubscriptionProbeMain {
static func main() {
let root = URL(fileURLWithPath: CommandLine.arguments[1])
do {
    let payload = try Data(contentsOf: root.appendingPathComponent("subscription.yaml"))
    var error: NSError?
    guard let box = ClashInspectProxyPayloadForIOS(payload, "subscriptionBody", &error), error == nil,
          let document = try JSONSerialization.jsonObject(with: Data(box.value.utf8)) as? [String: Any],
          var nodes = document["proxies"] as? [[String: Any]], !nodes.isEmpty else { throw NSError(domain: "SubscriptionParse", code: 1) }
    nodes = Array(nodes.prefix(100))
    let types = nodes.map { $0["type"] as? String ?? "unknown" }
    let onlyProtocol = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil
    let selectedIndices = nodes.indices.filter { onlyProtocol == nil || types[$0] == onlyProtocol }
    guard !selectedIndices.isEmpty else { throw NSError(domain: "SubscriptionParse", code: 2) }
    let enableUDPForExperiment = CommandLine.arguments.contains("--enable-udp")
    if enableUDPForExperiment {
        for index in selectedIndices where nodes[index]["udp"] == nil { nodes[index]["udp"] = true }
    }
    for index in nodes.indices { nodes[index]["name"] = "ValidationNode-\(index)" }
    let names = nodes.indices.map { "ValidationNode-\($0)" }
    let config: [String: Any] = ["mode": "rule", "log-level": "silent", "ipv6": false, "proxies": nodes,
        "proxy-groups": [["name": "Select", "type": "select", "proxies": names]], "rules": ["MATCH,Select"],
        "tun": ["enable": false], "dns": ["enable": true, "enhanced-mode": "redir-host", "nameserver": ["udp://1.1.1.1:53#Select"],
        "proxy-server-nameserver": ["223.5.5.5", "1.1.1.1"], "default-nameserver": ["223.5.5.5", "1.1.1.1"]]]
    let platform = SubscriptionPlatform(); try platform.prepare()
    let working = root.appendingPathComponent("NetworkProbe"); try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
    let setup = ClashSetupOptions(); setup.basePath = working.path; setup.workingPath = working.path; setup.tempPath = working.path
    setup.runtimeProfile = "macosApplication"; setup.maxProcs = 3; setup.logMaxLines = 0
    ClashSetup(setup, &error)
    guard error == nil else { throw NSError(domain: "CoreSetup", code: 1) }
    guard let core = ClashNewService(platform, &error), error == nil else { throw NSError(domain: "CoreSetup", code: 2) }
    defer { try? core.close(); platform.monitor.cancel() }
    let text = String(decoding: try JSONSerialization.data(withJSONObject: config, options: [.withoutEscapingSlashes]), as: UTF8.self)
    try core.start(text)
    let queue = OperationQueue(); queue.maxConcurrentOperationCount = 3
    let resultsLock = NSLock(); var results: [(Int, Int32)] = []
    for index in selectedIndices {
        queue.addOperation {
            var delay = ClashURLTest(names[index], "https://cp.cloudflare.com/generate_204")
            if delay < 0 { delay = ClashURLTest(names[index], "https://cp.cloudflare.com/generate_204") }
            resultsLock.lock(); results.append((index, delay)); resultsLock.unlock()
            print("NODE_RESULT", types[index], index + 1, delay >= 0 ? "passed" : "unreachable")
        }
    }
    queue.waitUntilAllOperationsAreFinished()
    var protocols: [[String: Any]] = []
    for kind in Set(selectedIndices.map { types[$0] }).sorted() {
        let tested = results.filter { types[$0.0] == kind }
        let healthy = tested.filter { $0.1 >= 0 }.sorted { $0.1 < $1.1 }
        var udp = false
        var udpAttempts: [[String: Any]] = []
        var udpOption: Any = NSNull()
        if let best = healthy.first ?? tested.first {
            udpOption = nodes[best.0]["udp"] ?? NSNull()
            error = nil; _ = ClashSelectProxy("Select", names[best.0], &error)
            guard error == nil else { throw NSError(domain: "ProxySelection", code: 1) }
            // A fresh standalone UDP client bypasses resolver caches and explicitly targets this node.
            for resolver in ["1.1.1.1", "223.5.5.5", "8.8.8.8"] {
                let query: [String: Any] = ["domain": "www.apple.com", "protocol": "udp", "server": "udp://\(resolver):53#" + names[best.0], "types": ["A"], "timeoutMilliseconds": 10000]
                let request = String(decoding: try JSONSerialization.data(withJSONObject: query, options: [.withoutEscapingSlashes]), as: UTF8.self)
                let reply = ClashScriptDNSQueryJSON(request)
                let response = (try? JSONSerialization.jsonObject(with: Data(reply.utf8))) as? [String: Any] ?? [:]
                udp = response["error"] == nil && response["fromCache"] as? Bool == false && !(response["answers"] as? [Any] ?? []).isEmpty
                let code = (response["error"] as? [String: Any])?["code"] as? String ?? (udp ? "OK" : "NO_ANSWER")
                udpAttempts.append(["resolver": resolver, "passed": udp, "errorCode": code])
                if udp { break }
            }
        }
        protocols.append(["protocol": kind, "tested": tested.count, "tcpHTTPSHealthy": healthy.count, "bestDelayMS": healthy.first?.1 ?? -1,
                          "udpDNSPassed": udp, "udpConfigured": udpOption, "udpAttempts": udpAttempts])
    }
    try core.setMode("global"); let global = core.mode() == "global"
    try core.setMode("rule"); let rule = core.mode() == "rule"
    let report: [String: Any] = ["platform": "macOS userland, not iOS Packet Tunnel", "nodeCount": nodes.count, "protocols": protocols, "testOnlyUDPOverride": enableUDPForExperiment,
        "modeChangesPassed": global && rule, "memoryBytes": ClashMemoryFootprint(), "coreVersion": ClashVersion()]
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    let reportName = onlyProtocol == nil ? "network-report.json" : "network-report-\(onlyProtocol!)\(enableUDPForExperiment ? "-udp-enabled" : "").json"
    try data.write(to: root.appendingPathComponent(reportName))
    print("SANITIZED_REPORT", String(decoding: data, as: UTF8.self))
    if protocols.contains(where: { ($0["tcpHTTPSHealthy"] as? Int ?? 0) == 0 || $0["udpDNSPassed"] as? Bool != true }) { exit(1) }
} catch {
    let ns = error as NSError
    let errorFile = root.appendingPathComponent("network-private-error.txt")
    try? ns.localizedDescription.write(to: errorFile, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: errorFile.path)
    let localDomains: Set<String> = ["SubscriptionParse", "NoPhysicalNetwork", "CoreSetup", "NoSystemTunnelInLab"]
    print("VALIDATION_FAILED", localDomains.contains(ns.domain) ? ns.domain : "NativeCore", ns.code)
    exit(1)
}
}
}
