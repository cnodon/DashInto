import Foundation
import Network

public enum ProxySelection {
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
