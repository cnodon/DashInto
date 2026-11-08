import SwiftUI
import ClashDashKit

struct PoliciesView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var choosingNode: NodeChoice?
    @AppStorage("proxyNodeSortOrder") private var sortOrder = ProxyNodeSortOrder.configuration.rawValue
    var body: some View {
        List {
            if model.displayProfile == nil {
                Section {
                    Text("选择一份订阅后，即可查看节点。").foregroundStyle(.secondary)
                    Button("前往订阅") { model.selectedTab = .subscriptions }
                }
            } else {
                Section {
                    Picker("运行模式", selection: Binding(get: { model.mode }, set: { mode in Task { await model.setMode(mode) } })) {
                        ForEach(RoutingMode.allCases, id: \.self) { Text($0.label).tag($0) }
                    }.pickerStyle(.segmented).disabled(!model.canEditRoutes).accessibilityIdentifier("routingMode")
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("搜索节点", text: $search).accessibilityIdentifier("proxySearch")
                        ProxySortMenu(selection: $sortOrder, identifier: "proxySortMenu")
                    }.frame(minHeight: 44)
                    DelayTestControl(names: nil, identifier: "testAllProxies")
                } footer: {
                    if model.tunnel.state != .connected { Text("连接后可测试节点延迟（ms）") }
                    else if model.tunnel.runtime == nil { Text("正在读取连接状态，可下拉刷新") }
                }
                Section("代理组") {
                    ForEach(model.visibleGroups.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.members.contains(where: { $0.localizedCaseInsensitiveContains(search) }) }) { group in
                        NavigationLink { PolicyDetailView(groupName: group.name).toolbar(.visible, for: .navigationBar) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack { Text(group.name).font(.subheadline.weight(.medium)); Spacer(); Image(systemName: group.isSelectable ? "hand.tap" : "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.secondary).accessibilityLabel(group.isSelectable ? "手动选择" : "自动选择") }
                                Text(group.selected ?? "连接后自动选择").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }.padding(.vertical, 3)
                        }.accessibilityIdentifier("routeGroup-" + group.name)
                    }
                }
                Section("节点 · \(model.proxyTestNames.count)") {
                    ForEach(model.sortedProxyNames(model.proxyTestNames, order: sortOrder).filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }, id: \.self) { name in
                        HStack(spacing: 10) {
                            Button { choosingNode = NodeChoice(name: name) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: (model.homeNode ?? model.plannedHomeRoute) == name ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle((model.homeNode ?? model.plannedHomeRoute) == name ? Color.dashBlue : Color.secondary.opacity(0.4))
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(name).font(.subheadline).foregroundStyle(.primary).lineLimit(2)
                                        Text(model.proxyKinds[name] ?? model.activeSummary?.nodes.first { $0.name == name }?.kind ?? "代理节点")
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 4)
                                }.frame(minHeight: 44).contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(!model.canEditRoutes)
                                .accessibilityLabel("选择节点 " + name).accessibilityIdentifier("chooseProxy-" + name)
                            NodeDelayButton(name: name)
                        }.padding(.vertical, 3)
                    }
                    if model.proxyTestNames.isEmpty { Text("远程节点会在连接后读取。").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }.contentMargins(.top, 8, for: .scrollContent).listSectionSpacing(.compact)
            .toolbar(.hidden, for: .navigationBar).accessibilityIdentifier("proxiesPage")
            .sheet(item: $choosingNode) { choice in NodeConnectionSheet(name: choice.name) }
            .task { await model.refreshGroups() }
            .refreshable { await model.tunnel.updateRuntime(); await model.refreshGroups(force: true) }
    }
}

private struct NodeChoice: Identifiable {
    let name: String
    var id: String { name }
}

private struct NodeConnectionSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let name: String
    @State private var applying = false
    private var path: [ProxyRouteChoice]? { model.nodeSelectionPath(name) }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(name).font(.headline)
                    if let delay = model.delays[name] { DelayIndicator(milliseconds: delay) }
                }
                if let path {
                    Section {
                        Button(model.tunnel.state == .connected ? "切换到此节点" : "选择并连接") { apply(global: false) }
                            .disabled(applying || !model.canEditRoutes).accessibilityIdentifier("useChosenNode")
                    } footer: {
                        Text(model.mode.label + " · " + path.map(\.group).joined(separator: " → ") + "。规则模式下仅影响使用此策略的流量。")
                    }
                } else {
                    Section {
                        Text("当前为直连或自动策略，无法固定选择这个节点。可明确切换为全局模式。").font(.subheadline).foregroundStyle(.secondary)
                        Button("使用全局模式连接此节点") { apply(global: true) }
                            .disabled(applying || !model.canEditRoutes || model.nodeSelectionPath(name, global: true) == nil)
                            .accessibilityIdentifier("useChosenNodeGlobally")
                    } footer: { Text("全局模式将流量交给所选节点，不再按订阅规则分流。") }
                }
                if applying { ProgressView("正在应用节点…") }
            }.navigationTitle("选择节点").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(applying) } }
        }.presentationDetents([.medium, .large])
    }
    private func apply(global: Bool) {
        applying = true
        Task {
            let success = await model.useNode(name, global: global)
            applying = false
            if success { dismiss() }
        }
    }
}

struct PolicyDetailView: View {
    @Environment(AppModel.self) private var model
    var groupName: String
    @State private var pending: String?
    @State private var search = ""
    @AppStorage("proxyNodeSortOrder") private var sortOrder = ProxyNodeSortOrder.configuration.rawValue
    private var group: ProxyGroup? { model.displayGroups.first { $0.name == groupName } }
    var body: some View {
        List {
            if let group {
                Section {
                    LabeledContent("当前选择", value: group.selected ?? "连接后自动选择")
                    DelayTestControl(names: [group.name], identifier: "testGroupProxies")
                }
                if group.members.isEmpty && model.tunnel.phase == .stopped {
                    Section { Text("此组来自远程资源，连接后可查看和测试具体节点。").font(.subheadline).foregroundStyle(.secondary) }
                }
                Section {
                    ForEach(model.sortedProxyNames(group.members, order: sortOrder).filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }, id: \.self) { name in
                        HStack(spacing: 8) {
                            Button {
                                guard group.isSelectable, model.canEditRoutes else { return }
                                pending = name
                                Task { await model.select(group: group, member: name); pending = nil }
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: group.selected == name ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(group.selected == name ? Color.dashBlue : Color.secondary.opacity(0.4))
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(name).font(.subheadline).foregroundStyle(.primary).lineLimit(2)
                                        Text(model.proxyKinds[name] ?? model.activeSummary?.nodes.first { $0.name == name }?.kind ?? (name == "DIRECT" ? "直接连接" : "代理组 / 动态节点"))
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                    if pending == name { ProgressView() }
                                }.frame(minHeight: 44).contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(!group.isSelectable || !model.canEditRoutes)
                            NodeDelayButton(name: name)
                        }
                    }
                } footer: {
                    Text(model.tunnel.state != .connected ? "下次连接使用" : group.isSelectable ? "对新连接生效" : "自动选择节点")
                }
            } else { ContentUnavailableView("代理组不存在", systemImage: "circle.grid.2x2") }
        }.navigationTitle(groupName).navigationBarTitleDisplayMode(.inline).searchable(text: $search, prompt: "搜索节点")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { ProxySortMenu(selection: $sortOrder, identifier: "groupProxySortMenu") } }
    }
}

private struct DelayTestControl: View {
    @Environment(AppModel.self) private var model
    var names: [String]?
    var identifier: String
    @State private var showingResults = false
    private var targets: [String] { model.delayTargets(names ?? model.proxyTestNames) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if model.delayPreparation.isPreparing {
                    ProgressView().controlSize(.small)
                    Text("正在准备测速…").font(.caption).accessibilityIdentifier("delayTestPreparing")
                    Spacer()
                    Button("取消") { model.cancelDelayTests() }.frame(minHeight: 44)
                        .accessibilityIdentifier("cancelDelayTests")
                } else if model.delayTests.isRunning {
                    Gauge(value: Double(model.delayTests.completed), in: 0...Double(max(model.delayTests.total, 1))) { Text("测速进度") }
                        .gaugeStyle(.accessoryCircularCapacity).tint(Color.dashBlue).scaleEffect(0.6).frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("测速中").font(.caption)
                        Text("\(model.delayTests.completed) / \(model.delayTests.total)").font(.caption2).monospacedDigit()
                    }.accessibilityIdentifier("delayTestProgress")
                    Spacer()
                    Button { model.cancelDelayTests() } label: { Image(systemName: "xmark.circle.fill").font(.title3).frame(width: 44, height: 44) }
                        .accessibilityLabel("取消测速").accessibilityIdentifier("cancelDelayTests")
                } else {
                    Button { model.startDelayTests(names) } label: {
                        Label("全部测速", systemImage: "gauge.with.dots.needle.33percent").frame(minHeight: 44)
                    }
                        .accessibilityIdentifier(identifier)
                        .accessibilityHint("测试 \(targets.count) 个实际节点的 HTTPS 响应延迟，单位毫秒")
                    Spacer()
                    if model.delayTests.finishedAt != nil {
                        VStack(alignment: .trailing, spacing: 3) {
                            Label("\(model.delayTests.completed) / \(model.delayTests.total)", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(model.delayTests.failed == 0 ? .green : .orange).accessibilityLabel("已完成 \(model.delayTests.completed) / \(model.delayTests.total)")
                                .accessibilityIdentifier("delayTestSummary")
                            Text("可用 \(model.delayTests.succeeded) · 未通过 \(model.delayTests.failed)")
                        }.font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }.buttonStyle(.borderless)
            if model.delayTests.total > 0 {
                HStack {
                    Button { showingResults = true } label: { Label("结果", systemImage: "list.bullet.clipboard") }
                        .accessibilityIdentifier("showDelayResults")
                    if let date = model.delayTests.endedAt {
                        Text(date, style: .relative).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !model.delayTestBusy && !model.delayTests.failedNames.isEmpty {
                        Button("重测失败") { model.startDelayTests(model.delayTests.failedNames) }
                            .accessibilityIdentifier("retryFailedDelays")
                    }
                }.font(.caption).buttonStyle(.borderless).frame(minHeight: 44)
            }
            if let message = model.delayPreparation.failure ?? model.delayTests.interruption {
                Text(message).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("delayTestInterruption")
                if model.tunnel.state != .connected {
                    Button("前往首页连接") { model.selectedTab = .home }
                        .font(.caption).frame(minHeight: 44).accessibilityIdentifier("connectForDelayTest")
                }
            }
        }.sheet(isPresented: $showingResults) { DelayResultsView() }
    }
}

private struct NodeDelayButton: View {
    @Environment(AppModel.self) private var model
    var name: String
    private var targets: [String] { model.delayTargets([name]) }
    var body: some View {
        Button { model.startDelayTests([name]) } label: {
            Group {
                if targets.contains(where: { model.testingNames.contains($0) }) { ProgressView().controlSize(.small) }
                else if let value = model.delays[name] {
                    VStack(alignment: .trailing, spacing: 3) {
                        DelayIndicator(milliseconds: value)
                        if let date = model.delayDates[name] {
                            Text(date, style: .relative).font(.system(size: 9)).foregroundStyle(.tertiary)
                        }
                    }
                } else if targets.isEmpty { Text("—") }
                else { Image(systemName: "gauge.with.dots.needle.33percent") }
            }.font(.caption).frame(minWidth: 76, minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.borderless).disabled(model.delayTestBusy || targets.isEmpty)
            .accessibilityLabel("测试 " + name + " 延迟").accessibilityIdentifier("testDelay-" + name)
    }
}

private struct ProxySortMenu: View {
    @Binding var selection: String
    var identifier: String
    var body: some View {
        Menu {
            Picker("节点排序", selection: $selection) {
                ForEach(ProxyNodeSortOrder.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
            }
        } label: {
            Label((ProxyNodeSortOrder(rawValue: selection) ?? .configuration).shortTitle, systemImage: "arrow.up.arrow.down")
                .font(.caption.weight(.medium)).fixedSize().frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }.accessibilityLabel("节点排序")
            .accessibilityValue((ProxyNodeSortOrder(rawValue: selection) ?? .configuration).title)
            .accessibilityIdentifier(identifier)
    }
}
