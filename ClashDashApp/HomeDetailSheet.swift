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
    var body: some View {
        NavigationStack {
            List {
                switch detail {
                case .node:
                    Section {
                        LabeledContent("当前节点", value: model.homeNode ?? "连接后读取")
                        if let name = model.homeNode {
                            LabeledContent("协议", value: model.proxyKinds[name] ?? "—")
                            Button("测试节点延迟") { Task { await model.testDelay(name) } }.disabled(model.testingNames.contains(name))
                            if let date = model.delayDates[name] { LabeledContent("最近测量") { Text(date, format: .dateTime.hour().minute().second()) } }
                        }
                        if let group = model.homeGroup { NavigationLink("选择这个策略的线路") { PolicyDetailView(groupName: group.name) } }
                    } footer: { Text("节点速率按仍活动的连接估算，不代表带宽上限。规则模式中，不同网站可使用不同节点。") }
                    Section("首页关注的策略") {
                        ForEach(model.visibleGroups) { group in
                            Button { model.homeGroupName = group.name } label: {
                                HStack { Text(group.name).foregroundStyle(.primary); Spacer(); if group.id == model.homeGroup?.id { Image(systemName: "checkmark") } }
                            }
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
            }.navigationTitle(detail.title).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}
