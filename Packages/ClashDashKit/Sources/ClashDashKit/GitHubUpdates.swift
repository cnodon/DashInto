import Foundation

public struct GitHubRepository: Equatable, Sendable {
    public let path: String
    public init(_ input: String) throws {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("https://github.com/") { text = String(text.dropFirst("https://github.com/".count)) }
        if text.hasSuffix("/") { text.removeLast() }
        if text.hasSuffix(".git") { text = String(text.dropLast(4)) }
        guard text.range(of: "^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9_.-]{1,100}$", options: .regularExpression) != nil,
              !text.hasSuffix("/.."), !text.hasSuffix("/.") else { throw DashError.message("请输入 GitHub 公共仓库地址，或 owner/repository。") }
        path = text
    }
    public var releasesURL: URL { URL(string: "https://github.com/" + path + "/releases")! }
}

/// Published development tags use vMAJOR.MINOR.PATCH-build.NUMBER; stable tags omit the suffix.
public struct AppReleaseVersion: Comparable, Equatable, Sendable {
    public let components: [Int]
    public let build: Int
    public init?(tag: String) {
        var value = tag
        if value.hasPrefix("v") { value.removeFirst() }
        let parts = value.components(separatedBy: "-build.")
        guard parts.count <= 2 else { return nil }
        let numbers = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard numbers.count == 3, numbers.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              numbers.compactMap({ Int($0) }).count == 3 else { return nil }
        components = numbers.compactMap { Int($0) }
        if parts.count == 2 {
            guard !parts[1].isEmpty, parts[1].allSatisfy(\.isNumber), let number = Int(parts[1]) else { return nil }
            build = number
        } else { build = 0 }
    }
    public init?(version: String, build: String) { self.init(tag: version + "-build." + build) }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.components == rhs.components ? lhs.build < rhs.build : lhs.components.lexicographicallyPrecedes(rhs.components)
    }
}

public struct GitHubRelease: Codable, Sendable {
    public let tag_name: String
    public let html_url: String
    public let body: String?
    public let draft: Bool
    public let prerelease: Bool
    public var version: AppReleaseVersion? { AppReleaseVersion(tag: tag_name) }
    public func trustedURL(repository: GitHubRepository) -> URL? {
        guard let url = URL(string: html_url), url.scheme == "https", url.host == "github.com", url.user == nil, url.password == nil,
              url.port == nil, url.query == nil, url.path.lowercased().hasPrefix("/" + repository.path.lowercased() + "/releases/tag/") else { return nil }
        return url
    }
}

public enum GitHubUpdateClient {
    public static func select(_ releases: [GitHubRelease], repository: GitHubRepository, includeDevelopment: Bool) -> GitHubRelease? {
        releases.filter { !$0.draft && (includeDevelopment || !$0.prerelease) && $0.version != nil && $0.trustedURL(repository: repository) != nil }
            .max { $0.version! < $1.version! }
    }
    public static func latest(repository: GitHubRepository, includeDevelopment: Bool) async throws -> GitHubRelease? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/" + repository.path + "/releases?per_page=30")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("DashInto-iOS", forHTTPHeaderField: "User-Agent")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12; configuration.timeoutIntervalForResource = 18
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        let (stream, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw DashError.message("GitHub 响应无效。") }
        guard http.statusCode == 200 else {
            throw DashError.message(http.statusCode == 404 ? "仓库不存在、未公开或暂不可访问。" : [403,429].contains(http.statusCode) ? "GitHub 暂时限制检查频率，请稍后再试。" : "GitHub 检查失败（HTTP \(http.statusCode)）。")
        }
        var data = Data()
        for try await byte in stream {
            try Task.checkCancellation(); data.append(byte)
            if data.count > 2 * 1024 * 1024 { throw DashError.message("版本列表过大，请到 GitHub 查看。") }
        }
        return select(try JSONDecoder().decode([GitHubRelease].self, from: data), repository: repository, includeDevelopment: includeDevelopment)
    }
}
