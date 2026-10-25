import Foundation
import CryptoKit
import Security

public protocol KeyMaterialProviding: Sendable { func key() throws -> Data }

public struct KeychainKeyProvider: KeyMaterialProviding {
    private let accessGroup: String?
    public init(accessGroup: String? = nil) { self.accessGroup = accessGroup }
    public func key() throws -> Data {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "app.clashdash.encryption", kSecAttrAccount as String: "configuration-key"]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        var read = query; read[kSecReturnData as String] = true; read[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data { return data }
        if status == errSecMissingEntitlement { throw DashError.message("当前 App 缺少钥匙串签名权限，请使用正确签名的构建重新安装。（\(status)）") }
        guard status == errSecItemNotFound else { throw DashError.message("无法读取配置密钥。设备重启后请先解锁一次。（\(status)）") }
        let data = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(query as CFDictionary, nil)
        if added == errSecDuplicateItem { return try key() }
        guard added == errSecSuccess else { throw DashError.message("无法保存配置密钥。（\(added)）") }
        return data
    }
}

public struct ConfigurationEnvelope: Codable, Sendable {
    public var original: String
    public var runtime: String
    public var sourceURL: String?
    public var resources: [ResourceDescriptor]?
    public var geodata: [GeodataDescriptor]?
    public init(original: String, runtime: String, sourceURL: String?) {
        self.original = original; self.runtime = runtime; self.sourceURL = sourceURL
    }
}

public struct ImportCommit: Sendable {
    public let profileID: UUID
    public let generation: String
    public let library: ProfileLibrary
}

public actor ProfileStore {
    public let root: URL
    private let keyProvider: any KeyMaterialProviding
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    public init(root: URL, keyProvider: any KeyMaterialProviding) {
        self.root = root; self.keyProvider = keyProvider
    }

    public func library() throws -> ProfileLibrary {
        let url = root.appendingPathComponent("library.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return ProfileLibrary() }
        return try decoder.decode(ProfileLibrary.self, from: Data(contentsOf: url))
    }
    public func saveLibrary(_ library: ProfileLibrary) throws {
        try ensureRoot()
        try writeProtected(encoder.encode(library), to: root.appendingPathComponent("library.json"))
    }
    /// Consolidate the old validation copy only when the encrypted source addresses match exactly.
    /// Copy all revisions before atomically publishing the new index; keep the original folder as a recovery copy.
    public func consolidateValidationDuplicate(retainingProfileID: UUID? = nil) throws -> ProfileLibrary {
        var state = try library()
        guard let mine = state.profiles.first(where: { $0.name == "我的订阅" && $0.isSubscription }),
              let verified = state.profiles.first(where: { $0.name == "已验证订阅" && $0.isSubscription }),
              let source = try envelope(profileID: mine.id, generation: mine.selectedVersion).sourceURL,
              !source.isEmpty,
              source == (try envelope(profileID: verified.id, generation: verified.selectedVersion).sourceURL) else { return state }
        let preferred = retainingProfileID ?? state.selectedProfileID
        var kept = preferred == verified.id ? verified : mine
        let other = kept.id == mine.id ? verified : mine
        let destination = root.appendingPathComponent(kept.id.uuidString)
        for version in other.versions where !kept.versions.contains(where: { $0.id == version.id }) {
            _ = try envelope(profileID: other.id, generation: version.id)
            let folder = root.appendingPathComponent(other.id.uuidString)
            for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
                where file.lastPathComponent.hasPrefix(version.id) && ["sealed", "resource", "geodata"].contains(file.pathExtension) {
                guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
                let target = destination.appendingPathComponent(file.lastPathComponent)
                if !FileManager.default.fileExists(atPath: target.path) { try FileManager.default.copyItem(at: file, to: target); try protectFile(target) }
            }
            kept.versions.append(version)
        }
        kept.name = mine.name
        kept.versions.sort { $0.createdAt > $1.createdAt }
        kept.selections = (other.selections ?? [:]).merging(kept.selections ?? [:]) { _, current in current }
        kept.preferredMode = kept.preferredMode ?? other.preferredMode
        kept.lastKnownGood = kept.lastKnownGood ?? other.lastKnownGood
        if other.updatedAt > kept.updatedAt { kept.usage = other.usage; kept.updatedAt = other.updatedAt }
        try writeProtected(encoder.encode(state), to: root.appendingPathComponent("before-validation-consolidation.json"))
        state.profiles.removeAll { $0.id == other.id }
        if let index = state.profiles.firstIndex(where: { $0.id == kept.id }) { state.profiles[index] = kept }
        if state.selectedProfileID == other.id { state.selectedProfileID = kept.id }
        try saveLibrary(state)
        return state
    }
    public func importConfiguration(_ prepared: PreparedConfiguration, name: String, sourceURL: URL? = nil,
                                    replacing profileID: UUID? = nil, usage: SubscriptionUsage? = nil,
                                    selectIfEmpty: Bool = true, retaining generations: [String] = []) throws -> ProfileLibrary {
        var state = try library()
        let id = profileID ?? UUID(); let generation = UUID().uuidString
        guard Set(prepared.resourceRequests.map(\.relativePath)) == Set(prepared.resources.map(\.relativePath)),
              prepared.resources.count == Set(prepared.resources.map(\.relativePath)).count else {
            throw DashError.message("远程资源尚未准备完成，配置未保存。")
        }
        try ensureRoot()
        var envelope = ConfigurationEnvelope(original: prepared.original, runtime: prepared.runtime, sourceURL: sourceURL?.absoluteString)
        let key = SymmetricKey(data: try keyProvider.key())
        let folder = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var descriptors: [ResourceDescriptor] = []
        for resource in prepared.resources {
            guard Self.isSafeResourcePath(resource.relativePath) else { throw DashError.message("资源路径无效。") }
            let blobName = generation + "-" + UUID().uuidString + ".resource"
            let encrypted = try AES.GCM.seal(resource.data, using: key)
            guard let data = encrypted.combined else { throw DashError.message("资源加密失败。") }
            try writeProtected(data, to: folder.appendingPathComponent(blobName))
            descriptors.append(.init(relativePath: resource.relativePath, blobName: blobName, hash: SHA256.hash(data: resource.data).map { String(format: "%02x", $0) }.joined()))
        }
        envelope.resources = descriptors
        var geoDescriptors: [GeodataDescriptor] = []
        for resource in prepared.geodata {
            guard Self.safeGeoPaths.contains(resource.relativePath), try FileDigest.sha256(resource.sourceFileURL) == resource.hash else {
                throw DashError.message("地理数据库路径或完整性检查失败，配置未保存。")
            }
            let blobName = generation + "-" + UUID().uuidString + ".geodata"
            let destination = folder.appendingPathComponent(blobName)
            try FileManager.default.copyItem(at: resource.sourceFileURL, to: destination)
            try protectFile(destination)
            geoDescriptors.append(GeodataDescriptor(relativePath: resource.relativePath, blobName: blobName, hash: resource.hash))
        }
        envelope.geodata = geoDescriptors
        let sealed = try AES.GCM.seal(encoder.encode(envelope), using: key)
        guard let data = sealed.combined else { throw DashError.message("配置加密失败。") }
        try writeProtected(data, to: folder.appendingPathComponent(generation + ".sealed"))
        let version = ProfileVersion(id: generation, createdAt: Date(), contentHash: prepared.hash, summary: prepared.summary)
        if let index = state.profiles.firstIndex(where: { $0.id == id }) {
            state.profiles[index].versions.insert(version, at: 0)
            // Keep the running / last-known-good revision available even across multiple downloads.
            let keep = Set(state.profiles[index].versions.prefix(3).map(\.id) + [state.profiles[index].selectedVersion, state.profiles[index].lastKnownGood].compactMap { $0 }).union(generations)
            state.profiles[index].versions.removeAll { !keep.contains($0.id) }
            state.profiles[index].selectedVersion = generation; state.profiles[index].updatedAt = Date()
            state.profiles[index].usage = usage
        } else {
            state.profiles.append(Profile(id: id, name: name, isSubscription: sourceURL != nil, sourceHost: sourceURL?.host, version: version, usage: usage))
        }
        if selectIfEmpty && state.selectedProfileID == nil { state.selectedProfileID = id }
        try saveLibrary(state)
        return state
    }
    /// A user import only saves. Activation is a separate, explicit connection intent.
    public func commitImport(_ prepared: PreparedConfiguration, name: String, sourceURL: URL? = nil,
                             usage: SubscriptionUsage? = nil) throws -> ImportCommit {
        let id = UUID()
        let state = try importConfiguration(prepared, name: name, sourceURL: sourceURL, replacing: id,
                                            usage: usage, selectIfEmpty: false)
        guard let profile = state.profiles.first(where: { $0.id == id }) else { throw DashError.message("保存结果缺失，请重试。") }
        return ImportCommit(profileID: id, generation: profile.selectedVersion, library: state)
    }
    public func envelope(profileID: UUID, generation: String) throws -> ConfigurationEnvelope {
        guard UUID(uuidString: generation) != nil else { throw DashError.message("配置版本标识无效。") }
        let url = root.appendingPathComponent(profileID.uuidString).appendingPathComponent(generation + ".sealed")
        let box = try AES.GCM.SealedBox(combined: Data(contentsOf: url))
        let data = try AES.GCM.open(box, using: SymmetricKey(data: keyProvider.key()))
        return try decoder.decode(ConfigurationEnvelope.self, from: data)
    }
    public func resource(profileID: UUID, descriptor: ResourceDescriptor) throws -> Data {
        guard Self.isSafeResourcePath(descriptor.relativePath), !descriptor.blobName.contains("/"), descriptor.blobName.hasSuffix(".resource") else { throw DashError.message("资源清单无效。") }
        let encrypted = try Data(contentsOf: root.appendingPathComponent(profileID.uuidString).appendingPathComponent(descriptor.blobName))
        let data = try AES.GCM.open(AES.GCM.SealedBox(combined: encrypted), using: SymmetricKey(data: keyProvider.key()))
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard hash == descriptor.hash else { throw DashError.message("资源完整性检查失败。") }
        return data
    }
    private static func isSafeResourcePath(_ value: String) -> Bool {
        value.range(of: "^providers/[a-f0-9]{64}\\.cache$", options: .regularExpression) != nil
    }
    private static let safeGeoPaths: Set<String> = ["GeoIP.dat", "GeoSite.dat", "geoip.metadb", "Country.mmdb", "ASN.mmdb"]
    public func materializeGeodata(profileID: UUID, descriptor: GeodataDescriptor, directory: URL) throws {
        guard Self.safeGeoPaths.contains(descriptor.relativePath), !descriptor.blobName.contains("/"), descriptor.blobName.hasSuffix(".geodata") else {
            throw DashError.message("地理数据库清单无效。")
        }
        let source = root.appendingPathComponent(profileID.uuidString).appendingPathComponent(descriptor.blobName)
        guard try FileDigest.sha256(source) == descriptor.hash else { throw DashError.message("地理数据库完整性检查失败。") }
        let target = directory.appendingPathComponent(descriptor.relativePath)
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        try FileManager.default.copyItem(at: source, to: target)
        try protectFile(target)
    }
    public func select(_ id: UUID) throws -> ProfileLibrary {
        var state = try library()
        guard state.profiles.contains(where: { $0.id == id }) else { throw DashError.message("找不到配置。") }
        state.selectedProfileID = id; try saveLibrary(state); return state
    }
    public func selectVersion(profileID: UUID, generation: String) throws -> ProfileLibrary {
        var state = try library()
        guard let index = state.profiles.firstIndex(where: { $0.id == profileID }), state.profiles[index].versions.contains(where: { $0.id == generation }) else { throw DashError.message("找不到历史版本。") }
        state.profiles[index].selectedVersion = generation; try saveLibrary(state); return state
    }
    public func markGood(profileID: UUID, generation: String) throws {
        var state = try library()
        guard let index = state.profiles.firstIndex(where: { $0.id == profileID }), state.profiles[index].versions.contains(where: { $0.id == generation }) else { return }
        state.profiles[index].lastKnownGood = generation; try saveLibrary(state)
    }
    public func rememberSelection(profileID: UUID, group: String, member: String) throws -> ProfileLibrary {
        var state = try library()
        guard let index = state.profiles.firstIndex(where: { $0.id == profileID }) else { throw DashError.message("找不到配置。") }
        if state.profiles[index].selections == nil { state.profiles[index].selections = [:] }
        state.profiles[index].selections?[group] = member
        try saveLibrary(state); return state
    }
    public func rememberMode(profileID: UUID, mode: RoutingMode) throws -> ProfileLibrary {
        var state = try library()
        guard let index = state.profiles.firstIndex(where: { $0.id == profileID }) else { throw DashError.message("找不到配置。") }
        state.profiles[index].preferredMode = mode; try saveLibrary(state); return state
    }
    public func delete(_ id: UUID) throws -> ProfileLibrary {
        var state = try library(); state.profiles.removeAll { $0.id == id }
        if state.selectedProfileID == id { state.selectedProfileID = state.profiles.first?.id }
        try saveLibrary(state)
        try? FileManager.default.removeItem(at: root.appendingPathComponent(id.uuidString))
        return state
    }
    public func prune(retaining generations: [String] = []) throws {
        let state = try library()
        let additional = Set(generations)
        for profile in state.profiles {
            let keep = Set(profile.versions.map(\.id)).union(additional)
            let folder = root.appendingPathComponent(profile.id.uuidString)
            for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) {
                let generation = String(file.lastPathComponent.prefix(36))
                guard UUID(uuidString: generation) != nil, !keep.contains(generation),
                      ["sealed", "resource", "geodata"].contains(file.pathExtension),
                      (try file.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
                try FileManager.default.removeItem(at: file)
            }
        }
    }
    private func ensureRoot() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: root.path)
        #endif
        var folder = root; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
    }
    private func writeProtected(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try protectFile(url)
    }
    private func protectFile(_ url: URL) throws {
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
        var protected = url; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try protected.setResourceValues(values)
    }
}
