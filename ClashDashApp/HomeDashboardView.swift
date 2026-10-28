import SwiftUI
import ClashDashKit

struct OverviewView: View {
    @Environment(AppModel.self) private var model
    @State private var showingSources = false
    @State private var sheet: HomeDetail?
    @State private var disconnectTaps = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var connected: Bool { model.tunnel.state == .connected }
    private var live: Bool { connected && model.tunnel.runtime != nil }
    private var sampled: Bool { live && !model.traffic.isEmpty }
    private var passed: Bool { live && model.connection.checkedSession == model.tunnel.runtime?.sessionID && model.connection.check?.successful == true }
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                proxyCard
                if let error = model.connection.failure ?? model.tunnel.lastError {
                    DashCard { VStack(alignment: .leading, spacing: 8) {
                        Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                        Button { model.selectedTab = .device } label: { Label("诊断", systemImage: "stethoscope").font(.caption).frame(minHeight: 44) }
                    } }.accessibilityIdentifier("connectionFailure")
                }
                if let profile = model.displayProfile {
                    if connected {
                        trafficCard
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
                    }
                    if model.hasPendingUpdate { Button("应用更新并重连") { model.useAndConnect(profile) }.font(.subheadline).disabled(model.connection.step.inProgress || model.busy) }
                }
            }.padding(.horizontal, 16).padding(.vertical, 8).frame(maxWidth: 680).frame(maxWidth: .infinity)
        }.background(Color.dashBackground).toolbar(.hidden, for: .navigationBar).accessibilityIdentifier("homePage")
            .sheet(isPresented: $showingSources) { SubscriptionPicker() }
            .sheet(item: $sheet) { HomeDetailSheet(detail: $0).presentationDetents([.medium, .large]).presentationDragIndicator(.visible) }
            .sensoryFeedback(.success, trigger: passed) { _, value in value }
            .sensoryFeedback(.impact(flexibility: .solid, intensity: 0.5), trigger: disconnectTaps)
            .refreshable {
                await model.refreshGroups()
                if let profile = model.displayProfile, profile.isSubscription, !model.busy, !model.connection.step.inProgress { await model.refresh(profile) }
            }
    }
    private var proxyCard: some View {
        DashCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    DashGlyph(symbol: model.displayProfile == nil ? "link" : model.mode == .direct ? "network" : "paperplane.fill", animated: model.connection.step.inProgress)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 5) {
                            Circle().fill(connected ? Color.green : Color.secondary.opacity(0.4)).frame(width: 5, height: 5)
                            Text(statusTitle).accessibilityIdentifier("connectionStatus")
                            if model.connection.step.inProgress { ProgressView().controlSize(.mini) }
                            if connected, let runtime = model.tunnel.runtime { Text(runtime.startedAt, style: .timer).monospacedDigit() }
                        }.font(.caption2).foregroundStyle(.secondary)
                        if model.displayProfile != nil {
                            Button { sheet = .node } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(model.homeProxyTitle).font(.title3.weight(.semibold)).foregroundStyle(.primary).lineLimit(2)
                                        .accessibilityIdentifier("homeProxyName")
                                    HStack(spacing: 4) {
                                        Text(model.homeGroup?.name ?? (model.mode == .direct ? "不经过代理节点" : "订阅默认策略")).lineLimit(1)
                                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                                    }.font(.caption2).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(!connected && !model.canEditRoutes)
                                .accessibilityIdentifier(connected ? "homeNode" : "plannedRoute")
                        } else { Text("DashInto").font(.title2.weight(.semibold)) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if model.displayProfile != nil {
                        VStack(alignment: .trailing, spacing: 4) {
                            Menu {
                                Picker("运行模式", selection: Binding(get: { model.mode }, set: { mode in Task { await model.setMode(mode) } })) {
                                    ForEach(RoutingMode.allCases, id: \.self) { Text($0.title).tag($0) }
                                }
                            } label: { Text(model.mode.label).font(.caption.weight(.medium)).frame(minWidth: 44, minHeight: 44) }
                                .disabled(!model.canEditRoutes).accessibilityIdentifier("homeMode")
                            if connected, let name = model.homeNode, let delay = model.delays[name] { DelayIndicator(milliseconds: delay) }
                        }
                    }
                }
                if model.displayProfile == nil || model.connection.step.inProgress && !connected {
                    Text(preparationHint).font(.caption).foregroundStyle(.secondary)
                }
                DashPrimaryButton(title: buttonTitle, symbol: model.displayProfile == nil ? "plus" : connected || model.connection.step.inProgress || model.tunnel.phase == .starting ? "power" : "paperplane.fill", tint: connected || model.connection.step == .stopping ? .red : .dashBlue) {
                    if connected { disconnectTaps += 1 }
                    connectionAction()
                }.disabled((!connected && model.busy) || model.connection.step == .stopping).accessibilityIdentifier("connectionButton")
            }
        }.animation(reduceMotion ? nil : DashMotion.state, value: connected)
    }
    private func subscriptionCard(_ profile: Profile) -> some View {
        DashCard {
            HStack(spacing: 8) {
                NavigationLink { ProfileDetailView(profileID: profile.id).toolbar(.visible, for: .navigationBar) } label: {
                    SubscriptionBalanceView(profile: profile)
                }.buttonStyle(.plain).accessibilityIdentifier("homeSubscription")
                Button { showingSources = true } label: {
                    Image(systemName: "arrow.left.arrow.right").font(.subheadline)
                        .frame(width: 44, height: 44).background(Color.dashBlue.opacity(0.07), in: Circle())
                }.buttonStyle(.plain).disabled(model.busy || model.connection.step.inProgress)
                    .accessibilityLabel("更换订阅").accessibilityIdentifier("changeHomeSubscription")
            }
        }
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
        HomeTrafficPanel(samples: model.traffic, downloadRate: sampled ? model.downloadRate : nil,
                         uploadRate: sampled ? model.uploadRate : nil,
                         downloaded: sampled ? model.downloaded : nil, uploaded: sampled ? model.uploaded : nil,
                         connectionCount: model.dashboard.connectionCount,
                         nodeRate: model.mode == .direct ? nil : model.homeNode.flatMap { name in model.dashboard.nodeRates.map { $0[name] ?? NodeTrafficRate() } },
                         address: model.dashboard.egress?.address, countryCode: model.dashboard.egress?.countryCode,
                         checking: model.dashboard.checking) { sheet = .egress }
    }
    private var websitesCard: some View {
        HomeWebsitesCard(results: model.dashboard.sites, checking: model.dashboard.checking, enabled: live,
                         refresh: { model.dashboard.refreshNetwork(model.tunnel) }, select: { sheet = .website($0) })
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

struct SubscriptionBalanceView: View {
    var profile: Profile
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                Text(profile.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                if let balance = SubscriptionBalance(usage: profile.usage) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(DashFormat.bytes(balance.remaining)).font(.system(.title3, design: .rounded, weight: .semibold)).monospacedDigit()
                        Text("剩余").font(.caption2).foregroundStyle(.secondary)
                    }
                } else { Text("额度未提供").font(.caption2).foregroundStyle(.tertiary) }
                HStack(spacing: 9) {
                    let summary = profile.current?.summary
                    Label(summary.map { $0.providerCount > 0 && $0.providerNodeCount == nil ? "远程" : String($0.nodes.count + ($0.providerNodeCount ?? 0)) } ?? "—", systemImage: "point.3.connected.trianglepath.dotted")
                        .accessibilityLabel(summary?.routeCountText ?? "节点信息未提供")
                    Label { Text(profile.updatedAt, style: .relative) } icon: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("订阅更新于 " + profile.updatedAt.formatted(.dateTime.month().day().hour().minute()))
                    if let expiry = profile.usage?.expiresAt {
                        Label { if expiry < Date() { Text("已到期") } else { Text(expiry, format: .dateTime.month().day()) } } icon: { Image(systemName: "calendar") }
                            .foregroundStyle(expiry < Date() ? Color.orange : Color.secondary)
                            .accessibilityLabel("到期 " + expiry.formatted(.dateTime.year().month().day()))
                    }
                }.font(.caption2).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if let balance = SubscriptionBalance(usage: profile.usage) { DashQuotaRing(fraction: balance.fraction) }
        }.frame(minHeight: 64)
    }
}
