#if DEBUG && targetEnvironment(simulator)
import SwiftUI
import ClashDashKit

/// Read-only, synthetic presentation. Never sets VPN state, starts a tunnel, or imports a subscription.
struct DashboardDesignPreview: View {
    private let date = Date()
    private var samples: [TrafficSample] {
        (0..<60).map { index in
            let time = Double(index)
            var sample = TrafficSample(upload: 110_000 + 35_000 * sin(time / 4),
                                       download: 1_200_000 + 450_000 * sin(time / 5) + 190_000 * cos(time / 2.7))
            sample.date = date.addingTimeInterval(Double(index - 59)); return sample
        }
    }
    private var profile: Profile {
        let summary = ConfigurationSummary(nodes: (1...24).map { ProxyNode(name: "Example \($0)", kind: "Shadowsocks") }, groups: [], rules: [], providerCount: 0, warnings: [])
        let version = ProfileVersion(id: UUID().uuidString, createdAt: date, contentHash: "preview", summary: summary)
        return Profile(name: "旅途 · 示例订阅", isSubscription: true, sourceHost: "example.invalid", version: version,
                       usage: .parse("upload=5000000000; download=27000000000; total=100000000000; expire=1814486400"))
    }
    private var sites: [WebsiteProbeResult] {
        DashboardNetworkProbe.targets.enumerated().map { index, target in
            WebsiteProbeResult(id: target.0, host: "example.invalid", state: index == 3 ? .challenge : .available,
                               statusCode: index == 3 ? 403 : 200, milliseconds: 90 + index * 31, date: date)
        }
    }
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Label("界面预览 · 示例数据", systemImage: "paintpalette")
                    .font(.caption.weight(.medium)).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
                VStack(spacing: 8) {
                    Label("已连接 · 12:08", systemImage: "circle.fill").font(.caption).foregroundStyle(.secondary)
                    Text("订阅 · " + profile.name).font(.subheadline).foregroundStyle(.secondary)
                    HomeRouteTitle(title: "日本 · Tokyo 01")
                    HStack(spacing: 14) {
                        Text("规则").font(.caption).foregroundStyle(.secondary)
                        DelayIndicator(milliseconds: 92)
                    }.frame(minHeight: 44)
                    Label("断开连接", systemImage: "power").font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 54).foregroundStyle(.white).background(.red, in: Capsule())
                }.padding(.horizontal, 14).padding(.top, 16).padding(.bottom, 16)
                HomeTrafficPanel(samples: samples, downloadRate: 1_820_000, uploadRate: 128_000,
                                 downloaded: 128_000_000, uploaded: 9_600_000, connectionCount: 24,
                                 nodeRate: previewNodeRate, address: "203.0.113.42", countryCode: "JP", onEgress: {})
                DashCard { SubscriptionBalanceView(profile: profile) }
                HomeWebsitesCard(results: sites, checking: false, enabled: false, refresh: {}, select: { _ in })
            }.padding(.horizontal, 16).padding(.vertical, 8).frame(maxWidth: 680).frame(maxWidth: .infinity)
        }.background(Color.dashBackground).toolbar(.hidden, for: .navigationBar)
            .accessibilityIdentifier("dashboardDesignPreview")
    }
    private var previewNodeRate: NodeTrafficRate {
        var value = NodeTrafficRate(); value.download = 1_580_000; value.upload = 96_000; return value
    }
}

@MainActor extension AppModel {
    func seedBlockedRefreshForUITest() async {
        guard library.profiles.isEmpty else { return }
        do {
            let text = """
            proxies:
              - {name: Route1, type: ss, server: 127.0.0.1, port: 19871, cipher: aes-128-gcm, password: synthetic}
              - {name: Route2, type: ss, server: 127.0.0.1, port: 19872, cipher: aes-128-gcm, password: synthetic}
            proxy-groups:
              - {name: Choose, type: select, proxies: [Route1, Route2]}
            rules: ["MATCH,Choose"]
            """
            let commit = try await save(ConfigurationParser.prepare(text), name: "界面测试 · 自动更新阻塞", url: URL(string: "https://fixture.invalid/sub"), usage: nil)
            library = try await store.select(commit.profileID)
            selectedTab = .home
            if let profile = library.activeProfile { Task { await self.refresh(profile, automatic: true) } }
        } catch { errorMessage = error.localizedDescription }
    }
    /// Synthetic report in an isolated UI-test library. No VPN or remote requests.
    func seedDelayResultsForUITest() async {
        do {
            let names = ["示例可用", "示例超时", "示例失败"]
            let nodes = names.enumerated().map { index, name in
                ["name": name, "type": "ss", "server": "127.0.0.1", "port": 19000 + index,
                 "cipher": "aes-128-gcm", "password": "synthetic-test"] as [String: Any]
            }
            let bytes = try JSONSerialization.data(withJSONObject: ["proxies": nodes, "rules": ["MATCH,DIRECT"]])
            let prepared = try ConfigurationParser.prepare(String(decoding: bytes, as: UTF8.self))
            let commit = try await save(prepared, name: "界面测试 · 示例数据", url: nil, usage: nil)
            library = try await store.select(commit.profileID)
            lastDelayEndpoint = .cloudflare
            delayTests.start(names: names, isCurrent: { true }, test: { name in
                name == "示例可用" ? 42 : name == "示例超时" ? -1 : -2
            }, receive: { [weak self] name, value in self?.delays[name] = value; self?.delayDates[name] = Date() })
            selectedTab = .proxies
        } catch { errorMessage = error.localizedDescription }
    }
}
#endif
