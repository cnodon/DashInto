import Foundation
import CryptoKit
import Yams

public struct PreparedConfiguration: Sendable {
    public var original: String
    public var runtime: String
    public var summary: ConfigurationSummary
    public var hash: String
    public var resourceRequests: [ResourceRequest] = []
    public var resources: [StagedResource] = []
    public var geodata: [PreparedGeodata] = []
    public init(original: String, runtime: String, summary: ConfigurationSummary, hash: String) {
        self.original = original; self.runtime = runtime; self.summary = summary; self.hash = hash
    }
}

public struct ResourceRequest: Sendable {
    public var url: URL
    public var relativePath: String
    public var headers: [String: String] = [:]
    public var kind: String = "proxy"
    public var behavior: String = "classical"
    public var format: String = "yaml"
}
public struct StagedResource: Sendable {
    public var relativePath: String
    public var data: Data
    public init(relativePath: String, data: Data) { self.relativePath = relativePath; self.data = data }
}
public struct ResourceDescriptor: Codable, Sendable {
    public var relativePath: String
    public var blobName: String
    public var hash: String
}

public struct PreparedGeodata: Sendable {
    public var relativePath: String
    public var sourceFileURL: URL
    public var hash: String
    public init(relativePath: String, sourceFileURL: URL, hash: String) { self.relativePath = relativePath; self.sourceFileURL = sourceFileURL; self.hash = hash }
}
public struct GeodataDescriptor: Codable, Sendable {
    public var relativePath: String
    public var blobName: String
    public var hash: String
}
public enum FileDigest {
    public static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty { digest.update(data: data) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public enum ConfigurationParser {
    public static func prepare(_ text: String) throws -> PreparedConfiguration {
        guard text.utf8.count <= DashConstants.maximumConfigurationBytes else { throw DashError.message("配置超过 5 MB，无法导入。") }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DashError.message("配置内容为空。") }
        // Reject pathological nesting before the recursive YAML composer is entered.
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard line.prefix(while: { $0 == " " }).count <= 128 else { throw DashError.message("配置嵌套过深。") }
        }
        try checkFlowDepth(text)
        let document: Node
        do {
            guard let root = try Yams.compose(yaml: text) else { throw DashError.message("配置内容为空。") }
            document = root
        } catch let error as DashError { throw error }
        catch { throw DashError.message("YAML 格式无法解析，请检查缩进、引号和冒号。") }
        var visited = 0
        try validate(document, depth: 0, visited: &visited)
        guard var object = document.any as? [String: Any] else {
            throw DashError.message("需要完整的 Clash / mihomo YAML 配置。请在订阅服务中选择 Clash 格式。")
        }
        if object["script"] != nil { throw DashError.message("此配置包含桌面脚本。请先导出脚本处理后的标准 Clash 配置。") }
        let proxies = object["proxies"] as? [[String: Any]] ?? []
        let groupObjects = object["proxy-groups"] as? [[String: Any]] ?? []
        let providers = object["proxy-providers"] as? [String: Any] ?? [:]
        let ruleProviders = object["rule-providers"] as? [String: Any] ?? [:]
        let originalRules = object["rules"] as? [String] ?? []
        let processPattern = try NSRegularExpression(pattern: "(^|[,(])\\s*(PROCESS-[A-Z-]+|UID)\\s*,", options: .caseInsensitive)
        let processRules = originalRules.filter { rule in
            processPattern.firstMatch(in: rule, range: NSRange(rule.startIndex..., in: rule)) != nil
        }
        let omittedRules = Set(processRules)
        let rules = originalRules.filter { !omittedRules.contains($0) }
        object["rules"] = rules
        guard !proxies.isEmpty || !providers.isEmpty || !rules.isEmpty else {
            throw DashError.message("没有找到节点或分流规则。请使用 Clash / mihomo 订阅地址，而不是管理面板网址或节点列表。")
        }
        guard providers.count + ruleProviders.count <= 16 else { throw DashError.message("远程资源数量超过首版支持范围（16 项）。") }
        let nodes = try proxies.map { node -> ProxyNode in
            guard let name = node["name"] as? String, !name.isEmpty, let kind = node["type"] as? String else {
                throw DashError.message("节点需要有效的 name 和 type 字段。")
            }
            return ProxyNode(name: name, kind: kind)
        }
        let groups = try groupObjects.map { group -> ProxyGroup in
            guard let name = group["name"] as? String, !name.isEmpty, let kind = group["type"] as? String else {
                throw DashError.message("策略组需要有效的 name 和 type 字段。")
            }
            return ProxyGroup(name: name, kind: kind, members: group["proxies"] as? [String] ?? [])
        }
        let names = nodes.map(\.name) + groups.map(\.name)
        guard Set(names).count == names.count else { throw DashError.message("存在重名节点或策略组，请使用唯一名称。") }
        let reserved: Set<String> = ["DIRECT", "REJECT", "REJECT-DROP", "PASS", "COMPATIBLE", "GLOBAL"]
        for group in groups {
            for member in group.members where !names.contains(member) && !reserved.contains(member) {
                throw DashError.message("策略组“\(group.name)”引用了不存在的节点“\(member)”。")
            }
        }
        var checking = Set<String>(); var checked = Set<String>()
        func visit(_ name: String) throws {
            if checked.contains(name) { return }
            guard !checking.contains(name) else { throw DashError.message("代理组存在循环引用：\(name)。") }
            checking.insert(name)
            for member in groups.first(where: { $0.name == name })?.members ?? [] where groups.contains(where: { $0.name == member }) {
                try visit(member)
            }
            checking.remove(name); checked.insert(name)
        }
        for group in groups { try visit(group.name) }
        var warnings = ["TUN、监听端口和外部控制器由 iOS 运行环境管理。"]
        if !processRules.isEmpty { warnings.append("已跳过 \(processRules.count) 条 iOS 无法执行的 PROCESS / UID 进程规则；其余规则保持原有顺序。原始配置仍完整保留。") }
        if !providers.isEmpty || !ruleProviders.isEmpty { warnings.append("远程节点和规则资源会随订阅一起准备。任何一项读取失败都会保留旧版本。") }
        if rules.contains(where: { $0.contains("GEOIP,") || $0.contains("GEOSITE,") }) {
            warnings.append("配置使用地理数据库；首次连接可能需要下载对应资源。")
        }
        // No desktop listeners, external controllers or arbitrary filesystem paths.
        for key in ["external-controller", "external-controller-tls", "external-controller-unix", "external-ui", "external-ui-url", "secret", "listeners", "tunnels", "interface-name", "routing-mark", "iptables", "authentication"] {
            object.removeValue(forKey: key)
        }
        for key in ["port", "socks-port", "mixed-port", "redir-port", "tproxy-port"] { object[key] = 0 }
        object["allow-lan"] = false; object["bind-address"] = "127.0.0.1"; object["log-level"] = "warning"
        object["find-process-mode"] = "off"
        object["mode"] = "rule"
        var tun = object["tun"] as? [String: Any] ?? [:]
        tun["enable"] = true; tun["stack"] = "gvisor"; tun["auto-route"] = true
        tun["auto-detect-interface"] = true; tun["mtu"] = 1400; tun["dns-hijack"] = ["any:53"]
        tun.removeValue(forKey: "auto-redirect")
        for key in ["device", "file-descriptor", "include-uid", "exclude-uid", "include-package", "exclude-package"] { tun.removeValue(forKey: key) }
        object["tun"] = tun
        var dns = object["dns"] as? [String: Any] ?? [:]
        dns["enable"] = true; dns["listen"] = ""
        if dns["enhanced-mode"] == nil { dns["enhanced-mode"] = "fake-ip" }
        if dns["fake-ip-range"] == nil { dns["fake-ip-range"] = "198.18.0.1/16" }
        if dns["nameserver"] == nil { dns["nameserver"] = ["https://dns.alidns.com/dns-query", "https://cloudflare-dns.com/dns-query"]
            warnings.append("原配置未提供 DNS 上游，将使用阿里 DNS 和 Cloudflare 的 HTTPS DNS。") }
        if dns["default-nameserver"] == nil { dns["default-nameserver"] = ["223.5.5.5", "1.1.1.1"] }
        object["dns"] = dns
        var resourceRequests: [ResourceRequest] = []
        for kind in ["proxy-providers", "rule-providers"] {
            if var collection = object[kind] as? [String: Any] {
                for (name, raw) in collection {
                    guard var provider = raw as? [String: Any] else { throw DashError.message("远程资源格式不正确。") }
                    if let urlText = provider["url"] as? String {
                        guard let url = URL(string: urlText), url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil else {
                            throw DashError.message("远程资源需要有效的 HTTPS 地址。")
                        }
                        let key = SHA256.hash(data: Data((kind + name).utf8)).map { String(format: "%02x", $0) }.joined()
                        provider["path"] = "providers/\(key).cache"
                        var headers: [String: String] = [:]
                        if let configured = provider["header"] as? [String: Any] {
                            for (field, value) in configured {
                                let text = (value as? String) ?? (value as? [String])?.joined(separator: ", ")
                                guard let text, !field.contains(where: { $0.isNewline }), !text.contains(where: { $0.isNewline }),
                                      field.utf8.count <= 256, text.utf8.count <= 8192 else { throw DashError.message("远程资源的请求头格式无效。") }
                                if !["host", "content-length", "connection"].contains(field.lowercased()) { headers[field] = text }
                            }
                        }
                        resourceRequests.append(ResourceRequest(url: url, relativePath: "providers/\(key).cache", headers: headers,
                            kind: kind == "proxy-providers" ? "proxy" : "rule", behavior: provider["behavior"] as? String ?? "classical", format: provider["format"] as? String ?? "yaml"))
                        provider["type"] = "file"
                        for field in ["url", "interval", "proxy", "header"] { provider.removeValue(forKey: field) }
                    } else if provider["type"] as? String == "inline" {
                        provider.removeValue(forKey: "path")
                    } else {
                        throw DashError.message("资源缺少 HTTPS 地址。本地文件 provider 无法从 Mac 目录迁移，请改用 HTTPS 资源或内联规则。")
                    }
                    collection[name] = provider
                }
                object[kind] = collection
            }
        }
        let runtime = try Yams.dump(object: object, sortKeys: true)
        let hash = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        var prepared = PreparedConfiguration(original: text, runtime: runtime,
            summary: .init(nodes: nodes, groups: groups, rules: rules, providerCount: providers.count + ruleProviders.count, warnings: warnings), hash: hash)
        prepared.resourceRequests = resourceRequests
        return prepared
    }

    private static func validate(_ node: Node, depth: Int, visited: inout Int) throws {
        visited += 1
        guard depth <= 64, visited <= 150_000 else { throw DashError.message("配置结构过大或别名展开超过安全限制。") }
        switch node {
        case .mapping(let mapping):
            var keys = Set<String>()
            for pair in mapping {
                guard let key = pair.key.string, keys.insert(key).inserted else { throw DashError.message("YAML 包含重复键或非文本键。") }
                try validate(pair.value, depth: depth + 1, visited: &visited)
            }
        case .sequence(let sequence): for value in sequence { try validate(value, depth: depth + 1, visited: &visited) }
        case .scalar: break
        case .alias: throw DashError.message("无法解析 YAML 别名。")
        }
    }

    private static func checkFlowDepth(_ text: String) throws {
        let bytes = Array(text.utf8)
        var quote: UInt8?; var escaped = false; var comment = false; var depth = 0; var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if comment { if byte == 10 { comment = false }; index += 1; continue }
            if let current = quote {
                if current == 34 {
                    if escaped { escaped = false }
                    else if byte == 92 { escaped = true }
                    else if byte == 34 { quote = nil }
                } else if byte == 39 {
                    if index + 1 < bytes.count && bytes[index + 1] == 39 { index += 1 }
                    else { quote = nil }
                }
            } else if byte == 34 || byte == 39 { quote = byte }
            else if byte == 35 && (index == 0 || [UInt8(9), 10, 13, 32].contains(bytes[index - 1])) { comment = true }
            else if byte == 91 || byte == 123 {
                depth += 1
                guard depth <= 64 else { throw DashError.message("配置流式嵌套超过安全限制。") }
            } else if byte == 93 || byte == 125 { depth = max(0, depth - 1) }
            index += 1
        }
    }
}
