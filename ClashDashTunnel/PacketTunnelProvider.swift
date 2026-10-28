@preconcurrency import Clash
import Foundation
import Network
import NetworkExtension
import os
import ClashDashKit

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private var engine: TunnelEngine?
    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        guard engine == nil,
              let configuration = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration,
              let idText = configuration["profileID"] as? String, let profileID = UUID(uuidString: idText),
              let generation = configuration["generation"] as? String, UUID(uuidString: generation) != nil,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: DashConstants.appGroup) else {
            completionHandler(DashError.message("VPN 配置不完整，请重新选择配置后连接。")); return
        }
        let startupID = configuration["startupID"] as? String
        TunnelStartupStatus.write(to: container, generation: generation, phase: "loading", startupID: startupID)
        let runtime = TunnelEngine(provider: self, generation: generation)
        let working = container.appendingPathComponent("Runtime/\(profileID.uuidString)/\(generation)", isDirectory: true)
        engine = runtime
        Task {
            do {
                let group = Bundle.main.object(forInfoDictionaryKey: "DashKeychainGroup") as? String
                let store = ProfileStore(root: container.appendingPathComponent("Profiles"), keyProvider: KeychainKeyProvider(accessGroup: group))
                let envelope = try await store.envelope(profileID: profileID, generation: generation)
                let preferences = try await store.library().profiles.first { $0.id == profileID }
                // A previous extension may have been killed before teardown. Rebuild only from sealed snapshots.
                let runtimeRoot = container.appendingPathComponent("Runtime", isDirectory: true)
                if FileManager.default.fileExists(atPath: runtimeRoot.path) { try FileManager.default.removeItem(at: runtimeRoot) }
                try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: working.path)
                var protectedWorking = working; var protection = URLResourceValues(); protection.isExcludedFromBackup = true
                try protectedWorking.setResourceValues(protection)
                for descriptor in envelope.resources ?? [] {
                    let data = try await store.resource(profileID: profileID, descriptor: descriptor)
                    let target = working.appendingPathComponent(descriptor.relativePath)
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: target, options: .atomic)
                    try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: target.path)
                }
                for descriptor in envelope.geodata ?? [] {
                    try await store.materializeGeodata(profileID: profileID, descriptor: descriptor, directory: working)
                }
                TunnelStartupStatus.write(to: container, generation: generation, phase: "starting", startupID: startupID)
                let summary = preferences?.versions.first { $0.id == generation }?.summary
                let groups = summary.map { ProxySelection.configurationGroups(summary: $0) + [ProxySelection.globalGroup(summary: $0)] } ?? []
                let selections = ProxySelection.defaultSelections(groups: groups, saved: preferences?.selections ?? [:])
                runtime.start(text: envelope.runtime, container: container, profileID: profileID,
                              selections: selections, mode: preferences?.preferredMode ?? .rule) { [weak self, weak runtime] error in
                    TunnelStartupStatus.write(to: container, generation: generation, phase: error == nil ? "ready" : "failed", startupID: startupID,
                                              failure: error?.localizedDescription)
                    if error != nil, self?.engine === runtime { self?.engine = nil }
                    completionHandler(error)
                }
            } catch {
                let failure: String
                if case DashError.message(let message) = error { failure = message }
                else { failure = "无法读取已保存的订阅资源（\((error as NSError).domain) / \((error as NSError).code)）。请重新导入这份订阅。" }
                TunnelStartupStatus.write(to: container, generation: generation, phase: "failed", startupID: startupID, failure: failure)
                try? FileManager.default.removeItem(at: working)
                if engine === runtime { engine = nil }
                completionHandler(error)
            }
        }
    }
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        guard let engine else { completionHandler(); return }
        self.engine = nil
        engine.stop(completion: completionHandler)
    }
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let engine else { completionHandler?(nil); return }
        engine.handle(messageData) { completionHandler?($0) }
    }
    override func sleep(completionHandler: @escaping () -> Void) { completionHandler() }
    override func wake() { engine?.wake() }
}

private final class TunnelEngine: NSObject, ClashPlatformInterfaceProtocol, @unchecked Sendable {
    private weak var provider: PacketTunnelProvider?
    private let generation: String
    private let sessionID = UUID().uuidString
    private let queue = DispatchQueue(label: "app.clashdash.core", qos: .userInitiated)
    private let pathQueue = DispatchQueue(label: "app.clashdash.path")
    private let probeQueue = DispatchQueue(label: "app.clashdash.probes", qos: .utility, attributes: .concurrent)
    private let lock = NSLock()
    private let lifecycle = ProviderLifecycle()
    private var service: ClashBoxService?
    private var bridge: PacketFlowBridge?
    private var monitor: ApplePhysicalPathMonitor?
    private var path: PhysicalPathSnapshot?
    private var listener: (any ClashInterfaceUpdateListenerProtocol)?
    private var startedAt = Date()
    private var recentEvents: [String] = []
    private var responses: [UUID: Data] = [:]
    private var responseOrder: [UUID] = []
    private var tunnelAddresses = Set<String>()
    private var isStopping = false
    private var activeProbes = 0
    private var workingDirectory: URL?
    private var temporaryDirectory: URL?
    private let log = Logger(subsystem: "app.clashdash.ios", category: "Tunnel")

    init(provider: PacketTunnelProvider, generation: String) { self.provider = provider; self.generation = generation }
    func start(text: String, container: URL, profileID: UUID, selections: [String: String], mode: RoutingMode, completion: @escaping (Error?) -> Void) {
        queue.async { [self] in
            do {
                workingDirectory = container.appendingPathComponent("Runtime/\(profileID.uuidString)/\(generation)", isDirectory: true)
                try lifecycle.beginStart()
                guard !stopping else { throw CancellationError() }
                let pathReady = DispatchSemaphore(value: 0)
                let pathMonitor = ApplePhysicalPathMonitor()
                pathMonitor.updateHandler = { [weak self] snapshot in
                    guard let self else { return }
                    self.lock.lock(); self.path = snapshot; let target = self.listener; self.lock.unlock()
                    if snapshot.isReady { pathReady.signal() }
                    target?.updateDefaultInterface(snapshot.interfaceName, interfaceIndex: Int32(bitPattern: snapshot.interfaceIndex),
                                                   isExpensive: snapshot.expensive, isConstrained: snapshot.constrained,
                                                   supportsIPv4: snapshot.supportsIPv4, supportsIPv6: snapshot.supportsIPv6)
                }
                monitor = pathMonitor; pathMonitor.start(queue: pathQueue)
                guard pathReady.wait(timeout: .now() + 8) == .success else { throw DashError.message("没有可用的 Wi-Fi 或蜂窝网络。") }
                let working = container.appendingPathComponent("Runtime/\(profileID.uuidString)/\(generation)", isDirectory: true)
                try FileManager.default.createDirectory(at: working.appendingPathComponent("providers"), withIntermediateDirectories: true)
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: working.path)
                var protectedWorking = working; var protection = URLResourceValues(); protection.isExcludedFromBackup = true
                try protectedWorking.setResourceValues(protection)
                let temporary = container.appendingPathComponent("Temporary", isDirectory: true)
                if FileManager.default.fileExists(atPath: temporary.path) { try FileManager.default.removeItem(at: temporary) }
                try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
                temporaryDirectory = temporary
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: temporary.path)
                var protectedTemporary = temporary; try protectedTemporary.setResourceValues(protection)
                let options = ClashSetupOptions()
                let control = try TunnelPaths.controlDirectory(in: container)
                try FileManager.default.createDirectory(at: control, withIntermediateDirectories: true)
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: control.path)
                var protectedControl = control; try protectedControl.setResourceValues(protection)
                options.basePath = control.path; options.workingPath = working.path; options.tempPath = temporary.path
                options.runtimeProfile = "iosPacketTunnel"; options.maxProcs = 4
                options.tunMTU = 1400; options.logMaxLines = 100; options.timeZone = TimeZone.current.identifier
                options.ipQueryMode = "config"; options.tunIPv6Mode = "config"
                options.systemDNSServerLines = ClashSystemResolverLines()
                options.includeAllNetworks = false
                var error: NSError?
                ClashSetup(options, &error)
                if let error { throw error }
                let gc = ClashRuntimeSetupOptions(); gc.gcPercent = 10
                ClashReloadSetupOptions(gc, &error)
                if let error { throw error }
                _ = ClashApplyRemoteControl("{\"enabled\":false}")
                guard let core = ClashNewService(self, &error) else { throw error ?? DashError.message("无法创建网络核心。") }
                service = core
                try core.start(text)
                for (group, member) in selections {
                    var selectionError: NSError?
                    _ = ClashSelectProxy(group, member, &selectionError)
                    // Removed or renamed nodes use the configuration's default selection.
                }
                try core.setMode(mode.rawValue)
                guard !stopping else { throw CancellationError() }
                try lifecycle.didStart(); startedAt = Date()
                record("核心已启动；系统网络设置与 PacketFlow 桥接已就绪。")
                completion(nil)
            } catch {
                teardown(); lifecycle.didFailStart()
                record("启动失败。请在 App 中检查配置与网络。")
                let ns = error as NSError
                log.error("Tunnel start failed: \(ns.domain, privacy: .public) / \(ns.code)")
                completion(DashError.message("连接失败：\(Self.safeError(error.localizedDescription))"))
            }
        }
    }
    func stop(completion: @escaping () -> Void) {
        lock.lock(); isStopping = true; lock.unlock()
        _ = lifecycle.beginStop()
        queue.async { [self] in teardown(); lifecycle.didStop(); completion() }
    }
    func wake() { queue.async { [weak self] in self?.service?.wake() } }
    private var stopping: Bool { lock.lock(); defer { lock.unlock() }; return isStopping }
    private func teardown() {
        try? service?.close(); service = nil
        lock.lock(); let previous = bridge; bridge = nil; listener = nil; lock.unlock()
        previous?.stop(); monitor?.cancel(); monitor = nil
        if let workingDirectory { try? FileManager.default.removeItem(at: workingDirectory) }
        if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
        workingDirectory = nil
        temporaryDirectory = nil
    }
    private func record(_ text: String) {
        lock.lock(); recentEvents.append(text)
        if recentEvents.count > 50 { recentEvents.removeFirst(recentEvents.count - 50) }; lock.unlock()
    }
    func writeLog(_ message: String?) {
        // Full core messages can contain domains, node credentials and subscription URLs.
        // Keep only lifecycle messages authored by this adapter in the exportable ring.
    }
    private static func safeError(_ value: String) -> String {
        var result = value
        for pattern in ["https?://[^\\s\\\"]+", "(?i)(password|uuid|token|secret|authorization)[:= ]+[^ ,;\\n]+"] {
            if let expression = try? NSRegularExpression(pattern: pattern) {
                result = expression.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "[已隐藏]")
            }
        }
        return String(result.prefix(280))
    }
    func openTun(_ options: (any ClashTunOptionsProtocol)?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        guard let options, let ret0_, let provider, !stopping else { throw CancellationError() }
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        guard (1280...9000).contains(Int(options.getMTU())) else { throw DashError.message("配置的 MTU 无效。") }
        settings.mtu = NSNumber(value: options.getMTU())
        let dns = try options.getDNSServerAddress().value
        guard !dns.isEmpty else { throw DashError.message("核心没有提供隧道 DNS 地址。") }
        let dnsSettings = NEDNSSettings(servers: [dns]); dnsSettings.matchDomains = [""]; dnsSettings.matchDomainsNoSearch = true
        settings.dnsSettings = dnsSettings
        var v4: [String] = []; var masks: [String] = []
        if let iterator = options.getInet4Address() {
            while iterator.hasNext(), let prefix = iterator.next() { v4.append(prefix.address()); masks.append(prefix.mask()) }
        }
        if !v4.isEmpty {
            let ipv4 = NEIPv4Settings(addresses: v4, subnetMasks: masks)
            var included: [NEIPv4Route] = []
            if let iterator = options.getInet4RouteAddress() {
                while iterator.hasNext(), let prefix = iterator.next() { included.append(NEIPv4Route(destinationAddress: prefix.address(), subnetMask: prefix.mask())) }
            }
            var excluded: [NEIPv4Route] = []
            if let iterator = options.getInet4RouteExcludeAddress() {
                while iterator.hasNext(), let prefix = iterator.next() { excluded.append(NEIPv4Route(destinationAddress: prefix.address(), subnetMask: prefix.mask())) }
            }
            ipv4.includedRoutes = included.isEmpty ? [.default()] : included; ipv4.excludedRoutes = excluded
            settings.ipv4Settings = ipv4
        }
        var v6: [String] = []; var lengths: [NSNumber] = []
        if let iterator = options.getInet6Address() {
            while iterator.hasNext(), let prefix = iterator.next() { v6.append(prefix.address()); lengths.append(NSNumber(value: prefix.prefix())) }
        }
        if !v6.isEmpty {
            let ipv6 = NEIPv6Settings(addresses: v6, networkPrefixLengths: lengths)
            var included: [NEIPv6Route] = []
            if let iterator = options.getInet6RouteAddress() {
                while iterator.hasNext(), let prefix = iterator.next() { included.append(NEIPv6Route(destinationAddress: prefix.address(), networkPrefixLength: NSNumber(value: prefix.prefix()))) }
            }
            var excluded: [NEIPv6Route] = []
            if let iterator = options.getInet6RouteExcludeAddress() {
                while iterator.hasNext(), let prefix = iterator.next() { excluded.append(NEIPv6Route(destinationAddress: prefix.address(), networkPrefixLength: NSNumber(value: prefix.prefix()))) }
            }
            ipv6.includedRoutes = included.isEmpty ? [.default()] : included; ipv6.excludedRoutes = excluded
            settings.ipv6Settings = ipv6
        }
        let completed = DispatchSemaphore(value: 0)
        let box = SettingsResult()
        provider.setTunnelNetworkSettings(settings) { error in box.set(error); completed.signal() }
        guard completed.wait(timeout: .now() + 20) == .success else { throw DashError.message("系统应用 VPN 网络设置超时。") }
        if let error = box.error { throw error }
        guard !stopping else { throw CancellationError() }
        let transport = PacketFlowBridge(packetFlow: provider.packetFlow, maxPendingBytes: 1024 * 1024) { [weak provider] error in
            provider?.cancelTunnelWithError(error)
        }
        let descriptor = try transport.start()
        lock.lock(); bridge = transport; tunnelAddresses = Set(v4 + v6); lock.unlock()
        ret0_.pointee = descriptor
    }
    func underNetworkExtension() -> Bool { true }
    func usePlatformAutoDetectControl() -> Bool { false }
    func autoDetectControl(_ fd: Int32) throws {
        lock.lock(); let index = path?.interfaceIndex ?? 0; lock.unlock()
        try PhysicalEgressBinding.apply(.decision(interfaceIndex: index), to: fd)
    }
    func startDefaultInterfaceMonitor(_ listener: (any ClashInterfaceUpdateListenerProtocol)?) throws {
        lock.lock(); self.listener = listener; let current = path; lock.unlock()
        guard let current, current.isReady else { throw DashError.message("物理网络尚未就绪。") }
        listener?.updateDefaultInterface(current.interfaceName, interfaceIndex: Int32(bitPattern: current.interfaceIndex), isExpensive: current.expensive,
                                         isConstrained: current.constrained, supportsIPv4: current.supportsIPv4, supportsIPv6: current.supportsIPv6)
    }
    func closeDefaultInterfaceMonitor(_ listener: (any ClashInterfaceUpdateListenerProtocol)?) throws {
        lock.lock(); self.listener = nil; lock.unlock()
    }
    func getInterfaces() throws -> any ClashNetworkInterfaceIteratorProtocol {
        lock.lock(); let current = path; let own = tunnelAddresses; lock.unlock()
        return InterfaceIterator(PhysicalInterfaceInventory.build(raw: PhysicalInterfaceInventory.enumerate(), available: current?.availableInterfaces ?? [],
            pathIsExpensive: current?.expensive ?? false, defaultInterfaceIndex: current?.interfaceIndex ?? 0, ownTunnelAddresses: own))
    }
    func handle(_ data: Data, completion: @escaping (Data?) -> Void) {
        guard data.count <= 32 * 1024, let request = try? JSONDecoder().decode(TunnelRequest.self, from: data) else { completion(nil); return }
        if request.method == "delay" {
            handleProbe(request, completion: completion)
            return
        }
        #if DEBUG
        if request.method == "validation-udp" { handleProbe(request, completion: completion); return }
        #endif
        let operation = { [self] in
            var reply = TunnelReply(requestID: request.requestID, sessionID: sessionID, generation: generation)
            do {
                guard request.protocolVersion == DashConstants.protocolVersion else { throw DashError.message("扩展协议版本不匹配。") }
                guard request.sessionID == nil || request.sessionID == sessionID else { throw DashError.message("连接会话已改变，请刷新状态。") }
                guard lifecycle.state == .running, let service else { throw DashError.message("网络核心尚未就绪。") }
                if let cached = responses[request.requestID] { completion(cached); return }
                switch request.method {
                case "snapshot":
                    let info = RuntimeInfo(sessionID: sessionID, generation: generation, startedAt: startedAt, coreVersion: ClashVersion(), mode: service.mode(),
                                           memoryBytes: UInt64(max(ClashMemoryFootprint(), 0)), trafficJSON: ClashTrafficJSON(), statusJSON: ClashStatusJSON())
                    reply.payload = try JSONEncoder().encode(info)
                case "proxies": reply.payload = Data(ClashProxiesJSON().utf8)
                case "connections": reply.payload = Data(ClashConnectionsJSON().utf8)
                case "mode":
                    guard let value = request.parameters["mode"], RoutingMode(rawValue: value) != nil else { throw DashError.message("无效模式。") }
                    try service.setMode(value); reply.payload = Data("{}".utf8)
                case "select":
                    guard let group = request.parameters["group"], let name = request.parameters["name"] else { throw DashError.message("缺少代理组或节点。") }
                    var error: NSError?; ClashSelectProxy(group, name, &error)
                    if let error { throw error }; reply.payload = Data("{}".utf8)
                case "close":
                    guard let id = request.parameters["id"] else { throw DashError.message("缺少连接标识。") }
                    reply.payload = try JSONSerialization.data(withJSONObject: ["closed": ClashCloseConnection(id)])
                case "events":
                    lock.lock(); let events = recentEvents; lock.unlock(); reply.payload = try JSONEncoder().encode(events)
                default: throw DashError.message("扩展不支持这个操作。")
                }
            } catch { reply.error = Self.safeError(error.localizedDescription) }
            guard let encoded = try? JSONEncoder().encode(reply), encoded.count <= 512 * 1024 else {
                reply.payload = nil; reply.error = "数据量过大，请缩小配置或连接列表后重试。"; completion(try? JSONEncoder().encode(reply)); return
            }
            if ["mode", "select", "close"].contains(request.method) {
                responses[request.requestID] = encoded; responseOrder.append(request.requestID)
                while responseOrder.count > 16 { responses.removeValue(forKey: responseOrder.removeFirst()) }
            }
            completion(encoded)
        }
        queue.async(execute: operation)
    }
    private func handleProbe(_ request: TunnelRequest, completion: @escaping (Data?) -> Void) {
        lock.lock()
        let admitted = activeProbes < 3 && !isStopping
        if admitted { activeProbes += 1 }
        lock.unlock()
        guard admitted else {
            completion(try? JSONEncoder().encode(TunnelReply(requestID: request.requestID, sessionID: sessionID, generation: generation, error: "已有三个测速任务，请稍后重试。")))
            return
        }
        probeQueue.async { [self] in
            defer { lock.lock(); activeProbes -= 1; lock.unlock() }
            var reply = TunnelReply(requestID: request.requestID, sessionID: sessionID, generation: generation)
            if request.protocolVersion != DashConstants.protocolVersion || (request.sessionID != nil && request.sessionID != sessionID) || lifecycle.state != .running {
                reply.error = "连接会话已改变，请刷新后重试。"
            } else if let name = request.parameters["name"] {
                #if DEBUG
                if request.method == "validation-udp" {
                    let query: [String: Any] = ["domain": "www.apple.com", "protocol": "udp", "server": "udp://1.1.1.1:53#" + name, "types": ["A"], "timeoutMilliseconds": 10000]
                    let text = String(decoding: (try? JSONSerialization.data(withJSONObject: query, options: [.withoutEscapingSlashes])) ?? Data(), as: UTF8.self)
                    let result = (try? JSONSerialization.jsonObject(with: Data(ClashScriptDNSQueryJSON(text).utf8))) as? [String: Any] ?? [:]
                    let passed = result["error"] == nil && result["fromCache"] as? Bool == false && !(result["answers"] as? [Any] ?? []).isEmpty
                    let code = (result["error"] as? [String: Any])?["code"] as? String ?? ""
                    reply.payload = try? JSONSerialization.data(withJSONObject: ["passed": passed, "errorCode": code])
                } else {
                    let delay = ClashURLTest(name, "https://cp.cloudflare.com/generate_204")
                    reply.payload = try? JSONSerialization.data(withJSONObject: ["delay": delay])
                }
                #else
                let delay = ClashURLTest(name, "https://cp.cloudflare.com/generate_204")
                reply.payload = try? JSONSerialization.data(withJSONObject: ["delay": delay])
                #endif
            } else { reply.error = "缺少节点名称。" }
            completion(try? JSONEncoder().encode(reply))
        }
    }
}

private final class SettingsResult: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Error?
    var error: Error? { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ error: Error?) { lock.lock(); value = error; lock.unlock() }
}

private final class InterfaceIterator: NSObject, ClashNetworkInterfaceIteratorProtocol {
    private var records: ArraySlice<PhysicalInterfaceInventory.Record>
    private let count: Int32
    init(_ values: [PhysicalInterfaceInventory.Record]) { records = values[...]; count = Int32(clamping: values.count) }
    func len() -> Int32 { count }
    func hasNext() -> Bool { !records.isEmpty }
    func next() -> ClashNetworkInterface? {
        guard let value = records.popFirst() else { return nil }
        let result = ClashNetworkInterface(); result.name = value.name; result.index = Int32(bitPattern: value.index)
        result.mtu = value.mtu; result.flags = value.flags.rawValue; result.type = value.type.rawValue
        result.metered = value.metered; result.addresses = StringIterator(value.addresses); return result
    }
}
private final class StringIterator: NSObject, ClashStringIteratorProtocol {
    private var values: ArraySlice<String>
    private let count: Int32
    init(_ strings: [String]) { values = strings[...]; count = Int32(clamping: strings.count) }
    func len() -> Int32 { count }
    func hasNext() -> Bool { !values.isEmpty }
    func next() -> String { values.popFirst() ?? "" }
}
