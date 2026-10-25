import Foundation

public enum DashConstants {
    public static var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(version) (\(build))"
    }
    public static let bundleID = Bundle.main.object(forInfoDictionaryKey: "DashAppBundleID") as? String ?? "app.clashdash.ios"
    public static let tunnelBundleID = bundleID + ".tunnel"
    public static let appGroup = Bundle.main.object(forInfoDictionaryKey: "DashAppGroup") as? String ?? "group.app.clashdash.ios"
    public static let protocolVersion = 1
    public static let maximumConfigurationBytes = 5 * 1024 * 1024
}

public enum DashError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

public enum RoutingMode: String, Codable, CaseIterable, Sendable {
    case rule, global
    public var title: String { self == .rule ? "规则模式" : "全局模式" }
}

public struct ProxyNode: Codable, Identifiable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var kind: String
    public init(name: String, kind: String) { self.name = name; self.kind = kind }
}

public struct ProxyGroup: Codable, Identifiable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var kind: String
    public var members: [String]
    public var selected: String?
    public var isSelectable: Bool { kind.lowercased() == "select" || kind.lowercased() == "selector" }
    public init(name: String, kind: String, members: [String], selected: String? = nil) {
        self.name = name; self.kind = kind; self.members = members; self.selected = selected
    }
}

public struct ConfigurationSummary: Codable, Hashable, Sendable {
    public var sourceFormat: String?
    public var providerNodeCount: Int?
    public var nodes: [ProxyNode]
    public var groups: [ProxyGroup]
    public var rules: [String]
    public var providerCount: Int
    public var warnings: [String]
    public var routeCountText: String {
        let count = nodes.count + (providerNodeCount ?? 0)
        if providerCount > 0 && providerNodeCount == nil { return "\(nodes.count) 条内置线路 · 含远程资源" }
        return count == 0 ? "仅直连，不提供代理线路" : "已识别 \(count) 条线路"
    }
    public var isDirectOnly: Bool { nodes.isEmpty && providerCount == 0 }
    public init(nodes: [ProxyNode], groups: [ProxyGroup], rules: [String], providerCount: Int, warnings: [String]) {
        self.nodes = nodes; self.groups = groups; self.rules = rules
        self.providerCount = providerCount; self.warnings = warnings
    }
}

public struct ProfileVersion: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var createdAt: Date
    public var contentHash: String
    public var summary: ConfigurationSummary
    public init(id: String, createdAt: Date, contentHash: String, summary: ConfigurationSummary) {
        self.id = id; self.createdAt = createdAt; self.contentHash = contentHash; self.summary = summary
    }
}

public struct SubscriptionUsage: Codable, Hashable, Sendable {
    public var uploaded: Int64?
    public var downloaded: Int64?
    public var total: Int64?
    public var expiresAt: Date?
    public static func parse(_ header: String?) -> Self? {
        guard let header else { return nil }
        var values: [String: Int64] = [:]
        for field in header.split(separator: ";") {
            let pair = field.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2, let number = Int64(pair[1]), number >= 0 { values[pair[0].lowercased()] = number }
        }
        guard !values.isEmpty else { return nil }
        return Self(uploaded: values["upload"], downloaded: values["download"], total: values["total"],
                    expiresAt: values["expire"].flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil })
    }
}

public struct Profile: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var isSubscription: Bool
    public var sourceHost: String?
    public var updatedAt: Date
    public var selectedVersion: String
    public var lastKnownGood: String?
    public var versions: [ProfileVersion]
    public var usage: SubscriptionUsage?
    public var selections: [String: String]?
    public var preferredMode: RoutingMode?
    public var current: ProfileVersion? { versions.first { $0.id == selectedVersion } }
    public init(id: UUID = UUID(), name: String, isSubscription: Bool, sourceHost: String?,
                version: ProfileVersion, usage: SubscriptionUsage? = nil) {
        self.id = id; self.name = name; self.isSubscription = isSubscription; self.sourceHost = sourceHost
        self.updatedAt = Date(); self.selectedVersion = version.id; self.versions = [version]; self.usage = usage
    }
}

public struct ProfileLibrary: Codable, Sendable {
    public var schemaVersion = 1
    public var profiles: [Profile] = []
    public var selectedProfileID: UUID?
    public var activeProfile: Profile? { profiles.first { $0.id == selectedProfileID } }
    public init() {}
}

public struct TrafficSample: Identifiable, Sendable {
    public var id = UUID()
    public var date = Date()
    public var upload: Double
    public var download: Double
    public init(upload: Double, download: Double) { self.upload = upload; self.download = download }
}

public struct TunnelRequest: Codable, Sendable {
    public var protocolVersion = DashConstants.protocolVersion
    public var requestID = UUID()
    public var sessionID: String?
    public var method: String
    public var parameters: [String: String]
    public init(method: String, parameters: [String: String] = [:], sessionID: String? = nil) {
        self.method = method; self.parameters = parameters; self.sessionID = sessionID
    }
}

public struct TunnelReply: Codable, Sendable {
    public var protocolVersion = DashConstants.protocolVersion
    public var requestID: UUID
    public var sessionID: String
    public var generation: String?
    public var payload: Data?
    public var error: String?
    public init(requestID: UUID, sessionID: String, generation: String?, payload: Data? = nil, error: String? = nil) {
        self.requestID = requestID; self.sessionID = sessionID; self.generation = generation
        self.payload = payload; self.error = error
    }
}

public struct RuntimeInfo: Codable, Sendable {
    public var sessionID: String
    public var generation: String
    public var startedAt: Date
    public var coreVersion: String
    public var mode: String
    public var memoryBytes: UInt64
    public var trafficJSON: String
    public var statusJSON: String
    public init(sessionID: String, generation: String, startedAt: Date, coreVersion: String, mode: String,
                memoryBytes: UInt64, trafficJSON: String, statusJSON: String) {
        self.sessionID = sessionID; self.generation = generation; self.startedAt = startedAt
        self.coreVersion = coreVersion; self.mode = mode; self.memoryBytes = memoryBytes
        self.trafficJSON = trafficJSON; self.statusJSON = statusJSON
    }
}

public enum DashFormat {
    public static func bytes(_ value: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var number = max(value, 0); var index = 0
        while number >= 1000 && index < units.count - 1 { number /= 1000; index += 1 }
        return String(format: index == 0 ? "%.0f %@" : "%.2f %@", number, units[index])
    }
}
