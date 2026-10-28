import SwiftUI
import Network
import Observation
import ClashDashKit

@Observable @MainActor
final class DeviceNetworkInfo {
    var network = "正在读取"
    var online = false
    var ipv4 = false
    var ipv6 = false
    var constrained = false
    var addresses: [(String, String)] = []
    @ObservationIgnored private var monitor: NWPathMonitor?
    func start() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor(); self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let name = path.status != .satisfied ? "无可用网络" : path.usesInterfaceType(.wifi) ? "Wi-Fi" : path.usesInterfaceType(.cellular) ? "蜂窝网络" : path.usesInterfaceType(.wiredEthernet) ? "有线网络" : "其他接口"
            Task { @MainActor [weak self] in
                guard let self, self.monitor != nil else { return }
                self.network = name; self.online = path.status == .satisfied; self.ipv4 = path.supportsIPv4; self.ipv6 = path.supportsIPv6
                self.constrained = path.isConstrained; self.addresses = Self.localAddresses()
            }
        }
        monitor.start(queue: DispatchQueue(label: "app.clashdash.device-network"))
    }
    func stop() { monitor?.cancel(); monitor = nil }
    private static func localAddresses() -> [(String, String)] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let start = list else { return [] }
        defer { freeifaddrs(list) }
        var result: [(String, String)] = []
        var pointer: UnsafeMutablePointer<ifaddrs>? = start
        while let item = pointer {
            defer { pointer = item.pointee.ifa_next }
            guard let address = item.pointee.ifa_addr, item.pointee.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            let name = String(cString: item.pointee.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("pdp_ip"), [AF_INET, AF_INET6].contains(Int32(address.pointee.sa_family)) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                result.append((name + (address.pointee.sa_family == AF_INET ? " · IPv4" : " · IPv6"), String(cString: host)))
            }
        }
        return result
    }
}

struct DeviceInfoView: View {
    @Environment(AppModel.self) private var model
    @State private var network = DeviceNetworkInfo()
    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    DashGlyph(symbol: network.network == "Wi-Fi" ? "wifi" : network.network == "蜂窝网络" ? "antenna.radiowaves.left.and.right" : "network", color: network.online ? .dashBlue : .secondary)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(network.network).font(.headline)
                        HStack(spacing: 8) {
                            Label("IPv4", systemImage: network.ipv4 ? "checkmark.circle.fill" : "minus.circle")
                                .foregroundStyle(network.ipv4 ? Color.green : Color.secondary)
                            Label("IPv6", systemImage: network.ipv6 ? "checkmark.circle.fill" : "minus.circle")
                                .foregroundStyle(network.ipv6 ? Color.green : Color.secondary)
                            if network.constrained { Image(systemName: "leaf").accessibilityLabel("低数据模式") }
                        }.font(.caption2)
                    }
                }.padding(.vertical, 5)
                if !network.addresses.isEmpty {
                    DisclosureGroup("本机地址") {
                        ForEach(Array(network.addresses.enumerated()), id: \.offset) { _, item in
                            VStack(alignment: .leading, spacing: 3) { Text(item.0).font(.caption2).foregroundStyle(.secondary); Text(item.1).font(.caption).monospaced().textSelection(.enabled) }
                        }
                    }.font(.subheadline)
                }
            }
            Section("设备") {
                LabeledContent("设备类型", value: UIDevice.current.model)
                LabeledContent("系统", value: UIDevice.current.systemName + " " + UIDevice.current.systemVersion)
            }
            Section {
                HStack {
                    Label(model.tunnel.state.title, systemImage: "shield.lefthalf.filled").foregroundStyle(model.tunnel.state == .connected ? Color.green : Color.secondary)
                    Spacer()
                    if let runtime = model.tunnel.runtime { Text(runtime.coreVersion).foregroundStyle(.tertiary) }
                }.font(.caption)
                HStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.tunnel.runtime.map { DashFormat.bytes(Double($0.memoryBytes)) } ?? "—")
                            .font(.system(.title3, design: .rounded, weight: .semibold)).monospacedDigit()
                        Label("核心内存", systemImage: "memorychip").font(.caption2).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.activeSummary.map { String($0.rules.count) } ?? "—")
                            .font(.system(.title3, design: .rounded, weight: .semibold)).monospacedDigit()
                        Label("规则", systemImage: "arrow.triangle.branch").font(.caption2).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.padding(.vertical, 6)
                NavigationLink { ConnectionsView().toolbar(.visible, for: .navigationBar) } label: { Label("活动连接", systemImage: "point.3.connected.trianglepath.dotted") }
                NavigationLink { DiagnosticsView().toolbar(.visible, for: .navigationBar) } label: { Label("运行诊断", systemImage: "stethoscope") }
            }
        }.listSectionSpacing(.compact).contentMargins(.top, 8, for: .scrollContent)
            .toolbar(.hidden, for: .navigationBar).accessibilityIdentifier("devicePage")
            .onAppear { network.start() }.onDisappear { network.stop() }
    }
}
