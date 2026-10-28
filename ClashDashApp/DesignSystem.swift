import SwiftUI
import ClashDashKit

extension Color {
    static let dashBlue = Color(red: 0.25, green: 0.36, blue: 0.94)
    static let dashBackground = Color(uiColor: .systemGroupedBackground)
    static let dashSurface = Color(uiColor: .secondarySystemGroupedBackground)
}

struct DashCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.dashSurface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Color.primary.opacity(0.035), lineWidth: 1).allowsHitTesting(false).accessibilityHidden(true) }
    }
}

struct DashPill: View {
    var title: String
    var body: some View {
        Text(title).font(.caption.weight(.medium)).foregroundStyle(Color.dashBlue)
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(Color.dashBlue.opacity(0.1), in: Capsule())
    }
}

struct DashPrimaryButton: View {
    var title: String
    var symbol: String? = nil
    var busy = false
    var tint: Color = .dashBlue
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                if busy { ProgressView().tint(.white) }
                if let symbol { Image(systemName: symbol) }
                Text(title).font(.headline)
            }.frame(maxWidth: .infinity).frame(minHeight: 52).foregroundStyle(.white)
                .background(LinearGradient(colors: [tint, tint.opacity(0.85)], startPoint: .topLeading, endPoint: .bottomTrailing), in: Capsule())
                .shadow(color: tint.opacity(0.15), radius: 8, y: 4).contentShape(Capsule())
        }.buttonStyle(DashPressStyle())
    }
}

enum DashMotion {
    static let press = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.14)
    static let state = Animation.easeOut(duration: 0.2)
}

private struct DashPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .opacity(!enabled ? 0.55 : configuration.isPressed ? 0.88 : 1)
            .animation(DashMotion.press, value: configuration.isPressed)
    }
}

struct SectionEyebrow: View {
    var title: String
    var body: some View { Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.secondary).padding(.horizontal, 4) }
}

struct EmptyCard: View {
    var symbol: String
    var title: String
    var message: String
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 34, weight: .light)).foregroundStyle(Color.dashBlue)
                .frame(width: 72, height: 72).background(Color.dashBlue.opacity(0.08), in: RoundedRectangle(cornerRadius: 23))
            Text(title).font(.title3.weight(.semibold))
            Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).padding(.vertical, 28)
    }
}

struct MetricView: View {
    var title: String
    var value: Double
    var symbol: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(DashFormat.bytes(value) + "/s").font(.title2.weight(.medium)).monospacedDigit().minimumScaleFactor(0.6).lineLimit(1)
                .accessibilityLabel("\(title)，每秒\(DashFormat.bytes(value))")
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Sparkline: View {
    var values: [Double]
    var body: some View {
        GeometryReader { geometry in
            let maximum = max(values.max() ?? 1, 1)
            Path { path in
                guard values.count > 1 else { return }
                for (index, value) in values.enumerated() {
                    let point = CGPoint(x: geometry.size.width * Double(index) / Double(values.count - 1),
                                        y: geometry.size.height * (1 - value / maximum) * 0.85 + 3)
                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
            }.stroke(Color.dashBlue, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
        }.frame(height: 42).accessibilityHidden(true)
    }
}

struct DashGlyph: View {
    var symbol: String
    var color: Color = .dashBlue
    var animated = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var phase
    var body: some View {
        Image(systemName: symbol).font(.system(size: 22, weight: .medium))
            .symbolEffect(.pulse, options: .repeating, isActive: animated && !reduceMotion && phase == .active)
            .foregroundStyle(color).frame(width: 48, height: 48)
            .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct DashQuotaRing: View {
    var fraction: Double
    var size: CGFloat = 56
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var value: Double { min(max(fraction, 0), 1) }
    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.1), lineWidth: 5)
            Circle().trim(from: 0, to: value)
                .stroke(value < 0.1 ? Color.orange : Color.dashBlue, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(value, format: .percent.precision(.fractionLength(0)))
                .font(.system(.caption, design: .rounded, weight: .semibold)).monospacedDigit()
                .contentTransition(.numericText())
        }.frame(width: size, height: size)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.4), value: value)
            .accessibilityElement(children: .ignore).accessibilityLabel("剩余额度 \(Int(value * 100))%")
    }
}

struct DelayIndicator: View {
    var milliseconds: Int?
    private var color: Color { guard let ms = milliseconds, ms >= 0 else { return .secondary }; return ms < 150 ? .green : ms < 350 ? .orange : .red }
    private var bars: Int { guard let ms = milliseconds, ms >= 0 else { return 0 }; return ms < 80 ? 4 : ms < 150 ? 3 : ms < 350 ? 2 : 1 }
    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<4) { index in
                    Capsule().fill(index < bars ? color : Color.secondary.opacity(0.15))
                        .frame(width: 3, height: CGFloat(5 + index * 3))
                }
            }.frame(height: 14)
            Text(milliseconds.map { $0 >= 0 ? "\($0) ms" : $0 == -1 ? "超时" : "失败" } ?? "—")
                .font(.system(.caption, design: .rounded, weight: .medium)).monospacedDigit().foregroundStyle(color)
        }.accessibilityElement(children: .ignore)
            .accessibilityLabel(milliseconds.map { $0 >= 0 ? "响应延迟 \($0) 毫秒" : $0 == -1 ? "测试超时" : "测试失败" } ?? "尚未测速")
    }
}
