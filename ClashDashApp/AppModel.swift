import Foundation
import Observation
import ClashDashKit

enum AppTab: Int { case home, subscriptions, proxies, device, settings }

@Observable @MainActor
final class AppModel {
    var library = ProfileLibrary()
    let tunnel: TunnelController
    let connection: ConnectionCoordinator
    var selectedTab: AppTab = .home
    var showingImport = false
    var importURL = ""
    var errorMessage: String?
    var notice: String?
    var busy = false
    var groups: [ProxyGroup] = []
    var delays: [String: Int] = [:]
    var testingNames: Set<String> = []
    var traffic: [TrafficSample] = []
    var uploadRate = 0.0
    var downloadRate = 0.0
    var uploaded = 0.0
    var downloaded = 0.0
    var refreshingProfileID: UUID?
    let dashboard = DashboardMonitor()
    let updates = AppUpdates()
    var homeGroupName: String?
    var proxyKinds: [String: String] = [:]
    var delayDates: [String: Date] = [:]
    @ObservationIgnored let store: ProfileStore
    @ObservationIgnored private var lastSampleSession: String?
    @ObservationIgnored private var lastGroupRefresh = Date.distantPast
    @ObservationIgnored private var healthyGeneration: String?

    var activeProfile: Profile? { library.activeProfile }
    var runningProfile: Profile? {
        guard tunnel.phase != .stopped, let id = tunnel.configuredProfileID else { return nil }
        return library.profiles.first { $0.id == id }
    }
    var displayProfile: Profile? { runningProfile ?? activeProfile }
    var activeSummary: ConfigurationSummary? {
        if let running = runningProfile, let generation = tunnel.runtime?.generation ?? tunnel.configuredGeneration {
            return running.versions.first { $0.id == generation }?.summary
        }
        return activeProfile?.current?.summary
    }
    var hasPendingUpdate: Bool {
        guard let running = runningProfile, let generation = tunnel.configuredGeneration else { return false }
        return running.selectedVersion != generation
    }
    var mode: RoutingMode { RoutingMode(rawValue: tunnel.runtime?.mode ?? "") ?? displayProfile?.preferredMode ?? .rule }
    var displayGroups: [ProxyGroup] {
        if tunnel.state == .connected { return groups }
        var result = activeSummary?.groups ?? []
        if mode == .global {
            result = [ProxyGroup(name: "GLOBAL", kind: "select", members: ["DIRECT"] + result.map(\.name) + (activeSummary?.nodes.map(\.name) ?? []))]
        }
        return result.map { group in
            var value = group
            value.selected = displayProfile?.selections?[group.name].flatMap { group.members.contains($0) ? $0 : nil }
            return value
        }
    }
    var visibleGroups: [ProxyGroup] { displayGroups.filter { mode == .global ? $0.name == "GLOBAL" : $0.name != "GLOBAL" } }
    var quickGroup: ProxyGroup? { visibleGroups.count == 1 ? visibleGroups.first : nil }
    var homeGroup: ProxyGroup? {
        if let name = homeGroupName, let group = visibleGroups.first(where: { $0.name == name }) { return group }
        let fallback = activeSummary?.rules.last(where: { $0.hasPrefix("MATCH,") })?.split(separator: ",").dropFirst().first.map(String.init)
        return visibleGroups.first(where: { $0.name == fallback }) ?? visibleGroups.first
    }
    var homeNode: String? {
        guard tunnel.runtime != nil, let group = homeGroup else { return nil }
        return ProxySelection.resolvedLeaf(group: group.name, groups: groups)
    }
    var canEditRoutes: Bool { !busy && !connection.step.inProgress && (tunnel.phase == .stopped || tunnel.runtime != nil) }
    var routeDescription: String {
        if activeSummary?.isDirectOnly == true { return "仅直连，不提供代理线路" }
        if let group = quickGroup { return group.selected ?? (group.isSelectable ? "使用订阅默认选择" : "由订阅自动选择") }
        return "按不同用途分流 · 无需逐个选择"
    }

    init() {
        let driver = TunnelController()
        tunnel = driver; connection = ConnectionCoordinator(driver: driver)
        let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: DashConstants.appGroup)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ClashDash")
        #if targetEnvironment(simulator)
        let group: String? = nil
        #else
        let group = Bundle.main.object(forInfoDictionaryKey: "DashKeychainGroup") as? String
        #endif
        var profileRoot = container.appendingPathComponent("Profiles")
        #if DEBUG
        if let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--ui-test-library=") }),
           let id = UUID(uuidString: String(argument.dropFirst("--ui-test-library=".count))) {
            profileRoot = container.appendingPathComponent("UITestLibraries").appendingPathComponent(id.uuidString)
        }
        #endif
        store = ProfileStore(root: profileRoot, keyProvider: KeychainKeyProvider(accessGroup: group))
    }
    func load() async {
        do {
            library = try await store.library()
            if !connection.step.inProgress { try await tunnel.load() }
            if !connection.step.inProgress {
                library = try await store.consolidateValidationDuplicate(retainingProfileID: tunnel.phase == .stopped ? nil : tunnel.configuredProfileID)
            }
            try? await store.prune(retaining: [tunnel.configuredGeneration].compactMap { $0 })
        } catch { errorMessage = error.localizedDescription }
    }
    func resume() { tunnel.startPolling { [weak self] in self?.consumeSample() } }
    func suspend() { tunnel.stopPolling(); dashboard.suspend(); traffic = [] }
    func consumeSample() {
        connection.reconcile()
        dashboard.sample(tunnel)
        guard let runtime = tunnel.runtime else { groups = []; traffic = []; return }
        if runtime.sessionID != lastSampleSession {
            lastSampleSession = runtime.sessionID; traffic = []; groups = []; delays = [:]; delayDates = [:]
            uploaded = 0; downloaded = 0; lastGroupRefresh = .distantPast
        }
        let dictionary = (try? JSONSerialization.jsonObject(with: Data(runtime.trafficJSON.utf8))) as? [String: Any] ?? [:]
        uploadRate = (dictionary["up"] as? NSNumber)?.doubleValue ?? 0
        downloadRate = (dictionary["down"] as? NSNumber)?.doubleValue ?? 0
        uploaded = (dictionary["upTotal"] as? NSNumber)?.doubleValue ?? uploaded
        downloaded = (dictionary["downTotal"] as? NSNumber)?.doubleValue ?? downloaded
        traffic.append(TrafficSample(upload: uploadRate, download: downloadRate))
        if traffic.count > 60 { traffic.removeFirst(traffic.count - 60) }
        if healthyGeneration != runtime.generation, let profile = runningProfile {
            healthyGeneration = runtime.generation
            Task { try? await store.markGood(profileID: profile.id, generation: runtime.generation) }
        }
        if Date().timeIntervalSince(lastGroupRefresh) >= 5 {
            lastGroupRefresh = Date(); Task { await refreshGroups() }
        }
    }
    func toggleConnection() async {
        if connection.step.inProgress || tunnel.phase != .stopped { connection.cancel(); return }
        guard let profile = activeProfile else {
            if library.profiles.isEmpty { showingImport = true } else { selectedTab = .subscriptions }
            return
        }
        useAndConnect(profile)
    }
    @discardableResult
    func save(_ prepared: PreparedConfiguration, name: String, url: URL?, usage: SubscriptionUsage?) async throws -> ImportCommit {
        let commit = try await store.commitImport(prepared, name: name, sourceURL: url, usage: usage)
        library = commit.library
        return commit
    }
    func useAndConnect(_ profile: Profile) {
        guard !connection.step.inProgress, !busy else { return }
        selectedTab = .home; notice = nil
        connection.start(profile) { [weak self] in
            guard let self else { throw CancellationError() }
            try Task.checkCancellation()
            self.library = try await self.store.select(profile.id)
            self.groups = []; self.delays = [:]; self.traffic = []; self.healthyGeneration = nil
        }
    }
    func activate(_ profile: Profile) async {
        if tunnel.phase != .stopped { useAndConnect(profile); return }
        await perform {
            self.library = try await self.store.select(profile.id)
            self.groups = []; self.delays = [:]; self.traffic = []
            self.selectedTab = .home
        }
    }
    func delete(_ profile: Profile) async {
        await perform {
            if self.runningProfile?.id == profile.id && self.tunnel.phase != .stopped { try await self.tunnel.waitUntilDisconnected() }
            self.library = try await self.store.delete(profile.id)
        }
    }
    func refresh(_ profile: Profile) async {
        refreshingProfileID = profile.id
        defer { refreshingProfileID = nil }
        await perform {
            let envelope = try await self.store.envelope(profileID: profile.id, generation: profile.selectedVersion)
            guard let source = envelope.sourceURL, let url = URL(string: source) else { throw DashError.message("本地文件没有订阅地址，请重新导入文件。") }
            let result = try await SubscriptionClient().download(url)
            let parsed = try await Task.detached { try NativeConfigImporter.prepare(result.text) }.value
            let prepared = try await NativeResourcePreparer.shared.prepare(parsed)
            self.library = try await self.store.importConfiguration(prepared, name: profile.name, sourceURL: url, replacing: profile.id, usage: result.usage, retaining: [self.tunnel.configuredGeneration].compactMap { $0 })
            try? await self.store.prune(retaining: [self.tunnel.configuredGeneration].compactMap { $0 })
            self.notice = self.tunnel.state.isActive ? "新版本已保存。重新连接后应用。" : "订阅已更新。"
        }
    }
    func rollback(_ profile: Profile, version: ProfileVersion) async {
        await perform {
            if self.runningProfile?.id == profile.id && self.tunnel.phase != .stopped { try await self.tunnel.waitUntilDisconnected() }
            self.library = try await self.store.selectVersion(profileID: profile.id, generation: version.id)
            self.notice = "已恢复所选版本。"
        }
    }
    func refreshGroups() async {
        guard tunnel.state == .connected, let session = tunnel.runtime?.sessionID else { return }
        do {
            let data = try await tunnel.request("proxies")
            guard tunnel.runtime?.sessionID == session else { return }
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let catalog = root["proxies"] as? [String: [String: Any]] ?? [:]
            proxyKinds = catalog.compactMapValues { $0["all"] == nil ? $0["type"] as? String : nil }
            for (name, value) in catalog {
                if let history = (value["history"] as? [[String: Any]])?.last,
                   let delay = history["delay"] as? Int, let timestamp = history["time"] as? String,
                   let date = ISO8601DateFormatter().date(from: timestamp), date > (delayDates[name] ?? .distantPast) {
                    delays[name] = delay > 0 ? delay : -1; delayDates[name] = date
                }
            }
            let order = activeSummary?.groups.map(\.name) ?? []
            groups = catalog.compactMap { name, value in
                guard let members = value["all"] as? [String] else { return nil }
                return ProxyGroup(name: name, kind: value["type"] as? String ?? "select", members: members, selected: value["now"] as? String)
            }.sorted { (order.firstIndex(of: $0.name) ?? Int.max, $0.name) < (order.firstIndex(of: $1.name) ?? Int.max, $1.name) }
        } catch { /* The connection page owns persistent runtime failures. */ }
    }
    func select(group: ProxyGroup, member: String) async {
        guard canEditRoutes, group.isSelectable, group.members.contains(member), let profile = displayProfile else { return }
        await perform {
            if self.tunnel.state == .connected {
                let session = self.tunnel.runtime?.sessionID
                _ = try await self.tunnel.request("select", parameters: ["group": group.name, "name": member])
                await self.refreshGroups()
                guard self.tunnel.runtime?.sessionID == session,
                      self.groups.first(where: { $0.name == group.name })?.selected == member else {
                    throw DashError.message("线路切换尚未确认，请刷新后重试。")
                }
            }
            self.library = try await self.store.rememberSelection(profileID: profile.id, group: group.name, member: member)
            self.dashboard.invalidateNetwork()
            self.notice = self.tunnel.state == .connected ? "线路已切换，影响新连接。" : "已保存，下次连接使用。"
        }
    }
    func testDelay(_ name: String) async {
        guard !testingNames.contains(name), testingNames.count < 3 else { return }
        testingNames.insert(name); defer { testingNames.remove(name) }
        do {
            let data = try await tunnel.request("delay", parameters: ["name": name])
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            delays[name] = (root["delay"] as? NSNumber)?.intValue ?? -1
        } catch { delays[name] = -1 }
        delayDates[name] = Date()
    }
    func setMode(_ mode: RoutingMode) async {
        guard canEditRoutes, let profile = displayProfile else { return }
        await perform {
            if self.tunnel.state == .connected {
                let session = self.tunnel.runtime?.sessionID
                _ = try await self.tunnel.request("mode", parameters: ["mode": mode.rawValue])
                await self.tunnel.updateRuntime()
                guard self.tunnel.runtime?.sessionID == session, self.tunnel.runtime?.mode == mode.rawValue else {
                    throw DashError.message("连接方式尚未确认，请重试。")
                }
            }
            self.library = try await self.store.rememberMode(profileID: profile.id, mode: mode)
            self.dashboard.invalidateNetwork()
        }
    }
    func perform(_ operation: @MainActor () async throws -> Void) async {
        guard !busy, !connection.step.inProgress else { return }
        busy = true; defer { busy = false }
        do { try await operation() } catch { errorMessage = error.localizedDescription }
    }
}
