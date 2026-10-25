import SwiftUI
import ClashDashKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("appearance") private var appearance = "system"
    var body: some View {
        List {
            Section {
                NavigationLink { AppUpdateView() } label: {
                    HStack { Label("软件更新", systemImage: "arrow.down.circle"); Spacer(); if model.updates.hasUpdate { Text("新版本").font(.caption).foregroundStyle(Color.dashBlue) } }
                }.accessibilityIdentifier("softwareUpdate")
            }
            Section("外观") {
                Picker("外观模式", selection: $appearance) {
                    Text("跟随系统").tag("system"); Text("浅色").tag("light"); Text("深色").tag("dark")
                }
            }
            Section("连接与排障") {
                NavigationLink { ConnectionHelpView().toolbar(.visible, for: .navigationBar) } label: { Label("连接行为", systemImage: "switch.2") }
                NavigationLink { ImportSupportView().toolbar(.visible, for: .navigationBar) } label: { Label("导入格式与协议", systemImage: "arrow.down.doc") }
            }
            Section("隐私与数据") {
                NavigationLink { PrivacyView().toolbar(.visible, for: .navigationBar) } label: { Label("数据与隐私", systemImage: "hand.raised") }
                NavigationLink { LicenseView().toolbar(.visible, for: .navigationBar) } label: { Label("开源许可", systemImage: "doc.text") }
            }
            Section {
                LabeledContent("App 版本", value: DashConstants.appVersion)
                LabeledContent("核心", value: "mihomo 1.19.33")
                LabeledContent("Apple SDK", value: "Clash .3")
            } footer: { Text("个人开发版本 · 配置由你提供，运行状态以系统与核心回执为准。") }
        }.listSectionSpacing(.compact).contentMargins(.top, 8, for: .scrollContent).toolbar(.hidden, for: .navigationBar).accessibilityIdentifier("settingsPage")
    }
}

struct ImportSupportView: View {
    var body: some View {
        List {
            Section("完整配置") {
                Text("Clash / mihomo YAML 或 JSON：保留节点、策略组、分流规则和 DNS，自动适配 iOS 网络环境。")
            }
            Section("节点集合") {
                Text("支持常见节点分享链接、Base64 节点订阅、Shadowrocket JSON、sing-box / V2Ray 出站节点、SIP008 / SSD、Surge 的 Proxy 节点和 WireGuard INI。")
                Text("节点集合会生成手动选择策略。原客户端的 DNS、路由、脚本及其他专有设置不会自动迁移，保存前会显示提示。")
                    .foregroundStyle(.secondary)
            }
            Section("可识别的分享链接类型") {
                ForEach(NativeConfigImporter.supportedSchemes, id: \.self) { scheme in Text(scheme + "://").font(.system(.subheadline, design: .monospaced)) }
            }
            Section {
                Text("Clash 和 Shadowrocket 是客户端或配置格式名称。实际连接使用 Shadowsocks、Trojan、VMess、VLESS、AnyTLS、Hysteria、TUIC 等协议。能够识别格式不保证每个节点都可连接；请在连接后测试延迟与网络可达性。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }.font(.subheadline).navigationTitle("导入格式与协议")
    }
}

struct ConnectionHelpView: View {
    var body: some View {
        List {
            Section("连接方式") { Text("使用 iOS 的 VPN 隧道承载网络流量。第一次连接时，系统会请求允许添加 VPN 配置。").font(.subheadline) }
            Section("自动配置") { Text("订阅中的节点、代理组、分流规则和 DNS 会自动读取。桌面监听端口、TUN 和外部控制器设置由 iOS 运行环境接管。").font(.subheadline) }
            Section("节点切换") { Text("选择新节点影响之后建立的新连接。已有下载、通话或其他长连接可能继续使用原来的路径。").font(.subheadline) }
            Section("更新") { Text("更新下载的新版本会保存在本机，重新连接后生效。历史版本可以在配置详情中恢复。").font(.subheadline) }
            Section("系统边界") { Text("规则与全局模式描述核心的路由策略。系统服务及特定网络流量可能受 iOS 的路由例外影响。当前版本使用手动连接。").font(.subheadline) }
        }.navigationTitle("连接行为")
    }
}

struct PrivacyView: View {
    var body: some View {
        List {
            Section("保存在本机") { Text("订阅地址、原始配置和运行配置使用 AES-GCM 加密。密钥保存在系统 Keychain。配置元数据和版本列表保存在受保护的应用容器中。").font(.subheadline) }
            Section("网络数据") { Text("流量会按你导入的配置发送到相应的节点、DNS 服务和远程规则来源。订阅及节点服务仍会收到建立连接所需的数据。").font(.subheadline) }
            Section("首页检查与更新") { Text("连接后，首页会向 Cloudflare 查询本次检测的出口 IP，并检查 Google、YouTube、OpenAI、Claude 的网页响应。软件更新只访问设置中指定的公共 GitHub 仓库；不会上传订阅或节点凭据。更新通知需要你单独开启。").font(.subheadline) }
            Section("诊断与分享") { Text("App 未接入广告或行为分析。诊断摘要在本机生成；只有你主动打开系统分享时才会交给你选择的目标。原始 YAML 可能包含密码，请谨慎复制。").font(.subheadline) }
            Section("权限") { Text("基础连接只需要系统 VPN 授权和网络访问。不会在后台读取剪贴板，不需要通讯录、照片或位置权限。").font(.subheadline) }
        }.navigationTitle("数据与隐私")
    }
}

struct LicenseView: View {
    var body: some View {
        List {
            Section { Text("DashInto 使用 ProjectClash 的 mihomo 派生核心和 PacketFlow Adapter，遵循 GPL-3.0。Yams 使用 MIT 许可。").font(.subheadline) }
            Section("随 App 提供的许可") {
                document("GPL-3.0", name: "GPL-3.0", ext: "txt")
                document("核心声明", name: "NOTICE", ext: nil)
                document("Yams · MIT", name: "Yams-MIT", ext: "txt")
                NavigationLink("核心第三方许可") { ThirdPartyLicenseList() }
            }
            Section("对应源码") {
                Link("网络核心", destination: URL(string: "https://github.com/ProjectClash/Clash/tree/7f6b34584e4aa67f37239a9ca2a3a49b578639e3")!)
                Link("PacketFlow 桥接", destination: URL(string: "https://github.com/ProjectClash/Clash-Adapter/tree/bdf40d4148eca4ead785fe54d724abd79d020876")!)
                Link("Yams", destination: URL(string: "https://github.com/jpsim/Yams/tree/5.4.0")!)
            }
        }.navigationTitle("开源许可")
    }
    @ViewBuilder private func document(_ title: String, name: String, ext: String?) -> some View {
        if let url = Bundle.main.url(forResource: name, withExtension: ext) {
            NavigationLink(title) { LicenseDocumentView(title: title, url: url) }
        }
    }
}

private struct ThirdPartyLicenseList: View {
    @State private var files: [URL] = []
    @State private var search = ""
    private var root: URL? { Bundle.main.resourceURL?.appendingPathComponent("THIRD_PARTY_LICENSES") }
    private func title(_ url: URL) -> String { url.path.replacingOccurrences(of: (root?.path ?? "") + "/", with: "") }
    var body: some View {
        List(files.filter { search.isEmpty || title($0).localizedCaseInsensitiveContains(search) }, id: \.path) { url in
            NavigationLink { LicenseDocumentView(title: url.lastPathComponent, url: url) } label: {
                Text(title(url)).font(.subheadline).lineLimit(3)
            }
        }.navigationTitle("第三方许可").searchable(text: $search, prompt: "搜索组件")
            .task {
                guard let root, let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return }
                files = iterator.compactMap { $0 as? URL }.filter { url in
                    (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true && url.pathExtension != "json"
                }.sorted { title($0) < title($1) }
            }
    }
}

private struct LicenseDocumentView: View {
    let title: String
    let url: URL
    @State private var text = ""
    var body: some View {
        ScrollView { Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(20) }
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .task { text = (try? String(contentsOf: url, encoding: .utf8)) ?? "无法读取许可文本。" }
    }
}
