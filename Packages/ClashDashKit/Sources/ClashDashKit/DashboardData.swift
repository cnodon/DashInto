import Foundation
import Network

public enum ProxyNodeSortOrder: String, CaseIterable, Sendable {
    case configuration, latency, name
    public var title: String {
        switch self { case .configuration: "默认顺序"; case .latency: "延迟从低到高"; case .name: "名称排序" }
    }
    public var shortTitle: String {
        switch self { case .configuration: "默认"; case .latency: "延迟"; case .name: "名称" }
    }

    /// Equal latency and unknown results keep their original subscription order.
    public func sorted(_ names: [String], delays: [String: Int]) -> [String] {
        if self == .name {
            return names.enumerated().sorted {
                let comparison = $0.element.localizedStandardCompare($1.element)
                return comparison == .orderedSame ? $0.offset < $1.offset : comparison == .orderedAscending
            }.map(\.element)
        }
        guard self == .latency else { return names }
        return names.enumerated().sorted { lhs, rhs in
            let left = delays[lhs.element].flatMap { $0 >= 0 ? $0 : nil }
            let right = delays[rhs.element].flatMap { $0 >= 0 ? $0 : nil }
            switch (left, right) {
            case let (a?, b?) where a != b: return a < b
            case (_?, nil): return true
            case (nil, _?): return false
            default: return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }
}

public struct ProxyRouteChoice: Equatable, Sendable {
    public let group: String
    public let member: String
    public init(group: String, member: String) { self.group = group; self.member = member }
}

public enum ProxySelection {
    /// Only manual selector chains can promise the requested leaf. Automatic groups are opaque.
    public static func manualPath(to node: String, from root: String, groups: [ProxyGroup]) -> [ProxyRouteChoice]? {
        let catalog = Dictionary(groups.map { ($0.name, $0) }, uniquingKeysWith: { _, new in new })
        func visit(_ name: String, visited: Set<String>) -> [ProxyRouteChoice]? {
            guard !visited.contains(name), let group = catalog[name], group.isSelectable else { return nil }
            if group.members.contains(node) { return [.init(group: name, member: node)] }
            let seen = visited.union([name])
            // Prefer the current manual chain before other branches.
            let members = group.members.sorted { ($0 == group.selected ? 0 : 1) < ($1 == group.selected ? 0 : 1) }
            for member in members {
                if let tail = visit(member, visited: seen) { return [.init(group: name, member: member)] + tail }
            }
            return nil
        }
        return visit(root, visited: [])
    }

    /// Expand nested groups into real nodes once; routing actions never become test targets.
    public static func delayTargets(_ requested: [String], nodes: [ProxyNode], groups: [ProxyGroup], runtimeKinds: [String: String]) -> [String] {
        let eligible = Set(testableNames(nodes: nodes, groups: groups, runtimeKinds: runtimeKinds))
        let catalog = Dictionary(groups.map { ($0.name, $0.members) }, uniquingKeysWith: { _, new in new })
        var visited = Set<String>(), output: [String] = []
        func append(_ name: String) {
            guard visited.insert(name).inserted else { return }
            if eligible.contains(name) { output.append(name) }
            else { for member in catalog[name] ?? [] { append(member) } }
        }
        for name in requested { append(name) }
        return output
    }
    public static func testableNames(nodes: [ProxyNode], groups: [ProxyGroup], runtimeKinds: [String: String]) -> [String] {
        let builtins: Set<String> = ["DIRECT", "REJECT", "REJECT-DROP", "PASS", "PASS-RULE", "COMPATIBLE", "GLOBAL"]
        let localKinds: Set<String> = ["direct", "reject", "rejectdrop", "pass", "passrule", "compatible", "dns", "dnsout"]
        let groupNames = Set(groups.map(\.name))
        let configuredKinds = Dictionary(nodes.map { ($0.name, $0.kind) }, uniquingKeysWith: { _, new in new })
        var seen = Set<String>()
        return (nodes.map(\.name) + runtimeKinds.keys.sorted()).filter { name in
            let kind = (runtimeKinds[name] ?? configuredKinds[name] ?? "").lowercased().filter { $0.isLetter || $0.isNumber }
            return !builtins.contains(name) && !localKinds.contains(kind) && !groupNames.contains(name) && seen.insert(name).inserted
        }
    }
    /// Manual groups have a deterministic first-member default. Automatic groups stay unresolved offline.
    public static func defaultSelections(groups: [ProxyGroup], saved: [String: String]) -> [String: String] {
        var result = saved
        for group in groups where group.isSelectable {
            if let selected = result[group.name], group.members.contains(selected) || group.usesProviders == true { continue }
            result[group.name] = group.members.first
        }
        return result
    }
    public static func preview(group: String, groups: [ProxyGroup]) -> String? {
        var name = group, visited = Set<String>()
        while let current = groups.first(where: { $0.name == name }) {
            guard visited.insert(name).inserted else { return nil }
            guard current.isSelectable else { return current.name + " · 自动选择" }
            guard let selected = current.selected ?? current.members.first, current.members.contains(selected) || current.usesProviders == true else {
                return current.name + " · 连接后读取节点"
            }
            name = selected
        }
        return name
    }
    public static func configurationGroups(summary: ConfigurationSummary) -> [ProxyGroup] {
        // Older saved summaries did not record provider membership. Keep their saved selections
        // until the running core confirms them, instead of deleting provider-only node choices.
        summary.groups.map { group in
            var value = group
            if value.usesProviders == nil { value.usesProviders = summary.providerCount > 0 }
            return value
        }
    }
    public static func globalGroup(summary: ConfigurationSummary) -> ProxyGroup {
        let members = summary.nodes.map(\.name) + summary.groups.map(\.name) + ["DIRECT"]
        return ProxyGroup(name: "GLOBAL", kind: "select", members: members, usesProviders: summary.providerCount > 0)
    }
    public static func resolvedLeaf(group: String, groups: [ProxyGroup]) -> String? {
        var name = group, visited = Set<String>()
        while let current = groups.first(where: { $0.name == name }) {
            guard visited.insert(name).inserted, let selected = current.selected, current.members.contains(selected) else { return nil }
            name = selected
        }
        return name
    }
}

public struct SubscriptionBalance: Equatable, Sendable {
    public let remaining: Double
    public let total: Double
    public var fraction: Double { remaining / total }
    public init?(usage: SubscriptionUsage?) {
        guard let usage, let total = usage.total, total > 0,
              let upload = usage.uploaded, let download = usage.downloaded else { return nil }
        self.total = Double(total)
        remaining = max(0, Double(total) - Double(upload) - Double(download))
    }
}

public struct NodeTrafficRate: Sendable {
    public var upload: Double = 0
    public var download: Double = 0
    public init() {}
}

/// Keeps only counters and chains, never destinations or browsing history.
public struct ConnectionTrafficTracker: Sendable {
    private struct Counter: Sendable { var upload: Double; var download: Double }
    private var counters: [String: Counter] = [:]
    private var sampledAt: Date?
    public private(set) var count = 0
    public private(set) var rates: [String: NodeTrafficRate] = [:]
    public var hasBaseline: Bool { sampledAt != nil }
    public init() {}
    public mutating func update(_ data: Data, at date: Date = Date()) throws {
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let rows = root["connections"] as? [[String: Any]] else { throw DashError.message("连接统计暂不可用。") }
        var next: [String: Counter] = [:], result: [String: NodeTrafficRate] = [:]
        let interval = sampledAt.map { date.timeIntervalSince($0) }
        for row in rows {
            guard let id = row["id"] as? String else { continue }
            let value = Counter(upload: (row["upload"] as? NSNumber)?.doubleValue ?? 0,
                                download: (row["download"] as? NSNumber)?.doubleValue ?? 0)
            next[id] = value
            guard let previous = counters[id], let interval, interval > 0, interval < 10 else { continue }
            let up = max(0, value.upload - previous.upload) / interval
            let down = max(0, value.download - previous.download) / interval
            for name in Set(row["chains"] as? [String] ?? []) {
                var rate = result[name] ?? NodeTrafficRate()
                rate.upload += up; rate.download += down; result[name] = rate
            }
        }
        count = rows.count; rates = result; counters = next; sampledAt = date
    }
}

public enum WebsiteProbeState: String, Sendable { case available, challenge, restricted, timeout, failed }
public struct WebsiteProbeResult: Identifiable, Sendable {
    public let id: String
    public let host: String
    public let state: WebsiteProbeState
    public let statusCode: Int?
    public let milliseconds: Int?
    public let date: Date
    public init(id: String, host: String, state: WebsiteProbeState, statusCode: Int? = nil, milliseconds: Int? = nil, date: Date = Date()) {
        self.id = id; self.host = host; self.state = state; self.statusCode = statusCode; self.milliseconds = milliseconds; self.date = date
    }
    public var label: String {
        switch state {
        case .available: return milliseconds.map { "\($0) ms" } ?? "可达"
        case .challenge: return "需验证"
        case .restricted: return statusCode == 429 ? "限流" : "受限"
        case .timeout: return "超时"
        case .failed: return "未连通"
        }
    }
    public static func classify(code: Int, body: String) -> WebsiteProbeState {
        let text = body.lowercased()
        if text.contains("cf-chl-") || text.contains("<title>just a moment") || text.contains("challenge-platform") { return .challenge }
        if (200..<300).contains(code) { return .available }
        return .restricted
    }
}

public struct EgressResult: Sendable {
    public let address: String?
    public let countryCode: String?
    public let date: Date
    public static func parse(_ text: String) -> Self {
        let fields = text.split(separator: "\n").reduce(into: [String: String]()) { result, line in
            let pair = line.split(separator: "=", maxSplits: 1)
            if pair.count == 2 { result[String(pair[0])] = String(pair[1]).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        // An IP literal only; never surface arbitrary remote response text.
        let candidate = fields["ip"] ?? ""
        let valid = IPv4Address(candidate) != nil || IPv6Address(candidate) != nil
        let country = fields["loc"].flatMap { $0.count == 2 && $0.allSatisfy(\.isLetter) ? $0.uppercased() : nil }
        return Self(address: valid ? candidate : nil, countryCode: country, date: Date())
    }
}

public enum DashboardNetworkProbe {
    public static let targets = [("Google", "https://www.google.com/generate_204"),
                                 ("YouTube", "https://www.youtube.com/"),
                                 ("OpenAI", "https://chatgpt.com/"),
                                 ("Claude", "https://claude.ai/")]
    public static func website(name: String, address: String) async -> WebsiteProbeResult {
        let start = ProcessInfo.processInfo.systemUptime
        let host = URL(string: address)?.host ?? name
        do {
            let response = try await read(address)
            return .init(id: name, host: host, state: WebsiteProbeResult.classify(code: response.code, body: response.text), statusCode: response.code,
                         milliseconds: Int((ProcessInfo.processInfo.systemUptime - start) * 1000), date: Date())
        } catch {
            return .init(id: name, host: host, state: (error as? URLError)?.code == .timedOut ? .timeout : .failed,
                         statusCode: nil, milliseconds: nil, date: Date())
        }
    }
    public static func egress() async -> EgressResult {
        guard let response = try? await read("https://www.cloudflare.com/cdn-cgi/trace"), response.code == 200 else {
            return EgressResult(address: nil, countryCode: nil, date: Date())
        }
        return EgressResult.parse(response.text)
    }
    private static func read(_ address: String) async throws -> (code: Int, text: String) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10; configuration.timeoutIntervalForResource = 12
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: address)!)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let (stream, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.url?.scheme == "https" else { throw URLError(.badServerResponse) }
        var data = Data()
        for try await byte in stream {
            try Task.checkCancellation(); data.append(byte)
            if data.count >= 8192 { break }
        }
        return (http.statusCode, String(decoding: data, as: UTF8.self))
    }
}
