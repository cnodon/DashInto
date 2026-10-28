import SwiftUI
import ClashDashKit

struct HomeWebsitesCard: View {
    var results: [WebsiteProbeResult]
    var checking: Bool
    var enabled: Bool
    var refresh: () -> Void
    var select: (WebsiteProbeResult) -> Void
    var body: some View {
        DashCard {
            VStack(spacing: 8) {
                HStack {
                    Text("连通性").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    if let date = results.map(\.date).max() { Text(date, format: .dateTime.hour().minute()).font(.caption2).foregroundStyle(.tertiary) }
                    Spacer()
                    Button(action: refresh) {
                        Group { if checking { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") } }
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }.disabled(!enabled || checking).accessibilityLabel("刷新出口与网站").accessibilityIdentifier("refreshWebsites")
                }
                HStack(spacing: 6) {
                    ForEach(DashboardNetworkProbe.targets, id: \.0) { target in
                        let result = results.first { $0.id == target.0 }
                        let color: Color = result == nil ? .secondary : result?.state == .available ? .green : .orange
                        Button { if let result { select(result) } } label: {
                            VStack(spacing: 7) {
                                Image(systemName: symbol(target.0)).font(.system(size: 19, weight: .medium))
                                    .foregroundStyle(.primary).frame(height: 24).accessibilityHidden(true)
                                Text(target.0).font(.caption2.weight(.medium)).foregroundStyle(.primary).lineLimit(1).minimumScaleFactor(0.8)
                                HStack(spacing: 3) {
                                    Circle().fill(color).frame(width: 4, height: 4)
                                    Text(result?.label ?? "—").font(.caption2).monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
                                }.foregroundStyle(color)
                            }.frame(maxWidth: .infinity).padding(.vertical, 10)
                                .background(color.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(result == nil).accessibilityIdentifier("website-" + target.0)
                    }
                }
            }
        }
    }
    private func symbol(_ name: String) -> String {
        switch name { case "Google": "globe"; case "YouTube": "play.rectangle.fill"; case "OpenAI": "sparkles"; default: "asterisk" }
    }
}
