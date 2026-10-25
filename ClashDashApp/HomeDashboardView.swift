import SwiftUI
import Charts
import ClashDashKit

struct OverviewView: View {
    @Environment(AppModel.self) private var model
    @State private var showingSources = false
    @State private var sheet: HomeDetail?
    @State private var chartDate: Date?
    private var connected: Bool { model.tunnel.state == .connected }
    private var live: Bool { connected && model.tunnel.runtime != nil }
    private var sampled: Bool { live && !model.traffic.isEmpty }
    private var passed: Bool { live && model.connection.checkedSession == model.tunnel.runtime?.sessionID && model.connection.check?.successful == true }
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: passed ? "checkmark.shield" : "shield").font(.title2).foregroundStyle(passed ? Color.green : Color.dashBlue)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(statusTitle).font(.title3.weight(.semibold)).accessibilityIdentifier("connectionStatus")
                        if live, let runtime = model.tunnel.runtime {
                            HStack(spacing: 5) { Text(runtime.startedAt, style: .timer).monospacedDigit(); Text("· " + model.mode.title) }.font(.caption).foregroundStyle(.secondary)
                        } else { Text(model.connection.step.inProgress ? "等待系统与核心回执" : model.mode.title).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 4)
                    Button { Task { await model.toggleConnection() } } label: {
                        Label(buttonTitle, systemImage: "power").font(.subheadline.weight(.medium)).padding(.horizontal, 12).frame(minHeight: 44)
                            .background(connected ? Color.dashSurface : Color.dashBlue, in: Capsule()).foregroundStyle(connected ? Color.primary : .white)
                    }.buttonStyle(.plain).disabled(model.busy || model.connection.step == .stopping).accessibilityIdentifier("connectionButton")
                }
                if let error = model.connection.failure ?? model.tunnel.lastError {
                    DashCard { VStack(alignment: .leading, spacing: 8) {
                        Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                        Button("查看运行诊断") { model.selectedTab = .device }
                    } }.accessibilityIdentifier("connectionFailure")
                }
                if let profile = model.displayProfile {
                    trafficCard
                    nodeCard
                    NavigationLink { ProfileDetailView(profileID: profile.id).toolbar(.visible, for: .navigationBar) } label: {
                        DashCard { SubscriptionBalanceView(profile: profile) }
                    }.buttonStyle(.plain).accessibilityIdentifier("homeSubscription")
                    websitesCard
                    if model.hasPendingUpdate { Button("订阅已更新 · 应用并重连") { model.useAndConnect(profile) }.font(.subheadline).disabled(model.connection.step.inProgress || model.busy) }
                } else {
                    EmptyCard(symbol: "rectangle.stack.badge.plus", title: model.library.profiles.isEmpty ? "添加你的订阅" : "订阅已保存", message: model.library.profiles.isEmpty ? "一次导入，下次一键连接" : "选一份订阅，即可连接")
                    if !model.library.profiles.isEmpty { Button("选择订阅") { showingSources = true } }
                }
            }.padding(.horizontal, 16).padding(.vertical, 8).frame(maxWidth: 680).frame(maxWidth: .infinity)
        }.background(Color.dashBackground).toolbar(.hidden, for: .navigationBar).accessibilityIdentifier("homePage")
            .sheet(isPresented: $showingSources) { SubscriptionPicker() }
            .sheet(item: $sheet) { HomeDetailSheet(detail: $0) }
            .sensoryFeedback(.success, trigger: passed) { _, value in value }
    }
    private var trafficCard: some View {
        DashCard { VStack(spacing: 8) {
            HStack(spacing: 12) {
                HomeRate(title: "总下载", value: sampled ? model.downloadRate : nil, symbol: "arrow.down", color: .dashBlue)
                HomeRate(title: "总上传", value: sampled ? model.uploadRate : nil, symbol: "arrow.up", color: .teal)
            }
            HStack { Text("最近 60 秒"); Spacer(); Text("KB/s") }.font(.caption2).foregroundStyle(.secondary)
            Chart {
                ForEach(model.traffic.filter { $0.date > Date().addingTimeInterval(-60) }) { sample in
                    AreaMark(x: .value("时间", sample.date), y: .value("速率", sample.download / 1000)).foregroundStyle(Color.dashBlue.opacity(0.08))
                    LineMark(x: .value("时间", sample.date), y: .value("速率", sample.download / 1000), series: .value("方向", "下载")).foregroundStyle(Color.dashBlue).lineStyle(StrokeStyle(lineWidth: 1.7))
                    LineMark(x: .value("时间", sample.date), y: .value("速率", sample.upload / 1000), series: .value("方向", "上传")).foregroundStyle(Color.teal).lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                }
                if let chartDate { RuleMark(x: .value("时间", chartDate)).foregroundStyle(.secondary.opacity(0.5)) }
            }.chartXScale(domain: Date().addingTimeInterval(-60)...Date()).chartYScale(domain: .automatic(includesZero: true))
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) { _ in AxisValueLabel(format: .dateTime.minute().second()) } }
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
                .chartXSelection(value: $chartDate).frame(height: 86)
                .overlay { if !sampled { Text("等待实时采样").font(.caption).foregroundStyle(.secondary) } }
                .accessibilityLabel("最近60秒核心总流量，实线下载、虚线上传")
            if let chartDate, let sample = model.traffic.min(by: { abs($0.date.timeIntervalSince(chartDate)) < abs($1.date.timeIntervalSince(chartDate)) }) {
                Text("↓ \(DashFormat.bytes(sample.download))/s   ↑ \(DashFormat.bytes(sample.upload))/s").font(.caption).monospacedDigit()
            }
            Divider()
            HStack {
                stat("本次下载", sampled ? DashFormat.bytes(model.downloaded) : "—")
                stat("本次上传", sampled ? DashFormat.bytes(model.uploaded) : "—")
                stat("活跃连接", model.dashboard.connectionCount.map(String.init) ?? "—")
            }
        } }.accessibilityIdentifier("liveTrafficCard")
    }
    private var nodeCard: some View {
        DashCard { VStack(spacing: 7) {
            Button { sheet = .node } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(Color.dashBlue).frame(width: 28)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.homeGroup?.name ?? "订阅默认策略").font(.caption2).foregroundStyle(.secondary)
                            Text(model.homeNode ?? (live ? "等待策略回执" : "连接后显示节点")).font(.subheadline.weight(.semibold)).lineLimit(2)
                        }
                        Spacer(minLength: 4)
                        if let name = model.homeNode, let delay = model.delays[name] { Text(delay > 0 ? "\(delay) ms" : "超时").font(.caption).foregroundStyle(.secondary) }
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    }
                    let rate = model.homeNode.flatMap { name in model.dashboard.nodeRates.map { $0[name] ?? NodeTrafficRate() } }
                    HStack(spacing: 12) {
                        Text("↓ " + (rate.map { DashFormat.bytes($0.download) + "/s" } ?? "—"))
                        Text("↑ " + (rate.map { DashFormat.bytes($0.upload) + "/s" } ?? "—"))
                        Spacer(); Text("节点估算").foregroundStyle(.tertiary)
                    }.font(.caption).monospacedDigit().accessibilityIdentifier("nodeRate")
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).frame(minHeight: 60).accessibilityIdentifier("homeNode")
            Divider()
            Button { sheet = .egress } label: {
                HStack(spacing: 6) {
                    Text("检测出口").foregroundStyle(.secondary); Spacer(minLength: 3)
                    Text(model.dashboard.egress?.address ?? (model.dashboard.checking ? "检测中" : model.dashboard.egress == nil ? "待检测" : "暂不可用")).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                    if let code = model.dashboard.egress?.countryCode { Text(code).foregroundStyle(.secondary) }
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }.font(.caption).frame(minHeight: 34).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("egressAddress")
        } }
    }
    private var websitesCard: some View {
        DashCard { VStack(spacing: 2) {
            HStack {
                Text("网站连通性").font(.caption).foregroundStyle(.secondary)
                if let date = model.dashboard.sites.map(\.date).max() { Text(date, format: .dateTime.hour().minute()).font(.caption2).foregroundStyle(.tertiary) }
                Spacer()
                Button { model.dashboard.refreshNetwork(model.tunnel) } label: {
                    Label(model.dashboard.checking ? "检测中" : "全部刷新", systemImage: "arrow.clockwise").font(.caption)
                }.frame(minHeight: 36).disabled(!live || model.dashboard.checking).accessibilityIdentifier("refreshWebsites")
            }
            HStack(spacing: 2) {
                ForEach(DashboardNetworkProbe.targets, id: \.0) { target in
                    let result = model.dashboard.sites.first { $0.id == target.0 }
                    Button { if let result { sheet = .website(result) } } label: {
                        VStack(spacing: 5) {
                            Text(target.0).font(.caption.weight(.medium)).foregroundStyle(.primary).lineLimit(1).minimumScaleFactor(0.8)
                            Text(result?.label ?? (model.dashboard.checking ? "检测中" : "未检测")).font(.caption2).monospacedDigit()
                                .foregroundStyle(result == nil ? Color.secondary : result?.state == .available ? Color.green : Color.orange)
                        }.frame(maxWidth: .infinity).frame(minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(result == nil).accessibilityIdentifier("website-" + target.0)
                }
            }
        } }
    }
    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(label).font(.caption2).foregroundStyle(.secondary); Text(value).font(.caption.weight(.medium)).monospacedDigit() }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var statusTitle: String {
        if model.connection.step.inProgress || model.connection.step == .failed { return model.connection.step.title }
        if connected { return passed ? "已连接" : "VPN 已建立" }
        return model.activeProfile == nil && model.library.profiles.isEmpty ? "准备开始" : "未连接"
    }
    private var buttonTitle: String {
        if model.connection.step == .stopping { return "正在断开" }
        if model.connection.step.inProgress || [.connecting, .recovering].contains(model.tunnel.state) { return "取消连接" }
        if connected { return "断开连接" }
        if model.activeProfile == nil { return model.library.profiles.isEmpty ? "添加订阅" : "选择订阅" }
        return model.connection.failure == nil ? "连接" : "重新连接"
    }
}

private struct HomeRate: View {
    var title: String; var value: Double?; var symbol: String; var color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label { Text(title).foregroundStyle(.secondary) } icon: { Image(systemName: symbol).foregroundStyle(color) }.font(.caption)
            Text(value.map { DashFormat.bytes($0) + "/s" } ?? "—")
                .font(.system(.title2, design: .rounded, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SubscriptionBalanceView: View {
    var profile: Profile
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(profile.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let balance = SubscriptionBalance(usage: profile.usage) {
                    Text(DashFormat.bytes(balance.remaining)).font(.title2.weight(.semibold)).monospacedDigit() + Text(" 剩余").font(.caption).foregroundStyle(.secondary)
                } else { Text("未提供额度").font(.subheadline.weight(.medium)) }
                HStack(spacing: 4) {
                    if let expiry = profile.usage?.expiresAt { Text(expiry < Date() ? "已到期" : "到期 " + expiry.formatted(.dateTime.month().day())).foregroundStyle(expiry < Date() ? Color.orange : Color.secondary) }
                    Text(profile.updatedAt, format: .dateTime.hour().minute()); Text("更新")
                }.font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if let balance = SubscriptionBalance(usage: profile.usage) {
                ZStack {
                    Circle().stroke(Color.secondary.opacity(0.12), lineWidth: 5)
                    Circle().trim(from: 0, to: balance.fraction).stroke(balance.fraction < 0.1 ? Color.orange : Color.dashBlue, style: StrokeStyle(lineWidth: 5, lineCap: .round)).rotationEffect(.degrees(-90))
                    Text(balance.fraction, format: .percent.precision(.fractionLength(0))).font(.caption.weight(.semibold)).monospacedDigit()
                }.frame(width: 56, height: 56).accessibilityLabel("剩余额度 \(Int(balance.fraction * 100))%")
            }
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
        }.frame(minHeight: 62)
    }
}
