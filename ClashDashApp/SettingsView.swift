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
            Section {
                Picker(selection: $appearance) {
                    Text("跟随系统").tag("system"); Text("浅色").tag("light"); Text("深色").tag("dark")
                } label: { Label("外观", systemImage: "circle.lefthalf.filled") }
            }
            Section("隐私与数据") {
                NavigationLink { PrivacyView().toolbar(.visible, for: .navigationBar) } label: { Label("数据与隐私", systemImage: "hand.raised") }
                NavigationLink { LicenseView().toolbar(.visible, for: .navigationBar) } label: { Label("开源许可", systemImage: "doc.text") }
            }
            Section {
                LabeledContent("App 版本", value: DashConstants.appVersion)

            }
        }.listSectionSpacing(.compact).contentMargins(.top, 8, for: .scrollContent).toolbar(.hidden, for: .navigationBar).accessibilityIdentifier("settingsPage")
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
