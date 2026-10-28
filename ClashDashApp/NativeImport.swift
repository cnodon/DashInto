import Foundation
import CryptoKit
import Clash
import ClashDashKit

/// Uses the exact importer shipped with our pinned runtime. No service or VPN is started here.
enum NativeConfigImporter {
    static func prepare(_ input: String) throws -> PreparedConfiguration {
        guard input.utf8.count <= DashConstants.maximumConfigurationBytes else { throw DashError.message("导入内容超过 5 MB。") }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw DashError.message("请粘贴订阅内容、节点链接或配置。") }
        // Run our bounded YAML validation before passing full configurations to the native importer.
        let fullConfiguration = hasConfigurationPolicy(text)
        var configuration = fullConfiguration ? try ConfigurationParser.prepare(text) : nil
        var error: NSError?
        if let summaryBox = ClashReadProxyPayloadSummaryForIOS(Data(text.utf8), "subscriptionBody", &error),
           let summary = try? JSONSerialization.jsonObject(with: Data(summaryBox.value.utf8)) as? [String: Any],
           let count = summary["count"] as? Int, count > 2048 { throw DashError.message("节点数量超过当前支持范围（2048 个）。") }
        error = nil
        guard let box = ClashInspectProxyPayloadForIOS(Data(text.utf8), "subscriptionBody", &error), error == nil,
              let document = try JSONSerialization.jsonObject(with: Data(box.value.utf8)) as? [String: Any] else {
            throw DashError.message("无法识别这份内容。可导入 Clash/mihomo 配置、常见节点分享链接、Base64 节点订阅和支持的客户端节点配置。")
        }
        let nodes = document["proxies"] as? [[String: Any]] ?? []
        let skipped = document["skipped"] as? [[String: Any]] ?? []
        let notices = document["notHonoured"] as? [[String: Any]] ?? []
        let format = document["format"] as? String ?? "unknown"
        guard nodes.count <= 2048 else { throw DashError.message("节点数量超过当前支持范围（2048 个）。") }
        if fullConfiguration {
            guard skipped.isEmpty else {
                throw DashError.message("完整配置中有 \(skipped.count) 个节点无法由当前核心解析。请使用服务商的 Clash/mihomo 格式，或先修正这些节点。")
            }
        } else {
            guard !nodes.isEmpty else {
                let types = Set(skipped.compactMap { $0["scheme"] as? String }).sorted().joined(separator: "、")
                throw DashError.message(types.isEmpty ? "没有找到可导入的节点。" : "没有找到可用节点。当前内容涉及的类型：\(types)。请使用 Clash/mihomo 格式或常见节点分享链接。")
            }
            let names = nodes.compactMap { $0["name"] as? String }
            var group = "节点选择"
            while names.contains(group) { group += " ·" }
            let object: [String: Any] = [
                "proxies": nodes,
                "proxy-groups": [["name": group, "type": "select", "proxies": names]],
                "rules": ["MATCH,\(group)"]
            ]
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            configuration = try ConfigurationParser.prepare(String(decoding: data, as: UTF8.self))
            configuration?.summary.warnings.append("这份内容按节点集合导入，已生成手动“节点选择”策略。原客户端的 DNS、路由、脚本和其他设置不会迁移；默认流量经过所选节点。")
        }
        guard var prepared = configuration else { throw DashError.message("配置转换失败。") }
        prepared.original = input
        prepared.hash = SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
        prepared.summary.sourceFormat = formatTitle(format)
        if !skipped.isEmpty {
            let types = Set(skipped.compactMap { $0["scheme"] as? String }.filter { !$0.isEmpty }).sorted().joined(separator: "、")
            prepared.summary.warnings.append("已跳过 \(skipped.count) 条无法解析或核心不支持的节点记录\(types.isEmpty ? "" : "（\(types)）")。保存前请核对节点数量。")
        }
        if !notices.isEmpty {
            prepared.summary.warnings.append("有 \(notices.count) 项来源字段未完整映射。请核对导入结果；转换不代表原客户端所有设置等价迁移。")
        }
        return prepared
    }

    static func formatTitle(_ key: String) -> String {
        ["mihomo-yaml": "Clash / mihomo YAML", "mihomo-json": "Clash / mihomo JSON",
         "share-links": "节点分享链接", "base64-share-links": "Base64 节点订阅",
         "shadowrocket-json": "Shadowrocket 节点配置", "sing-box-json": "sing-box 节点配置",
         "v2ray-json": "V2Ray 节点配置", "surge": "Surge 代理节点", "wireguard-ini": "WireGuard 配置",
         "sip008-json": "SIP008 Shadowsocks", "ssd": "SSD 节点订阅", "proxy-json": "JSON 节点集合",
         "mixed-proxy-json": "混合 JSON 节点集合"][key] ?? key
    }

    private static func hasConfigurationPolicy(_ text: String) -> Bool {
        // A plain proxies-only document is a node collection, not a complete routing policy.
        if let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
            return ["proxy-groups", "proxy-providers", "rules"].contains { object[$0] != nil }
        }
        return text.range(of: "(?m)^(proxy-groups|proxy-providers|rules):", options: .regularExpression) != nil
    }

    static var supportedSchemes: [String] {
        guard let box = ClashProxyImportCapabilitiesForIOS(),
              let document = (try? JSONSerialization.jsonObject(with: Data(box.value.utf8))) as? [String: Any] else { return [] }
        let schemes = document["schemes"] as? [[String: Any]] ?? []
        return schemes.filter { $0["status"] as? String == "supported" }.compactMap { $0["scheme"] as? String }.sorted()
    }
}
