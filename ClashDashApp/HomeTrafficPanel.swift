import SwiftUI
import Charts
import ClashDashKit

/// Pure presentation shared by the live home and the explicitly labelled simulator design preview.
struct HomeTrafficPanel: View {
    var samples: [TrafficSample]
    var downloadRate: Double?
    var uploadRate: Double?
    var downloaded: Double?
    var uploaded: Double?
    var connectionCount: Int?
    var nodeRate: NodeTrafficRate?
    var address: String?
    var countryCode: String?
    var checking = false
    var onEgress: () -> Void
    @State private var selection: Date?
    @Environment(\.dynamicTypeSize) private var typeSize
    private var end: Date { samples.last?.date ?? Date() }
    var body: some View {
        DashCard {
            VStack(spacing: 8) {
                HStack(spacing: 16) {
                    rate(downloadRate, symbol: "arrow.down", color: .dashBlue, label: "总下载")
                    rate(uploadRate, symbol: "arrow.up", color: .teal, label: "总上传")
                }
                Chart {
                    ForEach(samples.filter { $0.date >= end.addingTimeInterval(-60) }) { sample in
                        AreaMark(x: .value("时间", sample.date), y: .value("KB/s", sample.download / 1000))
                            .foregroundStyle(LinearGradient(colors: [.dashBlue.opacity(0.22), .dashBlue.opacity(0.01)], startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("时间", sample.date), y: .value("KB/s", sample.download / 1000), series: .value("方向", "下载"))
                            .foregroundStyle(Color.dashBlue).lineStyle(StrokeStyle(lineWidth: 2))
                        LineMark(x: .value("时间", sample.date), y: .value("KB/s", sample.upload / 1000), series: .value("方向", "上传"))
                            .foregroundStyle(Color.teal).lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                    }
                    if let selection { RuleMark(x: .value("时间", selection)).foregroundStyle(Color.secondary.opacity(0.4)) }
                }.chartXScale(domain: end.addingTimeInterval(-60)...end).chartYScale(domain: .automatic(includesZero: true))
                    .chartXAxis(.hidden).chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) }
                    .chartXSelection(value: $selection).frame(height: typeSize.isAccessibilitySize ? 120 : 80)
                    .overlay { if samples.isEmpty { Text("等待采样").font(.caption).foregroundStyle(.secondary) } }
                    .accessibilityLabel("最近60秒总流量，蓝色实线下载，绿色虚线上传，单位KB每秒")
                HStack {
                    Text("60s")
                    Spacer()
                    if let selection, let value = samples.min(by: { abs($0.date.timeIntervalSince(selection)) < abs($1.date.timeIntervalSince(selection)) }) {
                        Text("↓ \(DashFormat.bytes(value.download))/s  ↑ \(DashFormat.bytes(value.upload))/s").monospacedDigit()
                    } else { Text("KB/s") }
                }.font(.caption2).foregroundStyle(.tertiary)
                if let nodeRate {
                    if typeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("节点估算").foregroundStyle(.secondary)
                            HStack {
                                Text("↓ " + DashFormat.bytes(nodeRate.download) + "/s")
                                Spacer()
                                Text("↑ " + DashFormat.bytes(nodeRate.upload) + "/s")
                            }.monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
                        }.font(.caption2).accessibilityIdentifier("nodeRate")
                    } else {
                        HStack(spacing: 8) {
                            Text("节点估算").foregroundStyle(.secondary)
                            Spacer()
                            Text("↓ " + DashFormat.bytes(nodeRate.download) + "/s")
                            Text("↑ " + DashFormat.bytes(nodeRate.upload) + "/s")
                        }.font(.caption2).monospacedDigit().accessibilityIdentifier("nodeRate")
                    }
                }
                Divider().opacity(0.6)
                if typeSize.isAccessibilitySize {
                    VStack(spacing: 8) {
                        accessibleTotal("本次下载", value: downloaded.map(DashFormat.bytes) ?? "—")
                        accessibleTotal("本次上传", value: uploaded.map(DashFormat.bytes) ?? "—")
                        accessibleTotal("活跃连接", value: connectionCount.map(String.init) ?? "—")
                    }
                } else {
                    HStack {
                        total("arrow.down.circle", value: downloaded.map(DashFormat.bytes) ?? "—", label: "本次下载")
                        total("arrow.up.circle", value: uploaded.map(DashFormat.bytes) ?? "—", label: "本次上传")
                        total("point.3.connected.trianglepath.dotted", value: connectionCount.map(String.init) ?? "—", label: "活跃连接")
                    }
                }
                Button(action: onEgress) {
                    HStack(spacing: 7) {
                        Image(systemName: "globe").foregroundStyle(Color.dashBlue)
                        Text(address ?? (checking ? "检测中" : "暂未取得出口"))
                            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                        Spacer(minLength: 0)
                        if let countryCode { Text(countryCode).foregroundStyle(.secondary) }
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    }.font(.caption).frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("检测出口 " + (address ?? "未取得"))
                    .accessibilityIdentifier("egressAddress")
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("liveTrafficCard")
    }
    private func rate(_ value: Double?, symbol: String, color: Color, label: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: symbol).foregroundStyle(color)
                Text(label.replacingOccurrences(of: "总", with: "")).foregroundStyle(.secondary)
            }.font(.caption)
            Text(value.map { DashFormat.bytes($0) + "/s" } ?? "—")
                .font(.system(.title2, design: .rounded, weight: .semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.65).contentTransition(.numericText())
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func accessibleTotal(_ title: String, value: String) -> some View {
        HStack { Text(title).foregroundStyle(.secondary); Spacer(); Text(value).monospacedDigit().lineLimit(1) }.font(.caption)
    }
    private func total(_ symbol: String, value: String, label: String) -> some View {
        Label(value, systemImage: symbol).font(.caption).monospacedDigit()
            .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore).accessibilityLabel(label + " " + value)
    }
}
