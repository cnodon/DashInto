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
                if connected { connectedHeader } else { preparationCard }
                if let error = model.connection.failure ?? model.tunnel.lastError {
                    DashCard { VStack(alignment: .leading, spacing: 8) {
                        Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                        Button("查看运行诊断") { model.selectedTab = .device }
                    } }.accessibilityIdentifier("connectionFailure")
                }
                if let profile = model.displayProfile {
                    if connected {
                        trafficCard
                        nodeCard
                        subscriptionCard(profile)
                        websitesCard
                        if model.connection.step == .limited {
                            Button { model.connection.retryCheck() } label: {
                                Label("部分网络检查未通过 · 重试", systemImage: "arrow.clockwise")
                                    .font(.caption).foregroundStyle(.orange)
                            }.frame(minHeight: 44).accessibilityIdentifier("retryNetworkCheck")
                        }
                    } else {
                        subscriptionCard(profile)
                        plannedRouteCard
                    }
                    if model.hasPendingUpdate { Button("订阅已更新 · 应用并重连") { model.useAndConnect(profile) }.font(.subheadline).disabled(model.connection.step.inProgress || model.busy) }
                }
            }.padding(.horizontal, 16).padding(.vertical, 8).frame(maxWidth: 680).frame(maxWidth: .infinity)
        }.background(Color.dashBackground).toolbar(.hidden, for: .navigationBar).accessibilityIdentifier("homePage")
            .sheet(isPresented: $showingSources) { SubscriptionPicker() }
            .sheet(item: $sheet) { HomeDetailSheet(detail: $0) }
            .sensoryFeedback(.success, trigger: passed) { _, value in value }
    }
    private var connectedHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: passed ? "checkmark.shield.fill" : "shield.lefthalf.filled")
                .font(.title2).foregroundStyle(passed ? Color.green : Color.dashBlue)
            VStack(alignment: .leading, spacing: 3) {
                Text(statusTitle).font(.title3.weight(.semibold)).accessibilityIdentifier("connectionStatus")
                if live, let runtime = model.tunnel.runtime {
                    HStack(spacing: 5) {
                        Text(runtime.startedAt, style: .timer).monospacedDigit()
                        Text("· " + (model.connection.step == .checking ? "正在检测网络" : model.mode.title))
                    }.font(.caption).foregroundStyle(.secondary)
                } else { Text("正在读取核心状态").font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 4)
            Button { connectionAction() } label: {
                Label(buttonTitle, systemImage: "power").font(.subheadline.weight(.medium))
                    .padding(.horizontal, 12).frame(minHeight: 44).background(Color.dashSurface, in: Capsule())
            }.buttonStyle(.plain).disabled(model.connection.step == .stopping)
                .accessibilityIdentifier("connectionButton")
        }
    }
    private var preparationCard: some View {
        DashCard {
            VStack(spacing: 16) {
                HStack {
                    Text("DashInto").font(.subheadline.weight(.semibold))
                    Spacer()
                    if model.connection.step.inProgress || model.tunnel.phase == .starting { ProgressView().accessibilityLabel("正在连接") }
                }
                Image(systemName: model.displayProfile == nil ? "network.badge.shield.half.filled" : "power")
                    .font(.system(size: 36, weight: .light)).foregroundStyle(Color.dashBlue)
                    .frame(width: 84, height: 84)
                    .background(Color.dashBlue.opacity(0.08), in: Circle()).accessibilityHidden(true)
                VStack(spacing: 6) {
                    Text(statusTitle).font(.title2.weight(.semibold)).accessibilityIdentifier("connectionStatus")
                    Text(preparationHint).font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }
                DashPrimaryButton(title: buttonTitle, symbol: model.displayProfile == nil ? "plus" : "power") { connectionAction() }
                    .disabled(model.busy || model.connection.step == .stopping).accessibilityIdentifier("connectionButton")
                if model.displayProfile == nil {
                    HStack(spacing: 8) {
                        Label("添加订阅", systemImage: "1.circle")
                        Image(systemName: "chevron.right").font(.caption2)
                        Label("一键连接", systemImage: "2.circle")
                    }.font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.vertical, 8)
        }
    }
    private func subscriptionCard(_ profile: Profile) -> some View {
        DashCard {
            VStack(spacing: 10) {
                if !connected { HStack {
                    Text("连接使用的订阅").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("更换") { showingSources = true }
                        .font(.caption.weight(.medium)).frame(minWidth: 44, minHeight: 44)
                        .disabled(model.busy || model.connection.step.inProgress)
                        .accessibilityIdentifier("changeHomeSubscription")
                } }
                NavigationLink { ProfileDetailView(profileID: profile.id).toolbar(.visible, for: .navigationBar) } label: {
                    SubscriptionBalanceView(profile: profile)
                }.buttonStyle(.plain).accessibilityIdentifier("homeSubscription")
            }
        }
    }
    private var plannedRouteCard: some View {
        Button { model.selectedTab = .proxies } label: {
            DashCard {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.triangle.branch").foregroundStyle(Color.dashBlue)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.mode.title).font(.subheadline.weight(.medium))
                        Text(model.plannedHomeRoute).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }.frame(minHeight: 44)
            }
        }.buttonStyle(.plain).foregroundStyle(.primary).disabled(!model.canEditRoutes)
            .accessibilityIdentifier("plannedRoute")
    }
    private func connectionAction() {
        if !model.connection.step.inProgress, model.tunnel.phase == .stopped,
           model.activeProfile == nil, !model.library.profiles.isEmpty { showingSources = true }
        else { Task { await model.toggleConnection() } }
    }
    private var preparationHint: String {
        if model.tunnel.state == .recovering { return "网络发生变化，正在恢复连接" }
        switch model.connection.step {
        case .stopping: return "正在恢复系统网络"
        case .preparing: return "正在读取已保存的订阅"
        case .authorizing: return "如系统询问，请允许添加 VPN 配置"
        case .starting: return "正在建立安全连接"
        case .failed: return "订阅已保留，可重新连接或更换线路"
        default:
            if model.activeProfile == nil {
                return model.library.profiles.isEmpty ? "导入订阅后，即可一键连接" : "选择一份已保存的订阅，即可开始"
            }
            return "已准备好，点击连接即可使用"
        }
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
        if model.connection.step == .stopping { return model.connection.step.title }
        if connected { return passed ? "已连接" : "VPN 已建立" }
        if model.tunnel.state == .recovering { return "正在恢复连接" }
        if model.connection.step.inProgress || model.connection.step == .failed { return model.connection.step.title }
        return model.activeProfile == nil && model.library.profiles.isEmpty ? "准备开始" : "未连接"
    }
    private var buttonTitle: String {
        if model.connection.step == .stopping { return "正在断开" }
        if connected { return "断开连接" }
        if model.connection.step.inProgress || [.connecting, .recovering].contains(model.tunnel.state) { return "取消连接" }
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
                Text(profile.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                if let balance = SubscriptionBalance(usage: profile.usage) {
                    Text(DashFormat.bytes(balance.remaining)).font(.title2.weight(.semibold)).monospacedDigit() + Text(" 剩余").font(.caption).foregroundStyle(.secondary)
                } else { Text("订阅未提供额度信息").font(.caption).foregroundStyle(.secondary) }
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
