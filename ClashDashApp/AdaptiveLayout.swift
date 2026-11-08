import SwiftUI

/// Uses the available window width, never the physical screen size, so Split View
/// and Stage Manager keep the same destinations and actions in a smaller window.
enum DashLayout {
    static func showsSidebar(width: CGFloat, accessibilitySize: Bool) -> Bool {
        UIDevice.current.userInterfaceIdiom == .pad && width >= 1_000 && !accessibilitySize
    }
}

/// Keeps settings and long lists readable without narrowing their navigation bars.
private struct ReadableList: ViewModifier {
    var maximum: CGFloat
    func body(content: Content) -> some View {
        GeometryReader { geometry in
            content.contentMargins(.horizontal, max(20, (geometry.size.width - maximum) / 2), for: .scrollContent)
        }.background(Color.dashBackground)
    }
}

extension View {
    func readableList(maximum: CGFloat = 760) -> some View {
        modifier(ReadableList(maximum: maximum))
    }
}

/// Shared by the live dashboard and its labelled, read-only design fixture.
/// The compact order remains connection → traffic → subscription → websites.
struct DashboardLayout<Connection: View, Traffic: View, Subscription: View, Websites: View>: View {
    var hasSubscription: Bool
    var connected: Bool
    @ViewBuilder var connection: Connection
    @ViewBuilder var traffic: Traffic
    @ViewBuilder var subscription: Subscription
    @ViewBuilder var websites: Websites
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 740 && hasSubscription && !typeSize.isAccessibilitySize
            ScrollView {
                Group {
                    if wide {
                        HStack(alignment: .top, spacing: 20) {
                            VStack(spacing: 16) {
                                connection
                                if connected { subscription }
                            }.frame(width: min(340, (geometry.size.width - 68) * 0.44))
                            VStack(spacing: 16) {
                                if connected { traffic; websites }
                                else { subscription }
                            }.frame(maxWidth: .infinity)
                        }
                    } else {
                        VStack(spacing: 12) {
                            connection
                            if connected { traffic }
                            subscription
                            if connected { websites }
                        }.frame(maxWidth: 680)
                    }
                }
                .padding(.horizontal, wide ? 24 : 16)
                .padding(.vertical, wide ? 24 : 8)
                .frame(maxWidth: wide ? 1_180 : 712)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
    }
}
