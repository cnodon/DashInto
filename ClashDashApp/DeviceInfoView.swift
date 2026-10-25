import SwiftUI
import Network
import Observation
import ClashDashKit

@Observable @MainActor
final class DeviceNetworkInfo {
    var network = "正在读取"
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
                self.network = name; self.ipv4 = path.supportsIPv4; self.ipv6 = path.supportsIPv6
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
            Section("设备") {
                LabeledContent("设备类型", value: UIDevice.current.model)
                LabeledContent("系统", value: UIDevice.current.systemName + " " + UIDevice.current.systemVersion)
                LabeledContent("DashInto", value: DashConstants.appVersion)
            }
            Section("接入网络") {
                LabeledContent("网络类型", value: network.network)
                LabeledContent("IP 支持", value: [network.ipv4 ? "IPv4" : nil, network.ipv6 ? "IPv6" : nil].compactMap { $0 }.joined(separator: " / "))
                LabeledContent("低数据模式", value: network.constrained ? "已开启" : "未开启")
                ForEach(Array(network.addresses.enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 3) { Text(item.0).font(.caption).foregroundStyle(.secondary); Text(item.1).font(.subheadline).textSelection(.enabled) }
                }
            }
            Section("VPN 与核心") {
                LabeledContent("系统 VPN", value: model.tunnel.state.title)
                LabeledContent("核心", value: model.tunnel.runtime?.coreVersion ?? "未运行")
                LabeledContent("核心内存", value: model.tunnel.runtime.map { DashFormat.bytes(Double($0.memoryBytes)) } ?? "—")
                LabeledContent("当前订阅", value: model.displayProfile?.name ?? "未选择")
                LabeledContent("规则数", value: model.activeSummary.map { String($0.rules.count) } ?? "—")
                NavigationLink { ConnectionsView().toolbar(.visible, for: .navigationBar) } label: { Label("当前连接", systemImage: "network") }
                NavigationLink { DiagnosticsView().toolbar(.visible, for: .navigationBar) } label: { Label("运行诊断", systemImage: "stethoscope") }
            }
        }.listSectionSpacing(.compact).contentMargins(.top, 8, for: .scrollContent)
            .toolbar(.hidden, for: .navigationBar).accessibilityIdentifier("devicePage")
            .onAppear { network.start() }.onDisappear { network.stop() }
    }
}
