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
    let delayTests = DelayTestRunner()
    var testingNames: Set<String> { delayTests.testingNames }
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
    @ObservationIgnored private var loading = false
    @ObservationIgnored private var refreshingGroupSession: String?
    @ObservationIgnored private var groupRefreshToken = UUID()

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
        guard let summary = activeSummary else { return [] }
        let catalog = ProxySelection.configurationGroups(summary: summary) + [ProxySelection.globalGroup(summary: summary)]
        let selections = ProxySelection.defaultSelections(groups: catalog, saved: displayProfile?.selections ?? [:])
        return catalog.map { group in
            var value = group; value.selected = selections[group.name]; return value
        }
    }
    var visibleGroups: [ProxyGroup] { displayGroups.filter { mode == .global ? $0.name == "GLOBAL" : $0.name != "GLOBAL" } }
    var quickGroup: ProxyGroup? { visibleGroups.count == 1 ? visibleGroups.first : nil }
    var homeRouteTarget: String? {
        if mode == .direct || activeSummary?.isDirectOnly == true { return "DIRECT" }
        if mode == .global { return "GLOBAL" }
        if let name = homeGroupName, visibleGroups.contains(where: { $0.name == name }) { return name }
        return activeSummary?.rules.last(where: { $0.hasPrefix("MATCH,") })?.split(separator: ",").dropFirst().first.map { $0.trimmingCharacters(in: .whitespaces) }
            ?? visibleGroups.first?.name
    }
    var homeGroup: ProxyGroup? { visibleGroups.first { $0.name == homeRouteTarget } }
    var homeNode: String? {
        guard tunnel.runtime != nil, let target = homeRouteTarget else { return nil }
        if (target == "GLOBAL" || activeSummary?.groups.contains(where: { $0.name == target }) == true), !groups.contains(where: { $0.name == target }) { return nil }
        return ProxySelection.resolvedLeaf(group: target, groups: groups)
    }
    var plannedHomeRoute: String {
        guard let target = homeRouteTarget else { return "连接后读取节点" }
        return ProxySelection.preview(group: target, groups: displayGroups) ?? "请选择节点"
    }
    var homeProxyTitle: String {
        let name = tunnel.state == .connected ? (homeNode ?? homeGroup?.selected ?? homeRouteTarget ?? "正在读取节点") : plannedHomeRoute
        return name == "DIRECT" ? "直接连接" : name
    }
    var proxyTestNames: [String] {
        let builtins: Set<String> = ["DIRECT", "REJECT", "REJECT-DROP", "PASS", "COMPATIBLE", "GLOBAL"]
        let groupNames = Set(displayGroups.map(\.name))
        var seen = Set<String>()
        let candidates = (activeSummary?.nodes.map(\.name) ?? []) + proxyKinds.keys.sorted()
        return candidates.filter { !builtins.contains($0) && !groupNames.contains($0) && seen.insert($0).inserted }
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
        guard !loading else { return }
        loading = true; defer { loading = false }
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
    func suspend() { tunnel.stopPolling(); dashboard.suspend(); delayTests.cancel(); traffic = [] }
    func consumeSample() {
        connection.reconcile()
        dashboard.sample(tunnel)
        guard let runtime = tunnel.runtime else { groups = []; traffic = []; delayTests.cancel(); return }
        if runtime.sessionID != lastSampleSession {
            delayTests.cancel()
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
        if Date().timeIntervalSince(lastGroupRefresh) >= 2 {
            lastGroupRefresh = Date(); Task { await refreshGroups() }
        }
    }
    func toggleConnection() async {
        if connection.step.inProgress || tunnel.phase != .stopped { delayTests.cancel(); connection.cancel(); return }
        guard let profile = activeProfile else {
            if library.profiles.isEmpty { showingImport = true } else { selectedTab = .subscriptions }
            return
        }
        useAndConnect(profile)
    }
    @discardableResult
    func save(_ prepared: PreparedConfiguration, name: String, url: URL?, usage: SubscriptionUsage?) async throws -> ImportCommit {
        let title = SubscriptionNaming.resolve(input: name, sourceURL: url, existing: library.profiles.map(\.name))
        let commit = try await store.commitImport(prepared, name: title, sourceURL: url, usage: usage)
        library = commit.library
        return commit
    }
    func useAndConnect(_ profile: Profile) {
        guard !connection.step.inProgress, !busy else { return }
        delayTests.cancel(); homeGroupName = nil
        selectedTab = .home; notice = nil
        connection.start(profile) { [weak self] in
            guard let self else { throw CancellationError() }
            try Task.checkCancellation()
            self.library = try await self.store.select(profile.id)
            self.groups = []; self.delays = [:]; self.proxyKinds = [:]; self.traffic = []; self.healthyGeneration = nil
        }
    }
    func activate(_ profile: Profile) async {
        if tunnel.phase != .stopped { useAndConnect(profile); return }
        await perform {
            self.library = try await self.store.select(profile.id)
            self.groups = []; self.delays = [:]; self.traffic = []; self.homeGroupName = nil; self.proxyKinds = [:]
            self.selectedTab = .home
        }
    }
    func rename(_ profile: Profile, name: String) async {
        await perform {
            let title = SubscriptionNaming.resolve(input: name, fallback: profile.name,
                existing: self.library.profiles.filter { $0.id != profile.id }.map(\.name))
            self.library = try await self.store.rename(profileID: profile.id, name: title)
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
    func refreshGroups(force: Bool = false) async {
        guard tunnel.state == .connected, let session = tunnel.runtime?.sessionID, force || refreshingGroupSession != session else { return }
        refreshingGroupSession = session; groupRefreshToken = UUID(); let token = groupRefreshToken
        defer { if groupRefreshToken == token { refreshingGroupSession = nil } }
        do {
            let data = try await tunnel.request("proxies")
            guard tunnel.runtime?.sessionID == session, groupRefreshToken == token else { return }
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
                await self.refreshGroups(force: true)
                guard self.tunnel.runtime?.sessionID == session,
                      self.groups.first(where: { $0.name == group.name })?.selected == member else {
                    throw DashError.message("线路切换尚未确认，请刷新后重试。")
                }
            }
            self.library = try await self.store.rememberSelection(profileID: profile.id, group: group.name, member: member)
            self.dashboard.invalidateNetwork()
            self.dashboard.refreshNetwork(self.tunnel)
            self.notice = self.tunnel.state == .connected ? "线路已切换，影响新连接。" : "已保存，下次连接使用。"
        }
    }
    func testDelay(_ name: String) async { startDelayTests([name]) }
    func startDelayTests(_ names: [String]) {
        guard tunnel.state == .connected, let session = tunnel.runtime?.sessionID else { return }
        let profile = runningProfile?.id
        delayTests.start(names: names, isCurrent: { [weak self] in
            self?.tunnel.state == .connected && self?.tunnel.runtime?.sessionID == session && self?.runningProfile?.id == profile
        }, test: { [weak self] name in
            guard let self, self.tunnel.runtime?.sessionID == session else { throw CancellationError() }
            let data = try await self.tunnel.request("delay", parameters: ["name": name])
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            return (root["delay"] as? NSNumber)?.intValue ?? -2
        }, receive: { [weak self] name, delay in
            self?.delays[name] = delay; self?.delayDates[name] = Date()
        })
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
            await self.refreshGroups(force: true)
            self.dashboard.invalidateNetwork()
            self.dashboard.refreshNetwork(self.tunnel)
        }
    }
    func perform(_ operation: @MainActor () async throws -> Void) async {
        guard !busy, !connection.step.inProgress else { return }
        busy = true; defer { busy = false }
        do { try await operation() } catch { errorMessage = error.localizedDescription }
    }
}
