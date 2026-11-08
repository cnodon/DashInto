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
    let delayPreparation = DelayTestPreparation()
    var lastDelayEndpoint = LatencyTestEndpoint.cloudflare
    @ObservationIgnored private var frozenSortDelays: [String: Int] = [:]
    var delayTestBusy: Bool { delayPreparation.isPreparing || delayTests.isRunning }
    var testingNames: Set<String> { delayTests.testingNames }
    var traffic: [TrafficSample] = []
    var uploadRate = 0.0
    var downloadRate = 0.0
    var uploaded = 0.0
    var downloaded = 0.0
    var refreshingProfileID: UUID?
    let dashboard = DashboardMonitor()
    let updates = AppUpdates()
    let subscriptionUpdates = SubscriptionUpdates()
    @ObservationIgnored private let subscriptionRefresher: SubscriptionRefresher
    @ObservationIgnored private var automaticSubscriptionTask: Task<Void, Never>?
    @ObservationIgnored private var automaticSubscriptionRefresh: Task<ProfileLibrary, Error>?
    @ObservationIgnored private var subscriptionRefreshEpoch = 0
    var homeGroupName: String?
    var proxyKinds: [String: String] = [:]
    var delayDates: [String: Date] = [:]
    @ObservationIgnored let store: ProfileStore
    @ObservationIgnored private var lastSampleSession: String?
    @ObservationIgnored private var lastNetworkRevision: Int?
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
        ProxySelection.testableNames(nodes: activeSummary?.nodes ?? [], groups: displayGroups, runtimeKinds: proxyKinds)
    }
    func sortedProxyNames(_ names: [String], order: String) -> [String] {
        let eligible = Set(proxyTestNames)
        // Group aliases and routing actions must not rank as fast nodes (e.g. DIRECT = 0).
        return (ProxyNodeSortOrder(rawValue: order) ?? .configuration)
            .sorted(names, delays: (delayTestBusy ? frozenSortDelays : delays).filter { eligible.contains($0.key) })
    }
    func delayTargets(_ names: [String]) -> [String] {
        ProxySelection.delayTargets(names, nodes: activeSummary?.nodes ?? [], groups: displayGroups, runtimeKinds: proxyKinds)
    }
    var canEditRoutes: Bool { !busy && !connection.step.inProgress && (tunnel.phase == .stopped || tunnel.runtime != nil) }
    var routeDescription: String {
        if activeSummary?.isDirectOnly == true { return "仅直连，不提供代理线路" }
        if let group = quickGroup { return group.selected ?? (group.isSelectable ? "使用订阅默认选择" : "由订阅自动选择") }
        return "按不同用途分流 · 无需逐个选择"
    }

    static var automaticRefreshUITest: Bool {
        #if DEBUG && targetEnvironment(simulator)
        CommandLine.arguments.contains("--ui-test-blocked-refresh") && CommandLine.arguments.contains {
            $0.hasPrefix("--ui-test-library=") && UUID(uuidString: String($0.dropFirst("--ui-test-library=".count))) != nil
        }
        #else
        false
        #endif
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
        let profileStore = ProfileStore(root: profileRoot, keyProvider: KeychainKeyProvider(accessGroup: group))
        store = profileStore
        #if DEBUG && targetEnvironment(simulator)
        let simulateBlockedRefresh = Self.automaticRefreshUITest
        #endif
        subscriptionRefresher = SubscriptionRefresher(store: profileStore) { url in
            #if DEBUG && targetEnvironment(simulator)
            if simulateBlockedRefresh {
                try await Task.sleep(for: .seconds(3600))
                throw CancellationError()
            }
            #endif
            // The encrypted source was approved during import, including explicit HTTP consent.
            let result = try await SubscriptionClient().download(url, allowInsecureHTTP: url.scheme?.lowercased() == "http")
            let parsed = try await Task.detached { try NativeConfigImporter.prepare(result.text) }.value
            try Task.checkCancellation()
            let prepared = try await NativeResourcePreparer.shared.prepare(parsed)
            try Task.checkCancellation()
            return PreparedSubscription(configuration: prepared, usage: result.usage)
        }
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
    func resume() {
        tunnel.startPolling { [weak self] in self?.consumeSample() }
        startSubscriptionUpdates()
    }
    func startSubscriptionUpdates(restart: Bool = false) {
        guard restart || automaticSubscriptionTask == nil else { return }
        if restart { interruptAutomaticSubscriptionRefresh() }
        automaticSubscriptionTask?.cancel()
        subscriptionUpdates.schedule(profiles: library.profiles)
        guard subscriptionUpdates.interval != .disabled else { return }
        automaticSubscriptionTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshDueSubscriptions()
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
    }
    func refreshDueSubscriptions() async {
        guard !Task.isCancelled, !busy, !loading, !showingImport, !delayTestBusy, !connection.step.inProgress else { return }
        defer { subscriptionUpdates.schedule(profiles: library.profiles) }
        let due = library.profiles.filter { subscriptionUpdates.interval.nextDue(for: $0).map { $0 <= Date() } ?? false }
            .sorted { (subscriptionUpdates.interval.nextDue(for: $0) ?? .distantFuture) < (subscriptionUpdates.interval.nextDue(for: $1) ?? .distantFuture) }
        for profile in due {
            guard !Task.isCancelled, subscriptionUpdates.interval != .disabled, !busy, !showingImport, !delayTestBusy, !connection.step.inProgress else { return }
            await refresh(profile, automatic: true)
        }
    }
    func suspend() { automaticSubscriptionTask?.cancel(); automaticSubscriptionTask = nil; subscriptionUpdates.schedule(profiles: library.profiles); tunnel.stopPolling(); dashboard.suspend(); cancelDelayTests(reason: "App 已进入后台，测速已停止"); traffic = [] }
    func consumeSample() {
        connection.reconcile()
        dashboard.sample(tunnel)
        guard tunnel.state == .connected, let runtime = tunnel.runtime else {
            groups = []; traffic = []
            delayTests.cancel(reason: tunnel.state == .connected ? "无法读取连接状态，请刷新后重试" : "连接已断开，测速已停止")
            return
        }
        if runtime.sessionID != lastSampleSession {
            delayTests.reset()
            lastSampleSession = runtime.sessionID; lastNetworkRevision = runtime.networkRevision; traffic = []; groups = []; delays = [:]; delayDates = [:]
            uploaded = 0; downloaded = 0; lastGroupRefresh = .distantPast
        }
        if lastNetworkRevision != runtime.networkRevision {
            lastNetworkRevision = runtime.networkRevision
            invalidateDelayMeasurements(reason: "网络已切换，以下为上次结果，请重新测速")
            connection.networkChanged(); connection.reconcile()
            dashboard.invalidateNetwork(); dashboard.refreshNetwork(tunnel)
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
        interruptAutomaticSubscriptionRefresh()
        if connection.step.inProgress || tunnel.phase != .stopped { cancelDelayTests(); connection.cancel(); return }
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
        interruptAutomaticSubscriptionRefresh()
        delayPreparation.cancel(); delayTests.reset(); homeGroupName = nil
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
            self.delayPreparation.cancel(); self.delayTests.reset()
            self.groups = []; self.delays = [:]; self.delayDates = [:]; self.traffic = []; self.homeGroupName = nil; self.proxyKinds = [:]
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
    func refresh(_ profile: Profile, automatic: Bool = false) async {
        guard !busy, !connection.step.inProgress, refreshingProfileID == nil else { return }
        // Automatic downloads must never lock connection, selection or mode controls.
        if !automatic { busy = true }
        refreshingProfileID = profile.id
        let refreshEpoch = subscriptionRefreshEpoch
        defer {
            if !automatic { busy = false }
            refreshingProfileID = nil
            subscriptionUpdates.schedule(profiles: library.profiles)
        }
        do {
            if automatic {
                let retained = [tunnel.configuredGeneration].compactMap { $0 }
                let operation = Task { try await subscriptionRefresher.refresh(profileID: profile.id, retaining: retained) }
                automaticSubscriptionRefresh = operation
                defer { automaticSubscriptionRefresh = nil }
                let updated = try await withTaskCancellationHandler { try await operation.value } onCancel: { operation.cancel() }
                guard refreshEpoch == subscriptionRefreshEpoch else { return }
                library = updated
            } else {
                library = try await subscriptionRefresher.refresh(profileID: profile.id, retaining: [tunnel.configuredGeneration].compactMap { $0 })
            }
            try? await store.prune(retaining: [tunnel.configuredGeneration].compactMap { $0 })
            if !automatic { notice = tunnel.state.isActive ? "新版本已保存。重新连接后应用。" : "订阅已更新。" }
        } catch {
            if !automatic || refreshEpoch == subscriptionRefreshEpoch {
                if let current = try? await store.library(), !automatic || refreshEpoch == subscriptionRefreshEpoch { library = current }
            }
            if !automatic && !Task.isCancelled && !(error is CancellationError) {
                errorMessage = "订阅更新失败，已保留原配置。请检查网络和订阅有效期后重试。"
            }
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
            try await self.applySelection(group: group.name, member: member, profileID: profile.id)
            self.dashboard.invalidateNetwork()
            self.dashboard.refreshNetwork(self.tunnel)
            self.notice = self.tunnel.state == .connected ? "线路已切换，影响新连接。" : "已保存，下次连接使用。"
        }
    }
    private func applySelection(group: String, member: String, profileID: UUID) async throws {
        if tunnel.state == .connected {
            let session = tunnel.runtime?.sessionID
            _ = try await tunnel.request("select", parameters: ["group": group, "name": member])
            await refreshGroups(force: true)
            guard tunnel.runtime?.sessionID == session, groups.first(where: { $0.name == group })?.selected == member else {
                throw DashError.message("线路切换尚未确认，请刷新后重试。")
            }
        }
        library = try await store.rememberSelection(profileID: profileID, group: group, member: member)
    }
    func nodeSelectionPath(_ name: String, global: Bool = false) -> [ProxyRouteChoice]? {
        guard proxyTestNames.contains(name), global || mode != .direct,
              let root = global ? "GLOBAL" : homeRouteTarget else { return nil }
        return ProxySelection.manualPath(to: name, from: root, groups: displayGroups)
    }
    /// Select the manual chain that actually reaches this node; never silently change routing mode.
    func useNode(_ name: String, global: Bool = false) async -> Bool {
        guard canEditRoutes, let profile = displayProfile, let path = nodeSelectionPath(name, global: global) else {
            errorMessage = "当前策略不能手动选择此节点，请刷新节点列表后重试。"; return false
        }
        let wasConnected = tunnel.state == .connected
        var saved = false
        await perform {
            // Set the leaf first, then switch the parent to the prepared branch.
            for choice in path.reversed() {
                try await self.applySelection(group: choice.group, member: choice.member, profileID: profile.id)
            }
            if global { try await self.applyMode(.global, profileID: profile.id) }
            self.dashboard.invalidateNetwork(); self.dashboard.refreshNetwork(self.tunnel)
            self.notice = wasConnected ? "节点已切换，对新连接生效。" : nil
            saved = true
        }
        guard saved else { return false }
        if !wasConnected, let current = library.profiles.first(where: { $0.id == profile.id }) { useAndConnect(current) }
        return true
    }
    func invalidateDelayMeasurements(reason: String) {
        delayPreparation.cancel(reason: delayPreparation.isPreparing ? reason : nil)
        delayTests.invalidate(reason: reason)
        delays = [:]; delayDates = [:]; frozenSortDelays = [:]
    }
    func cancelDelayTests(reason: String? = nil) {
        let wasPreparing = delayPreparation.isPreparing
        delayPreparation.cancel(reason: wasPreparing ? (reason ?? "已取消测速") : nil)
        delayTests.cancel(reason: reason)
    }
    func testDelay(_ name: String) async { startDelayTests([name]) }
    /// nil requests the entire freshly loaded catalog, including provider nodes.
    func startDelayTests(_ requestedNames: [String]? = nil) {
        guard !delayTestBusy else { return }
        tunnel.refreshState()
        guard tunnel.state == .connected else {
            delayPreparation.cancel(reason: "请先在首页连接 VPN，再测试节点延迟。")
            notice = "需要先连接 VPN，节点测速不会自动开启连接。"
            return
        }
        let profileID = runningProfile?.id
        let generation = tunnel.configuredGeneration
        let expectedSession = tunnel.runtime?.sessionID
        let expectedNetwork = tunnel.runtime?.networkRevision
        frozenSortDelays = delays
        delayPreparation.start(prepare: { [weak self] in
            guard let self else { throw CancellationError() }
            await self.tunnel.updateRuntime()
            try Task.checkCancellation()
            guard self.tunnel.state == .connected, let runtime = self.tunnel.runtime else {
                throw DashError.message("无法读取 VPN 状态，请重新连接后重试。")
            }
            guard self.runningProfile?.id == profileID, self.tunnel.configuredGeneration == generation,
                  expectedSession == nil || (expectedSession == runtime.sessionID && expectedNetwork == runtime.networkRevision) else {
                throw DashError.message("连接已变化，请重新测速。")
            }
            // Synchronize the session before launching workers; the next polling tick must not
            // reset a batch that was started immediately after connection establishment.
            self.consumeSample()
            await self.refreshGroups(force: true)
            try Task.checkCancellation()
            guard self.tunnel.state == .connected, self.tunnel.runtime?.sessionID == runtime.sessionID,
                  self.runningProfile?.id == profileID, self.tunnel.runtime?.networkRevision == runtime.networkRevision else { throw DashError.message("连接已变化，请重新测速。") }
            return self.delayTargets(requestedNames ?? self.proxyTestNames)
        }, ready: { [weak self] names in
            self?.runDelayTests(names)
        })
    }
    private func runDelayTests(_ names: [String]) {
        guard tunnel.state == .connected, let session = tunnel.runtime?.sessionID else {
            delayPreparation.cancel(reason: "连接已断开，请连接后重试。"); return
        }
        let profile = runningProfile?.id
        let network = tunnel.runtime?.networkRevision
        let endpoint = LatencyTestEndpoint(rawValue: UserDefaults.standard.string(forKey: "latencyTestEndpoint") ?? "") ?? .cloudflare
        lastDelayEndpoint = endpoint
        delayTests.start(names: names, isCurrent: { [weak self] in
            self?.tunnel.state == .connected && self?.tunnel.runtime?.sessionID == session && self?.runningProfile?.id == profile && self?.tunnel.runtime?.networkRevision == network
        }, test: { [weak self] name in
            guard let self, self.tunnel.runtime?.sessionID == session, self.tunnel.runtime?.networkRevision == network else { throw CancellationError() }
            let data = try await self.tunnel.request("delay", parameters: ["name": name, "endpoint": endpoint.rawValue])
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            return (root["delay"] as? NSNumber)?.intValue ?? -2
        }, receive: { [weak self] name, delay in
            self?.delays[name] = delay; self?.delayDates[name] = Date()
        })
    }
    func setMode(_ mode: RoutingMode) async {
        guard canEditRoutes, let profile = displayProfile else { return }
        await perform {
            try await self.applyMode(mode, profileID: profile.id)
            self.dashboard.invalidateNetwork(); self.dashboard.refreshNetwork(self.tunnel)
        }
    }
    private func applyMode(_ mode: RoutingMode, profileID: UUID) async throws {
        if tunnel.state == .connected {
            let session = tunnel.runtime?.sessionID
            _ = try await tunnel.request("mode", parameters: ["mode": mode.rawValue])
            await tunnel.updateRuntime()
            guard tunnel.runtime?.sessionID == session, tunnel.runtime?.mode == mode.rawValue else {
                throw DashError.message("连接方式尚未确认，请重试。")
            }
        }
        library = try await store.rememberMode(profileID: profileID, mode: mode)
        await refreshGroups(force: true)
    }
    func interruptAutomaticSubscriptionRefresh() {
        subscriptionRefreshEpoch += 1
        automaticSubscriptionRefresh?.cancel()
    }
    func perform(_ operation: @MainActor () async throws -> Void) async {
        guard !busy, !connection.step.inProgress else { return }
        busy = true; defer { busy = false }
        interruptAutomaticSubscriptionRefresh()
        do { try await operation() } catch { errorMessage = error.localizedDescription }
    }
}
