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
                DashCard {
                    HStack(spacing: 12) {
                        DashGlyph(symbol: "paperplane.fill")
                        VStack(alignment: .leading, spacing: 5) {
                            Text("日本 · Tokyo 01").font(.headline)
                            Text("示例节点").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        DelayIndicator(milliseconds: 92)
                    }
                }
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
#endif
