import Foundation

public enum SubscriptionTransport {
    public static func validate(_ url: URL, allowInsecureHTTP: Bool = false) throws {
        guard let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.scheme?.lowercased() == "https" || (allowInsecureHTTP && url.scheme?.lowercased() == "http") else {
            throw DashError.message("请输入 HTTPS 订阅地址。HTTP 地址需要在导入时确认使用未加密连接。")
        }
    }
    public static func redirect(_ request: URLRequest, from source: URL, approvedHTTPOrigin: URL? = nil) -> URLRequest? {
        guard let target = request.url, target.user == nil, target.password == nil, let host = target.host, !host.isEmpty else { return nil }
        let secure = target.scheme?.lowercased() == "https"
        let approved = approvedHTTPOrigin?.scheme?.lowercased() == "http" && source.scheme?.lowercased() == "http" && sameOrigin(target, approvedHTTPOrigin)
        guard secure || approved else { return nil }
        var safe = request
        if !sameOrigin(source, target) {
            safe.setValue(nil, forHTTPHeaderField: "Authorization")
            safe.setValue(nil, forHTTPHeaderField: "Cookie")
        }
        return safe
    }
    private static func sameOrigin(_ left: URL, _ right: URL?) -> Bool {
        guard let right else { return false }
        func port(_ url: URL) -> Int { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
        return left.scheme?.lowercased() == right.scheme?.lowercased() && left.host?.lowercased() == right.host?.lowercased() && port(left) == port(right)
    }
}
