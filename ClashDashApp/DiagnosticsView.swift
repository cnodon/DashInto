import SwiftUI
import ClashDashKit

struct DiagnosticsView: View {
    @Environment(AppModel.self) private var model
    @State private var checking = false
    @State private var checkResult: String?
    @State private var checkedAt: Date?
    @State private var events: [String] = []
    private var report: String {
        "DashInto \(DashConstants.appVersion)\n系统 VPN：\(model.tunnel.state.title)\n核心：\(model.tunnel.runtime?.coreVersion ?? "未运行")\n内存：\(DashFormat.bytes(Double(model.tunnel.runtime?.memoryBytes ?? 0)))\n静态节点：\(model.activeSummary?.nodes.count ?? 0)\n规则：\(model.activeSummary?.rules.count ?? 0)\n网络检查：\(checkResult ?? "未检查")\n诊断时间：\(Date().formatted())\n\n不包含订阅地址、节点凭据或浏览目标。"
    }
    var body: some View {
        List {
            Section("系统与核心") {
                LabeledContent("系统 VPN", value: model.tunnel.state.title)
                LabeledContent("扩展响应", value: model.tunnel.runtime == nil ? "未取得运行快照" : "已响应")
                if let runtime = model.tunnel.runtime {
                    LabeledContent("核心版本", value: runtime.coreVersion)
                    LabeledContent("扩展内存", value: DashFormat.bytes(Double(runtime.memoryBytes)))
                    LabeledContent("运行版本", value: runtime.generation == model.activeProfile?.selectedVersion ? "所选配置" : "旧版本，待重新连接")
                }
            }
            Section {
                Button { runCheck() } label: { HStack { Label("检查网络可达性", systemImage: "network"); Spacer(); if checking { ProgressView() } } }.disabled(checking || model.tunnel.state != .connected)
                if let checkResult { Text(checkResult).font(.subheadline).foregroundStyle(.secondary) }
                if let checkedAt { Text(checkedAt, format: .dateTime.hour().minute().second()).font(.caption).foregroundStyle(.tertiary) }
            } header: { Text("网络检查") } footer: { Text("主动请求 Apple 的公开网络测试页面。结果仅反映该地址通过当前系统路由的可达性。VPN 已连接不等于所有网站均可访问。") }
            if !events.isEmpty { Section("最近运行事件") { ForEach(Array(events.enumerated()), id: \.offset) { _, item in Text(item).font(.subheadline) } } }
            Section {
                ShareLink(item: report) { Label("分享脱敏诊断摘要", systemImage: "square.and.arrow.up") }
            } footer: { Text("摘要不包含订阅地址、节点密码或目标域名。分享前可以在系统面板中选择接收位置。") }
            #if DEBUG
            Section {
                Button("导入直连诊断配置") {
                    Task {
                        await model.perform {
                            guard let url = Bundle.main.url(forResource: "direct-diagnostic", withExtension: "yaml") else { throw DashError.message("诊断样本缺失。") }
                            let text = try String(contentsOf: url, encoding: .utf8)
                            let prepared = try ConfigurationParser.prepare(text)
                            try await model.save(prepared, name: "直连诊断", url: nil, usage: nil)
                        }
                    }
                }.accessibilityIdentifier("importDiagnostic")
            } header: { Text("开发验证") } footer: { Text("样本不含代理节点和个人凭据，所有流量选择 DIRECT，只用于检查本地隧道。它不能证明远端代理协议已通过测试。") }
            #endif
        }.navigationTitle("运行诊断").task {
            if let data = try? await model.tunnel.request("events"), let values = try? JSONDecoder().decode([String].self, from: data) { events = values }
        }
    }
    private func runCheck() {
        checking = true; checkResult = nil
        Task {
            defer { checking = false; checkedAt = Date() }
            do {
                let session = URLSession(configuration: .ephemeral); defer { session.invalidateAndCancel() }
                var request = URLRequest(url: URL(string: "https://www.apple.com/library/test/success.html")!); request.timeoutInterval = 12
                let (_, response) = try await session.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                checkResult = (200..<300).contains(code) ? "测试地址可达（HTTP \(code)）。" : "测试地址返回 HTTP \(code)。"
            } catch { checkResult = "测试地址暂时不可达。可检查节点、DNS 或当前网络后重试。" }
        }
    }
}

private struct LiveConnection: Identifiable {
    var id: String; var target: String; var network: String; var rule: String; var chain: String; var upload: Double; var download: Double
}

struct ConnectionsView: View {
    @Environment(AppModel.self) private var model
    @State private var connections: [LiveConnection] = []
    @State private var error: String?
    var body: some View {
        List {
            if model.tunnel.state != .connected { ContentUnavailableView("连接后查看", systemImage: "network", description: Text("这里显示核心实际观测到的当前连接。")) }
            else if connections.isEmpty { ContentUnavailableView("暂无活动连接", systemImage: "network", description: Text(error ?? "新建立的连接会显示在这里。")) }
            ForEach(connections) { connection in
                VStack(alignment: .leading, spacing: 7) {
                    HStack { Text(connection.target).font(.body.weight(.medium)).lineLimit(2); Spacer(); Text(connection.network.uppercased()).font(.caption).foregroundStyle(.secondary) }
                    Text("\(connection.rule) → \(connection.chain)").font(.caption).foregroundStyle(.secondary)
                    Text("↓ \(DashFormat.bytes(connection.download))  ↑ \(DashFormat.bytes(connection.upload))").font(.caption).monospacedDigit().foregroundStyle(.tertiary)
                }.padding(.vertical, 3).swipeActions {
                    Button("关闭", role: .destructive) { Task { _ = try? await model.tunnel.request("close", parameters: ["id": connection.id]); await reload() } }
                }
            }
        }.navigationTitle("当前连接").refreshable { await reload() }.task {
            while !Task.isCancelled { await reload(); try? await Task.sleep(for: .seconds(2)) }
        }
    }
    private func reload() async {
        guard model.tunnel.state == .connected else { connections = []; return }
        do {
            let data = try await model.tunnel.request("connections")
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let rows = object["connections"] as? [[String: Any]] ?? []
            connections = rows.prefix(100).compactMap { value in
                guard let id = value["id"] as? String else { return nil }
                let metadata = value["metadata"] as? [String: Any] ?? [:]
                let host = metadata["host"] as? String ?? ""; let ip = metadata["destinationIP"] as? String ?? "未知目标"
                return LiveConnection(id: id, target: host.isEmpty ? ip : host, network: metadata["network"] as? String ?? "TCP",
                    rule: value["rule"] as? String ?? "规则", chain: (value["chains"] as? [String] ?? []).joined(separator: " → "),
                    upload: (value["upload"] as? NSNumber)?.doubleValue ?? 0, download: (value["download"] as? NSNumber)?.doubleValue ?? 0)
            }
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}
