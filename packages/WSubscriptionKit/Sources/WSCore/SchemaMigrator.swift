import Foundation

/// schema 版本迁移。任何新版本写入的字段都不能被旧版本静默丢弃，因此：
/// - 文件版本 > App 支持版本 → 拒绝打开（提示升级 App）
/// - 文件版本 < App 支持版本 → 逐级迁移，迁移成功后立即回写
public enum SchemaMigrator {
    public static let currentVersion = 1

    public enum MigrationError: Error, LocalizedError {
        case tooNew(found: Int, supported: Int)
        case unreadable

        public var errorDescription: String? {
            switch self {
            case .tooNew: return VaultError(.schemaTooNew).errorDescription
            case .unreadable: return VaultError(.corrupted).errorDescription
            }
        }
    }

    public static func decode(_ data: Data, decoder: JSONDecoder = .ws) throws -> VaultSnapshot {
        guard let probe = try? decoder.decode(VersionProbe.self, from: data) else {
            throw MigrationError.unreadable
        }
        if probe.schemaVersion > currentVersion {
            throw MigrationError.tooNew(found: probe.schemaVersion, supported: currentVersion)
        }
        var snapshot = try decoder.decode(VaultSnapshot.self, from: data)
        if snapshot.schemaVersion < currentVersion {
            snapshot = try migrate(snapshot)
        }
        return snapshot
    }

    public static func encode(_ snapshot: VaultSnapshot, encoder: JSONEncoder = .ws) throws -> Data {
        try encoder.encode(snapshot)
    }

    /// 迁移链：目前只有 v1。新增版本时在此逐级追加，禁止跳级。
    static func migrate(_ snapshot: VaultSnapshot) throws -> VaultSnapshot {
        var working = snapshot
        while working.schemaVersion < currentVersion {
            switch working.schemaVersion {
            case 1:
                working.schemaVersion = 1
            default:
                working.schemaVersion += 1
            }
        }
        return working
    }

    private struct VersionProbe: Decodable {
        var schemaVersion: Int
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        }
        private enum CodingKeys: String, CodingKey { case schemaVersion }
    }
}

public extension JSONEncoder {
    static var ws: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

public extension JSONDecoder {
    static var ws: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
