import SwiftUI
import ClashDashKit

extension Color {
    static let dashBlue = Color(red: 0.21, green: 0.43, blue: 0.95)
    static let dashBackground = Color(uiColor: .systemGroupedBackground)
    static let dashSurface = Color(uiColor: .secondarySystemGroupedBackground)
}

struct DashCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.dashSurface, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
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
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                if busy { ProgressView().tint(.white) }
                if let symbol { Image(systemName: symbol) }
                Text(title).font(.headline)
            }.frame(maxWidth: .infinity).frame(minHeight: 52).foregroundStyle(.white)
                .background(Color.dashBlue, in: Capsule()).contentShape(Capsule())
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
