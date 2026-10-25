import Foundation
import CryptoKit
import Clash
import ClashDashKit

actor NativeResourcePreparer {
    static let shared = NativeResourcePreparer()
    private let root: URL
    private var preparing = false
    init(root: URL? = nil) {
        self.root = root ?? (FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: DashConstants.appGroup)
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("ClashDash"))
            .appendingPathComponent("ImportResources", isDirectory: true)
    }
    func prepare(_ input: PreparedConfiguration, progress: @Sendable (String) async -> Void = { _ in }) async throws -> PreparedConfiguration {
        // Actors are reentrant during a download; serialize the native SDK's global compile workspace.
        guard !preparing else { throw DashError.message("另一份配置正在准备资源，请完成后重试。") }
        preparing = true; defer { preparing = false }
        try Task.checkCancellation()
        await progress("准备节点与规则资源")
        var prepared = try await SubscriptionClient().prepareResources(input)
        prepared.summary.providerNodeCount = 0
        prepared.geodata = []
        for resource in prepared.resources {
            guard let request = prepared.resourceRequests.first(where: { $0.relativePath == resource.relativePath }) else { throw DashError.message("资源清单不匹配。") }
            var error: NSError?
            _ = ClashValidateProviderForIOS(request.kind, request.behavior, request.format, resource.data, &error)
            if error != nil { throw DashError.message("远程节点或规则资源未通过核心校验，配置尚未保存。") }
            if request.kind == "proxy" {
                error = nil
                if let box = ClashReadProxyPayloadSummaryForIOS(resource.data, "subscriptionBody", &error), error == nil,
                   let summary = try JSONSerialization.jsonObject(with: Data(box.value.utf8)) as? [String: Any], let count = summary["count"] as? Int {
                    prepared.summary.providerNodeCount = (prepared.summary.providerNodeCount ?? 0) + count
                } else { prepared.summary.providerNodeCount = nil }
            }
        }
        var error: NSError?
        guard let box = ClashPlanResourcesForIOS(prepared.runtime, &error), error == nil,
              let plan = try JSONSerialization.jsonObject(with: Data(box.value.utf8)) as? [String: Any] else {
            throw DashError.message("核心无法生成 iOS 资源计划，配置尚未保存。")
        }
        let issues = plan["errors"] as? [[String: Any]] ?? []
        if !issues.isEmpty { throw DashError.message("配置包含 iOS 不支持的设置（\(issues.count) 项），请使用标准 Clash/mihomo 配置。") }
        let notices = plan["structuredNotices"] as? [[String: Any]] ?? []
        let kinds = Set(notices.compactMap { $0["kind"] as? String })
        var compatibility: [String] = []
        if kinds.contains("metadata-rules-inert") { compatibility.append("部分规则依赖 iOS 无法获取的桌面进程信息，无法按原客户端方式匹配。") }
        if kinds.contains("route-set-inert") { compatibility.append("部分路由集合未提供有效 IP 网段，不会改变系统 VPN 路由。") }
        if kinds.contains("egress-override-stripped") { compatibility.append("配置指定的桌面网络接口或路由标记不适用于 iPhone，将由 App 选择物理网络。") }
        if kinds.contains(where: { $0.hasPrefix("dns-") }) { compatibility.append("部分 DNS 来源或参数不适用于 iOS，核心将移除或替换这些设置；连接后请核对 DNS 可用性。") }
        if kinds.contains("outbound-option-unrepresentable") { compatibility.append("部分节点的高级参数不能完整映射到当前核心；请核对实际连通性。") }
        if kinds.contains("outbound-dns-fragment-inert") { compatibility.append("部分节点内嵌 DNS 的策略后缀不起作用，将通过节点自身的 DNS 路径解析。") }
        for warning in compatibility where !prepared.summary.warnings.contains(warning) { prepared.summary.warnings.append(warning) }
        // provider-file-inert describes upstream App behavior. Our version manifest explicitly stages these files.
        let geo = plan["geodata"] as? [[String: Any]] ?? []
        let allowed: Set<String> = ["GeoIP.dat", "GeoSite.dat", "geoip.metadb", "Country.mmdb", "ASN.mmdb"]
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: root.path)
        #endif
        var cacheRoot = root; var backup = URLResourceValues(); backup.isExcludedFromBackup = true; try cacheRoot.setResourceValues(backup)
        if !geo.isEmpty { await progress("准备分流数据库") }
        for item in geo {
            try Task.checkCancellation()
            guard let path = item["path"] as? String, allowed.contains(path), let kind = item["kind"] as? String,
                  let format = item["format"] as? String, let address = item["url"] as? String, let url = URL(string: address) else {
                throw DashError.message("地理数据库计划无效。")
            }
            let key = SHA256.hash(data: Data(address.utf8)).map { String(format: "%02x", $0) }.joined()
            let cached = root.appendingPathComponent(key + "-" + path)
            let modified = (try? cached.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if !FileManager.default.fileExists(atPath: cached.path) || Date().timeIntervalSince(modified) > 86400 {
                let temporary = root.appendingPathComponent(UUID().uuidString + ".download")
                defer { try? FileManager.default.removeItem(at: temporary) }
                _ = try await ResourceFileDownload(destination: temporary).download(url)
                error = nil; _ = ClashValidateGeodataForIOS(kind, format, temporary.path, &error)
                guard error == nil else { throw DashError.message("下载的地理数据库未通过校验，配置尚未保存。") }
                if FileManager.default.fileExists(atPath: cached.path) { try FileManager.default.removeItem(at: cached) }
                try FileManager.default.moveItem(at: temporary, to: cached)
            }
            error = nil; _ = ClashValidateGeodataForIOS(kind, format, cached.path, &error)
            guard error == nil else { try? FileManager.default.removeItem(at: cached); throw DashError.message("缓存的地理数据库无效，请重新导入。") }
            prepared.geodata.append(PreparedGeodata(relativePath: path, sourceFileURL: cached, hash: try FileDigest.sha256(cached)))
        }
        try Task.checkCancellation()
        await progress("检查连接配置")
        let workspace = root.appendingPathComponent("Compiler-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        for resource in prepared.resources {
            let target = workspace.appendingPathComponent(resource.relativePath)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try resource.data.write(to: target)
        }
        for resource in prepared.geodata { try FileManager.default.copyItem(at: resource.sourceFileURL, to: workspace.appendingPathComponent(resource.relativePath)) }
        let options = ClashSetupOptions()
        options.basePath = workspace.path; options.workingPath = workspace.path; options.tempPath = workspace.path
        options.runtimeProfile = "iosPacketTunnel"; options.maxProcs = 2; options.tunMTU = 1400
        options.disablePersistentCache = true; options.logMaxLines = 0
        error = nil; ClashSetup(options, &error)
        guard error == nil else { throw DashError.message("无法初始化配置校验器。") }
        guard let checked = ClashCompileCheckForIOS(prepared.runtime, "{}", &error), error == nil,
              let result = try JSONSerialization.jsonObject(with: Data(checked.value.utf8)) as? [String: Any] else {
            throw DashError.message("核心配置检查未完成，配置尚未保存。")
        }
        guard result["ok"] as? Bool == true else {
            let first = (result["errors"] as? [[String: Any]])?.first
            let section = first?["section"] as? String ?? "配置"
            let index = (first?["index"] as? Int).map { "第 \($0 + 1) 项" } ?? ""
            throw DashError.message("核心检查发现\(section)\(index)存在错误，配置尚未保存。")
        }
        if !geo.isEmpty {
            prepared.summary.warnings.removeAll { $0.contains("首次连接可能需要下载") }
            prepared.summary.warnings.append("所需地理数据库已下载并验证，会随配置版本保存；VPN 扩展无需在首次启动时下载。")
        }
        return prepared
    }
}
