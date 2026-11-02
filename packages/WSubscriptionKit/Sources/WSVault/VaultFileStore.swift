import Foundation
import WSCore

#if canImport(UIKit)
import UIKit
#endif

/// 用户选择的目录。iOS 上通过 security-scoped bookmark 持久化访问权限。
public struct FolderAccess: Sendable {
    public enum Mode: Sendable {
        case securityScoped
        case plain
    }

    public let url: URL
    public let mode: Mode
    /// 书签是否已失效（文件夹被移动/文件提供者容器变化）。iOS 上无法静默恢复，需要用户重新选择。
    public let isStale: Bool

    public init(url: URL, mode: Mode = .plain, isStale: Bool = false) {
        self.url = url
        self.mode = mode
        self.isStale = isStale
    }

    public static func bookmark(for url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    public static func from(bookmark: Data) throws -> FolderAccess {
        var isStale = false
        do {
            let url = try URL(resolvingBookmarkData: bookmark,
                              options: [],
                              relativeTo: nil,
                              bookmarkDataIsStale: &isStale)
            return FolderAccess(url: url, mode: .securityScoped, isStale: isStale)
        } catch {
            throw VaultError(.folderPermissionLost)
        }
    }

    /// 每次 IO 单独获取/释放作用域，避免同时占用过多 scoped resource。
    public func withAccess<T>(_ body: (URL) throws -> T) throws -> T {
        guard mode == .securityScoped else { return try body(url) }
        guard url.startAccessingSecurityScopedResource() else {
            throw VaultError(.folderPermissionLost)
        }
        defer { url.stopAccessingSecurityScopedResource() }
        return try body(url)
    }

    public func probe() -> Bool {
        (try? withAccess { directory in
            FileManager.default.isReadableFile(atPath: directory.path)
        }) ?? false
    }
}

public struct VaultFileStore: Sendable {
    public let access: FolderAccess
    public let fileName: String

    public init(access: FolderAccess, fileName: String = "WSubscription.vault") {
        self.access = access
        self.fileName = fileName
    }

    public var fileURL: URL { access.url.appendingPathComponent(fileName, isDirectory: false) }
    public var backupURL: URL { access.url.appendingPathComponent(fileName + ".bak", isDirectory: false) }

    public func exists() -> Bool {
        (try? access.withAccess { dir in
            FileManager.default.fileExists(atPath: dir.appendingPathComponent(fileName).path)
        }) ?? false
    }

    public func read() throws -> Data {
        try access.withAccess { dir in
            let target = dir.appendingPathComponent(fileName)
            guard FileManager.default.fileExists(atPath: target.path) else {
                throw VaultError(.vaultNotFound)
            }
            var coordinationError: NSError?
            var result: Result<Data, Error>?
            NSFileCoordinator().coordinate(readingItemAt: target, options: [], error: &coordinationError) { url in
                result = Result { try Data(contentsOf: url) }
            }
            if let coordinationError {
                throw VaultError(.io(coordinationError.localizedDescription))
            }
            guard let result else { throw VaultError(.io("文件读取被中断")) }
            return try result.get()
        }
    }

    public func readBackup() -> Data? {
        try? access.withAccess { dir in
            try Data(contentsOf: dir.appendingPathComponent(fileName + ".bak"))
        }
    }

    /// 原子写：协调 → 写临时文件 → 保留上一版为 .bak → 替换。
    public func write(_ data: Data) throws {
        guard !data.isEmpty else { throw VaultError(.corrupted) }
        try access.withAccess { dir in
            let target = dir.appendingPathComponent(fileName)
            let backup = dir.appendingPathComponent(fileName + ".bak")

            var coordinationError: NSError?
            var innerError: Error?

            NSFileCoordinator().coordinate(writingItemAt: target, options: .forReplacing,
                                           error: &coordinationError) { url in
                do {
                    if FileManager.default.fileExists(atPath: target.path),
                       let previous = try? Data(contentsOf: target) {
                        try? previous.write(to: backup, options: .atomic)
                    }
                    try data.write(to: url, options: .atomic)
                    #if os(iOS)
                    try? (url as NSURL).setResourceValue(URLFileProtection.complete, forKey: .fileProtectionKey)
                    #endif
                } catch {
                    innerError = error
                }
            }

            if let coordinationError {
                throw VaultError(.io(coordinationError.localizedDescription))
            }
            if let innerError {
                let nsError = innerError as NSError
                if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileWriteOutOfSpaceError {
                    throw VaultError(.diskFull)
                }
                throw VaultError(.io(nsError.localizedDescription))
            }
        }
    }

    public func deleteFile() throws {
        try access.withAccess { dir in
            let target = dir.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
        }
    }
}

/// 书签持久化。书签本身不是秘密（文件是密文），放 UserDefaults 即可，也便于测试注入。
/// UserDefaults 本身线程安全，但其类型未标注 Sendable，这里显式承诺。
public struct VaultBookmarkStore: @unchecked Sendable {
    public struct Record: Codable, Sendable {
        public var bookmark: Data
        public var fileName: String
        public var displayPath: String

        public init(bookmark: Data, fileName: String, displayPath: String) {
            self.bookmark = bookmark
            self.fileName = fileName
            self.displayPath = displayPath
        }
    }

    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "ws.vault.location.v1") {
        self.defaults = defaults
        self.key = key
    }

    public func save(_ record: Record) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: key)
    }

    public func load() -> Record? {
        guard let data = defaults.data(forKey: key),
              let record = try? JSONDecoder().decode(Record.self, from: data) else { return nil }
        return record
    }

    public func clear() {
        defaults.removeObject(forKey: key)
    }
}

/// 本机记录见过的最大 revision，用于检测「文件被替换成旧版本」。
/// 只告警不阻断 —— 用户从备份恢复也属于合法场景。
public struct RevisionLedger: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "ws.vault.revision.v1") {
        self.defaults = defaults
        self.key = key
    }

    public func record(_ revision: UInt64) {
        let known = UInt64(defaults.integer(forKey: key))
        if revision > known {
            defaults.set(Int(revision), forKey: key)
        }
    }

    public func known() -> UInt64 {
        UInt64(defaults.integer(forKey: key))
    }

    public func isRollback(_ revision: UInt64) -> Bool {
        revision < known()
    }
}
