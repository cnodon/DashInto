import SwiftUI
import ClashDashKit

enum HomeDetail: Identifiable {
    case node, egress, website(WebsiteProbeResult)
    var id: String { switch self { case .node: "node"; case .egress: "egress"; case .website(let result): result.id } }
    var title: String { switch self { case .node: "当前节点"; case .egress: "检测出口"; case .website(let result): result.id } }
}

struct HomeDetailSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let detail: HomeDetail
    @State private var pending: String?
    var body: some View {
        NavigationStack {
            List {
                switch detail {
                case .node:
                    Section {
                        HStack(spacing: 12) {
                            DashGlyph(symbol: model.mode == .direct ? "network" : "paperplane.fill")
                            VStack(alignment: .leading, spacing: 4) {
                                Text(model.homeProxyTitle).font(.headline).lineLimit(2)
                                Text(model.mode.title).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if model.tunnel.state == .connected, let name = model.homeNode {
                                Button { model.startDelayTests([name]) } label: { Image(systemName: "gauge.with.dots.needle.33percent").frame(width: 44, height: 44) }
                                    .disabled(model.delayTests.isRunning).accessibilityLabel("测试节点延迟")
                            }
                        }
                    }
                    if let group = model.homeGroup {
                        Section(group.name) {
                            ForEach(group.members, id: \.self) { name in
                                Button {
                                    pending = name
                                    Task {
                                        await model.select(group: group, member: name)
                                        pending = nil
                                        if model.displayGroups.first(where: { $0.name == group.name })?.selected == name { dismiss() }
                                    }
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: group.selected == name ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(group.selected == name ? Color.dashBlue : Color.secondary.opacity(0.35))
                                        Text(name).font(.subheadline).foregroundStyle(.primary).lineLimit(2)
                                        Spacer(minLength: 4)
                                        if pending == name { ProgressView() }
                                        else if let delay = model.delays[name] { DelayIndicator(milliseconds: delay) }
                                    }.frame(minHeight: 44).contentShape(Rectangle())
                                }.buttonStyle(.plain).disabled(!group.isSelectable || !model.canEditRoutes || pending != nil)
                                    .accessibilityIdentifier("homeSelect-" + name)
                            }
                            if group.members.isEmpty { Text("连接后读取远程节点").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    if model.visibleGroups.count > 1 {
                        Section {
                            Menu {
                                ForEach(model.visibleGroups) { group in
                                    Button { model.homeGroupName = group.name } label: {
                                        if group.id == model.homeGroup?.id { Label(group.name, systemImage: "checkmark") }
                                        else { Text(group.name) }
                                    }
                                }
                            } label: { LabeledContent("显示策略", value: model.homeGroup?.name ?? "默认") }
                        }
                    }
                    Section {
                        DisclosureGroup("详情") {
                            if let name = model.homeNode {
                                LabeledContent("协议", value: model.proxyKinds[name] ?? "—")
                                if let date = model.delayDates[name] { LabeledContent("最近测速") { Text(date, format: .dateTime.hour().minute().second()) } }
                            }
                            Text("规则模式下不同网站可使用不同节点。节点速率是活跃连接估算，测速是 HTTPS 响应延迟。").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                case .egress:
                    Section {
                        LabeledContent("公网 IP", value: model.dashboard.egress?.address ?? "未取得").textSelection(.enabled)
                        if let code = model.dashboard.egress?.countryCode { LabeledContent("地区", value: Locale.current.localizedString(forRegionCode: code) ?? code) }
                        if let date = model.dashboard.egress?.date { LabeledContent("检测时间") { Text(date, format: .dateTime.hour().minute().second()) } }
                        LabeledContent("检测来源", value: "Cloudflare")
                        Button("刷新出口与网站") { model.dashboard.refreshNetwork(model.tunnel) }.disabled(model.dashboard.checking || model.tunnel.runtime == nil)
                    } footer: { Text("这是检测请求实际使用的公网出口。规则模式可能让不同网站走不同出口，IP 地区也不一定等于节点名称标注的地区。") }
                case .website(let result):
                    Section {
                        LabeledContent("结果", value: result.label)
                        LabeledContent("检测目标", value: result.host)
                        if let code = result.statusCode { LabeledContent("HTTP", value: String(code)) }
                        if let ms = result.milliseconds { LabeledContent("响应耗时", value: "\(ms) ms") }
                        LabeledContent("检测时间") { Text(result.date, format: .dateTime.hour().minute().second()) }
                    } footer: { Text("只检测网页响应；验证码、账号登录、地区权限及模型调用需在网站中确认。响应耗时包含建立连接和读取响应片段。") }
                }
            }.navigationTitle(detail.id == "node" && model.tunnel.state != .connected ? "选择节点" : detail.title).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}
