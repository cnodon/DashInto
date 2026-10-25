import Foundation

public enum TunnelPaths {
    /// Darwin sockaddr_un allows 103 path bytes. The versioned resource directory is too deep on iOS.
    public static func controlDirectory(in container: URL) throws -> URL {
        let directory = container.appendingPathComponent("Core", isDirectory: true)
        guard directory.appendingPathComponent("clash.sock").path.utf8.count <= 103 else {
            throw DashError.message("系统分配的运行目录过长，无法创建 VPN 内部通信文件。")
        }
        return directory
    }
}

/// Small, credential-free handoff, also available when startup fails before IPC is ready.
public struct TunnelStartupStatus: Codable, Sendable {
    public var startupID: String?
    public var generation: String
    public var phase: String
    public var failure: String?
    public var date: Date
    public static let filename = "TunnelStartupStatus.json"
    public static func write(to container: URL, generation: String, phase: String, startupID: String? = nil, failure: String? = nil) {
        let value = Self(startupID: startupID, generation: generation, phase: phase, failure: failure, date: Date())
        guard let data = try? JSONEncoder().encode(value) else { return }
        #if os(iOS)
        try? data.write(to: container.appendingPathComponent(filename), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try? data.write(to: container.appendingPathComponent(filename), options: .atomic)
        #endif
    }
    public static func read(from container: URL) -> Self? {
        guard let data = try? Data(contentsOf: container.appendingPathComponent(filename)) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}
