import SwiftUI
import ClashDashKit

struct PoliciesView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
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
                    HStack { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField("搜索节点", text: $search).accessibilityIdentifier("proxySearch") }.frame(minHeight: 44)
                    DelayTestControl(names: model.proxyTestNames, identifier: "testAllProxies")
                } footer: {
                    if model.tunnel.state != .connected { Text("连接后可测速") }
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
                    ForEach(model.proxyTestNames.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }, id: \.self) { name in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(name).font(.subheadline).lineLimit(2)
                                Text(model.proxyKinds[name] ?? model.activeSummary?.nodes.first { $0.name == name }?.kind ?? "代理节点")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            NodeDelayButton(name: name)
                        }.padding(.vertical, 3)
                    }
                    if model.proxyTestNames.isEmpty { Text("远程节点会在连接后读取。").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }.contentMargins(.top, 8, for: .scrollContent).listSectionSpacing(.compact)
            .toolbar(.hidden, for: .navigationBar).accessibilityIdentifier("proxiesPage")
            .task { await model.refreshGroups() }.refreshable { await model.refreshGroups() }
    }
}

struct PolicyDetailView: View {
    @Environment(AppModel.self) private var model
    var groupName: String
    @State private var pending: String?
    @State private var search = ""
    private var group: ProxyGroup? { model.displayGroups.first { $0.name == groupName } }
    var body: some View {
        List {
            if let group {
                Section {
                    LabeledContent("当前选择", value: group.selected ?? "连接后自动选择")
                    DelayTestControl(names: group.members, identifier: "testGroupProxies")
                }
                if group.members.isEmpty && model.tunnel.phase == .stopped {
                    Section { Text("此组来自远程资源，连接后可查看和测试具体节点。").font(.subheadline).foregroundStyle(.secondary) }
                }
                Section {
                    ForEach(group.members.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }, id: \.self) { name in
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
    }
}

private struct DelayTestControl: View {
    @Environment(AppModel.self) private var model
    var names: [String]
    var identifier: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if model.delayTests.isRunning {
                    Gauge(value: Double(model.delayTests.completed), in: 0...Double(max(model.delayTests.total, 1))) { Text("测速进度") }
                        .gaugeStyle(.accessoryCircularCapacity).tint(Color.dashBlue).scaleEffect(0.6).frame(width: 32, height: 32)
                    Text("\(model.delayTests.completed) / \(model.delayTests.total)").font(.caption).monospacedDigit()
                    Spacer()
                    Button { model.delayTests.cancel() } label: { Image(systemName: "xmark.circle.fill").font(.title3).frame(width: 44, height: 44) }
                        .accessibilityLabel("取消测速").accessibilityIdentifier("cancelDelayTests")
                } else {
                    Button { model.startDelayTests(names) } label: {
                        Label("全部测速", systemImage: "gauge.with.dots.needle.33percent").frame(minHeight: 44)
                    }.disabled(model.tunnel.state != .connected || model.tunnel.runtime == nil || names.isEmpty)
                        .accessibilityIdentifier(identifier)
                    Spacer()
                    if let date = model.delayTests.finishedAt {
                        VStack(alignment: .trailing, spacing: 3) {
                            Label("\(model.delayTests.completed) / \(model.delayTests.total)", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green).accessibilityLabel("已完成 \(model.delayTests.completed) / \(model.delayTests.total)")
                                .accessibilityIdentifier("delayTestSummary")
                            Text(date, format: .dateTime.hour().minute())
                        }.font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }

        }
    }
}

private struct NodeDelayButton: View {
    @Environment(AppModel.self) private var model
    var name: String
    var body: some View {
        Button { model.startDelayTests([name]) } label: {
            Group {
                if model.testingNames.contains(name) { ProgressView().controlSize(.small) }
                else if let value = model.delays[name] {
                    DelayIndicator(milliseconds: value)
                } else { Image(systemName: "gauge.with.dots.needle.33percent") }
            }.font(.caption).frame(minWidth: 76, minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.borderless).disabled(model.tunnel.state != .connected || model.delayTests.isRunning)
            .accessibilityLabel("测试 " + name + " 延迟").accessibilityIdentifier("testDelay-" + name)
    }
}
