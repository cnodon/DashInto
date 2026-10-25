import SwiftUI
import ClashDashKit

struct PoliciesView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    var body: some View {
        List {
            if model.displayProfile == nil {
                Section {
                    Text("选择一份订阅后，即可查看代理策略。").font(.subheadline).foregroundStyle(.secondary)
                    Button("前往订阅") { model.selectedTab = .subscriptions }
                }
            } else {
                Section {
                    Picker("运行模式", selection: Binding(get: { model.mode }, set: { mode in Task { await model.setMode(mode) } })) {
                        ForEach(RoutingMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).disabled(!model.canEditRoutes)
                    HStack { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField("搜索代理组或节点", text: $search).accessibilityIdentifier("proxySearch") }
                }
                Section {
                    ForEach(model.visibleGroups.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.members.contains(where: { $0.localizedCaseInsensitiveContains(search) }) }) { group in
                        NavigationLink { PolicyDetailView(groupName: group.name).toolbar(.visible, for: .navigationBar) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack { Text(group.name).font(.subheadline.weight(.medium)); Spacer(); Text(group.isSelectable ? "手动" : "自动").font(.caption2).foregroundStyle(.secondary) }
                                Text(group.selected ?? (group.isSelectable ? "使用订阅默认选择" : "由订阅自动选择")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }.padding(.vertical, 3)
                        }.accessibilityIdentifier("routeGroup-" + group.name)
                    }
                }
                Section { NavigationLink { RulesView().toolbar(.visible, for: .navigationBar) } label: { LabeledContent("分流规则", value: "\(model.activeSummary?.rules.count ?? 0)") } }
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
                    LabeledContent("策略类型", value: group.kind)
                    LabeledContent("当前选择", value: group.selected ?? (group.isSelectable ? "使用订阅默认选择" : "由订阅自动选择"))
                }
                if group.members.isEmpty && model.tunnel.phase == .stopped {
                    Section { Text("此组的线路来自远程资源。可以先按订阅默认选择连接，连接后展开具体线路。").font(.subheadline).foregroundStyle(.secondary) }
                }
                Section {
                    ForEach(group.members.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }, id: \.self) { name in
                        Button {
                            guard group.isSelectable, model.canEditRoutes else { return }
                            pending = name
                            Task { await model.select(group: group, member: name); pending = nil }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "network").font(.body).foregroundStyle(Color.dashBlue)
                                    .frame(width: 36, height: 36).background(Color.dashBlue.opacity(0.08), in: Circle())
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(name).font(.body).foregroundStyle(.primary).lineLimit(3)
                                    Text(model.activeSummary?.nodes.first { $0.name == name }?.kind ?? (name == "DIRECT" ? "直接连接" : "代理组 / 动态节点"))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 6)
                                if pending == name || model.testingNames.contains(name) { ProgressView() }
                                else {
                                    if let delay = model.delays[name] { Text(delay < 0 ? "超时" : "\(delay) ms").font(.caption).foregroundStyle(delay < 0 ? .secondary : Color.dashBlue) }
                                    if group.selected == name { Image(systemName: "checkmark").font(.subheadline.weight(.semibold)).foregroundStyle(Color.dashBlue).accessibilityLabel("已选中") }
                                }
                            }.padding(.vertical, 4).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(!group.isSelectable || !model.canEditRoutes)
                            .contextMenu { Button("测试延迟", systemImage: "gauge.with.dots.needle.33percent") { Task { await model.testDelay(name) } }.disabled(model.tunnel.state != .connected) }
                    }
                } footer: { Text(model.tunnel.state != .connected ? "选择会保存在本机，下次连接时使用。测速需要先连接。" : group.isSelectable ? "选择影响新连接；原有下载和通话不会被主动断开。" : "这个代理组由配置自动管理，不接受手动选择。") }
            } else { ContentUnavailableView("代理组不存在", systemImage: "circle.grid.2x2") }
        }.navigationTitle(groupName).navigationBarTitleDisplayMode(.inline).searchable(text: $search, prompt: "搜索节点")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("测速") {
                Task {
                    let members = group?.members ?? []
                    for batch in stride(from: 0, to: members.count, by: 3) {
                        await withTaskGroup(of: Void.self) { tasks in
                            for name in members[batch..<min(batch + 3, members.count)] { tasks.addTask { await model.testDelay(name) } }
                        }
                    }
                }
            }.disabled(model.tunnel.state != .connected || !model.testingNames.isEmpty) } }
    }
}

struct RulesView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    var body: some View {
        List {
            Section { Text("规则按顺序匹配。远程规则集按配置引用执行。").font(.subheadline).foregroundStyle(.secondary) }
            ForEach(Array((model.activeSummary?.rules ?? []).enumerated()).filter { search.isEmpty || $0.element.localizedCaseInsensitiveContains(search) }, id: \.offset) { index, rule in
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(index + 1) · \(rule.split(separator: ",").first.map(String.init) ?? "规则")").font(.caption.weight(.medium)).foregroundStyle(Color.dashBlue)
                    Text(rule).font(.subheadline).textSelection(.enabled)
                }.padding(.vertical, 4)
            }
        }.navigationTitle("分流规则").searchable(text: $search, prompt: "搜索规则或目标策略")
    }
}
