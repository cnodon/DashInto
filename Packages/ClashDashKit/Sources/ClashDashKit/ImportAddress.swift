import Foundation

public enum ImportAddress {
    private static let nodeSchemes: Set<String> = ["ss", "ssr", "vmess", "vless", "trojan", "trojan-go", "anytls", "hysteria", "hy", "hysteria2", "hy2", "hysteria2+realm", "hy2+realm", "tuic", "wireguard", "wg", "socks", "socks5", "socks5h", "ssocks", "ssocks5", "snell", "ssh", "masque", "tt", "mierus"]
    public static func isNodeLink(_ text: String) -> Bool {
        guard let end = text.range(of: "://") else { return false }
        return nodeSchemes.contains(text[..<end.lowerBound].lowercased())
    }
    public static func subscriptionURL(from input: String) throws -> URL { try unwrap(input, depth: 0) }
    private static func unwrap(_ input: String, depth: Int) throws -> URL {
        guard depth < 4, input.utf8.count <= 16_384 else { throw DashError.message("订阅地址过长或嵌套层数过多。") }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: text), let scheme = components.scheme?.lowercased() else {
            throw DashError.message("请输入 HTTPS 订阅地址，或粘贴客户端的订阅安装链接。")
        }
        if scheme == "https", let url = components.url, let host = url.host, !host.isEmpty, url.user == nil, url.password == nil {
            return url
        }
        let wrappers: Set<String> = ["clash", "clashmeta", "clash-verge", "clashdash", "shadowrocket", "surge", "sing-box", "sub"]
        if wrappers.contains(scheme) {
            if let nested = components.queryItems?.first(where: { ["url", "config", "subscription"].contains($0.name.lowercased()) })?.value {
                return try unwrap(nested, depth: depth + 1)
            }
            if scheme == "sub", let marker = text.range(of: "://") {
                let body = String(text[marker.upperBound...]).components(separatedBy: "#")[0].removingPercentEncoding ?? ""
                var base64 = body.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
                if let data = Data(base64Encoded: base64), let value = String(data: data, encoding: .utf8) { return try unwrap(value, depth: depth + 1) }
            }
            if scheme == "shadowrocket", text.lowercased().hasPrefix("shadowrocket://add/") {
                let value = String(text.dropFirst("shadowrocket://add/".count))
                return try unwrap(value.removingPercentEncoding ?? value, depth: depth + 1)
            }
        }
        throw DashError.message("订阅下载需要 HTTPS 地址。节点链接请使用“粘贴节点或配置”。")
    }
}
