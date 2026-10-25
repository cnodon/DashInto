import Foundation

public struct SubscriptionDownload: Sendable {
    public var text: String
    public var usage: SubscriptionUsage?
    public var suggestedName: String?
}

public final class SubscriptionClient: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    public override init() { super.init() }
    public func prepareResources(_ input: PreparedConfiguration) async throws -> PreparedConfiguration {
        var result = input; result.resources = []; var total = 0
        for request in input.resourceRequests {
            try Task.checkCancellation()
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15; configuration.timeoutIntervalForResource = 45
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            var fetch = URLRequest(url: request.url)
            fetch.setValue("ClashDash/0.1 mihomo", forHTTPHeaderField: "User-Agent")
            for (field, value) in request.headers { fetch.setValue(value, forHTTPHeaderField: field) }
            let (stream, response) = try await session.bytes(for: fetch)
            guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
                throw DashError.message("远程节点或规则资源读取失败，配置尚未保存。")
            }
            var data = Data()
            for try await byte in stream {
                try Task.checkCancellation(); data.append(byte); total += 1
                guard data.count <= 5 * 1024 * 1024, total <= 20 * 1024 * 1024 else {
                    throw DashError.message("远程资源超过首版限制：单项 5 MB，总计 20 MB。配置尚未保存。")
                }
            }
            guard !data.isEmpty else { throw DashError.message("远程资源为空，配置尚未保存。") }
            result.resources.append(StagedResource(relativePath: request.relativePath, data: data))
        }
        return result
    }
    public func download(_ url: URL) async throws -> SubscriptionDownload {
        guard url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil else {
            throw DashError.message("请输入 HTTPS 订阅地址。地址应指向 Clash / mihomo 配置。")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15; configuration.timeoutIntervalForResource = 45
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("ClashDash/0.1 mihomo", forHTTPHeaderField: "User-Agent")
        request.setValue("application/yaml, text/yaml, text/plain, */*", forHTTPHeaderField: "Accept")
        let (stream, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw DashError.message("订阅服务返回错误（HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)）。请检查地址或稍后重试。")
        }
        guard response.expectedContentLength <= DashConstants.maximumConfigurationBytes else { throw DashError.message("订阅配置超过 5 MB。") }
        var data = Data(); data.reserveCapacity(min(Int(max(response.expectedContentLength, 0)), DashConstants.maximumConfigurationBytes))
        for try await byte in stream {
            try Task.checkCancellation(); data.append(byte)
            if data.count > DashConstants.maximumConfigurationBytes { throw DashError.message("订阅配置超过 5 MB。") }
        }
        guard let text = String(data: data, encoding: .utf8) else { throw DashError.message("订阅内容不是 UTF-8 文本。") }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("<!doctype html") || text.lowercased().hasPrefix("<html") {
            throw DashError.message("这个地址返回了网页。请复制订阅面板中的 Clash 订阅链接。")
        }
        let title = http.value(forHTTPHeaderField: "profile-title")
        return SubscriptionDownload(text: text, usage: .parse(http.value(forHTTPHeaderField: "subscription-userinfo")), suggestedName: title)
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard request.url?.scheme?.lowercased() == "https", task.countOfBytesReceived <= DashConstants.maximumConfigurationBytes else {
            completionHandler(nil); return
        }
        var safe = request
        if response.url?.host != request.url?.host {
            safe.setValue(nil, forHTTPHeaderField: "Authorization"); safe.setValue(nil, forHTTPHeaderField: "Cookie")
        }
        completionHandler(safe)
    }
}
