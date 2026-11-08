import Foundation

public enum LatencyTestEndpoint: String, CaseIterable, Sendable {
    case cloudflare, google
    public var title: String { self == .cloudflare ? "Cloudflare" : "Google" }
    public var url: String {
        self == .cloudflare ? "https://cp.cloudflare.com/generate_204" : "https://www.google.com/generate_204"
    }
}
