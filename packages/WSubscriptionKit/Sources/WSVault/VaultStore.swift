import Foundation
import WSCore
import WSCrypto

public enum VaultEvent: Sendable {
    case unlocked
    case changed(VaultSnapshot)
    case saved(revision: UInt64)
    case locked
    case warning(String)
}

/// 唯一持有密钥与明文的对象。所有写入串行化，UI 只能拿到不可变快照。
public actor VaultStore {
    public struct Configuration: Sendable {
        public var fileName: String
        public var autosaveDelay: Duration
        public var kdf: KDFParameters

        public init(fileName: String = "WSubscription.vault",
                    autosaveDelay: Duration = .milliseconds(600),
                    kdf: KDFParameters = .standard) {
            self.fileName = fileName
            self.autosaveDelay = autosaveDelay
            self.kdf = kdf
        }
    }

    private let store: VaultFileStore
    private let configuration: Configuration
    private let ledger: RevisionLedger
    public nonisolated let deviceID: UUID

    private var masterKey: SecureBytes?
    private var snapshot: VaultSnapshot?
    private var currentFileData: Data?
    private var revision: UInt64 = 0
    private var isDirty = false
    private var saveTask: Task<Void, Never>?
    private var continuations: [UUID: AsyncStream<VaultEvent>.Continuation] = [:]

    /// 上次打开时检测到文件版本比本机记录更旧（可能是从备份恢复，也可能是被替换）。
    public private(set) var detectedRollback = false

    public init(store: VaultFileStore,
                configuration: Configuration = Configuration(),
                ledger: RevisionLedger = RevisionLedger(),
                deviceID: UUID = VaultStore.persistentDeviceID()) {
        self.store = store
        self.configuration = configuration
        self.ledger = ledger
        self.deviceID = deviceID
    }

    public nonisolated static func persistentDeviceID(defaults: UserDefaults = .standard) -> UUID {
        let key = "ws.device.id.v1"
        if let raw = defaults.string(forKey: key), let uuid = UUID(uuidString: raw) { return uuid }
        let uuid = UUID()
        defaults.set(uuid.uuidString, forKey: key)
        return uuid
    }

    // MARK: - 状态查询

    public var isUnlocked: Bool { masterKey != nil && snapshot != nil }
    public var currentSnapshot: VaultSnapshot? { snapshot }
    public var fileURL: URL { store.fileURL }
    public var hasFile: Bool { store.exists() }

    public func headerSummary() -> (revision: UInt64, hasBiometric: Bool)? {
        guard let data = try? store.read(), let header = try? VaultFileCodec.header(of: data) else { return nil }
        return (header.revision, header.hasBiometric)
    }

    // MARK: - 建库

    public func createVault(initial: VaultSnapshot,
                            passphrase: String,
                            recoveryKey: String? = nil,
                            biometricPublicKey: Data? = nil) async throws -> (snapshot: VaultSnapshot, recoveryKey: String) {
        var snapshot = initial
        snapshot.schemaVersion = SchemaMigrator.currentVersion
        snapshot.settings.biometryEnabled = biometricPublicKey != nil

        let payload = try SchemaMigrator.encode(snapshot)
        let creation = try VaultKeyring.create(payload: payload,
                                               passphrase: passphrase,
                                               recoveryKey: recoveryKey,
                                               biometricPublicKey: biometricPublicKey,
                                               revision: 1,
                                               deviceID: deviceID,
                                               kdf: configuration.kdf)
        do {
            try store.write(creation.fileData)
        } catch {
            throw Self.map(error)
        }

        self.masterKey = creation.masterKey
        self.snapshot = snapshot
        self.currentFileData = creation.fileData
        self.revision = 1
        self.isDirty = false
        ledger.record(1)
        emit(.unlocked)
        return (snapshot, creation.recoveryKey)
    }

    // MARK: - 解锁

    public func unlock(passphrase: String) async throws -> VaultSnapshot {
        try await performUnlock { fileData in
            try VaultKeyring.masterKey(passphrase: passphrase, fileData: fileData)
        }
    }

    public func unlockWithRecoveryKey(_ key: String) async throws -> VaultSnapshot {
        try await performUnlock { fileData in
            try VaultKeyring.masterKey(recoveryKey: key, fileData: fileData)
        }
    }

    /// provider 接收文件的临时公钥，返回 ECDH 共享密钥（内部会触发 Face ID）。
    public func unlockWithBiometry(sharedSecretProvider: @Sendable (Data) throws -> SecureBytes) async throws -> VaultSnapshot {
        try await performUnlock { fileData in
            try VaultKeyring.masterKey(fileData: fileData, sharedSecretProvider: sharedSecretProvider)
        }
    }

    private func performUnlock(_ keyProvider: (Data) throws -> SecureBytes) async throws -> VaultSnapshot {
        let fileData: Data
        do {
            fileData = try store.read()
        } catch {
            throw Self.map(error)
        }

        let header: VaultHeader
        do {
            header = try VaultFileCodec.header(of: fileData)
        } catch {
            throw Self.map(error)
        }

        detectedRollback = ledger.isRollback(header.revision) && header.revision > 0

        let key: SecureBytes
        do {
            key = try keyProvider(fileData)
        } catch {
            throw Self.map(error)
        }

        do {
            let payload = try VaultKeyring.open(fileData: fileData, masterKey: key)
            let snapshot = try SchemaMigrator.decode(payload)
            self.masterKey = key
            self.snapshot = snapshot
            self.currentFileData = fileData
            self.revision = header.revision
            self.isDirty = false
            ledger.record(header.revision)
            emit(.unlocked)
            if detectedRollback {
                emit(.warning("这个文件比本机记录更旧，可能来自备份"))
            }
            return snapshot
        } catch {
            throw Self.map(error)
        }
    }

    // MARK: - 修改与保存

    public func update(_ body: @Sendable (inout VaultSnapshot) throws -> Void) async throws {
        guard var working = snapshot, masterKey != nil else { throw VaultError(.notUnlocked) }
        try body(&working)
        snapshot = working
        isDirty = true
        emit(.changed(working))
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let delay = configuration.autosaveDelay
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            try? await self?.flush()
        }
    }

    /// 立即落盘。切后台、退出编辑器、手动保存时调用。
    public func flush() async throws {
        saveTask?.cancel()
        saveTask = nil
        guard isDirty, let snapshot, let masterKey, let fileData = currentFileData else { return }

        do {
            let payload = try SchemaMigrator.encode(snapshot)
            let nextRevision = max(revision, 1) + 1
            let newData = try VaultKeyring.reseal(payload: payload,
                                                  basedOn: fileData,
                                                  masterKey: masterKey,
                                                  revision: nextRevision,
                                                  deviceID: deviceID)
            try store.write(newData)
            currentFileData = newData
            revision = nextRevision
            isDirty = false
            ledger.record(nextRevision)
            emit(.saved(revision: nextRevision))
        } catch {
            isDirty = true
            throw Self.map(error)
        }
    }

    public func lock(flushFirst: Bool = true) async {
        if flushFirst, isDirty {
            try? await flush()
        }
        saveTask?.cancel()
        saveTask = nil
        masterKey = nil
        snapshot = nil
        currentFileData = nil
        isDirty = false
        emit(.locked)
    }

    // MARK: - 密钥管理

    public func changePassphrase(to newPassphrase: String) async throws {
        guard let masterKey, let fileData = currentFileData else { throw VaultError(.notUnlocked) }
        do {
            let nextRevision = revision + 1
            let newData = try VaultKeyring.changePassphrase(fileData: fileData,
                                                            masterKey: masterKey,
                                                            newPassphrase: newPassphrase,
                                                            revision: nextRevision,
                                                            deviceID: deviceID,
                                                            kdf: configuration.kdf)
            try store.write(newData)
            currentFileData = newData
            revision = nextRevision
            ledger.record(nextRevision)
            emit(.saved(revision: nextRevision))
        } catch {
            throw Self.map(error)
        }
    }

    public func enableBiometry(publicKey: Data) async throws {
        guard let masterKey, let fileData = currentFileData else { throw VaultError(.notUnlocked) }
        do {
            let nextRevision = revision + 1
            let newData = try VaultKeyring.attachBiometric(fileData: fileData,
                                                           masterKey: masterKey,
                                                           biometricPublicKey: publicKey,
                                                           revision: nextRevision,
                                                           deviceID: deviceID)
            try store.write(newData)
            currentFileData = newData
            revision = nextRevision
            ledger.record(nextRevision)
            try await update { $0.settings.biometryEnabled = true }
            try await flush()
        } catch {
            throw Self.map(error)
        }
    }

    public func disableBiometry() async throws {
        guard let masterKey, let fileData = currentFileData else { throw VaultError(.notUnlocked) }
        do {
            let nextRevision = revision + 1
            let newData = try VaultKeyring.detachBiometric(fileData: fileData,
                                                           masterKey: masterKey,
                                                           revision: nextRevision,
                                                           deviceID: deviceID)
            try store.write(newData)
            currentFileData = newData
            revision = nextRevision
            ledger.record(nextRevision)
            try await update { $0.settings.biometryEnabled = false }
            try await flush()
        } catch {
            throw Self.map(error)
        }
    }

    public func regenerateRecoveryKey() async throws -> String {
        guard let masterKey, let fileData = currentFileData else { throw VaultError(.notUnlocked) }
        do {
            let nextRevision = revision + 1
            let result = try VaultKeyring.rotateRecoveryKey(fileData: fileData,
                                                            masterKey: masterKey,
                                                            newRecoveryKey: nil,
                                                            revision: nextRevision,
                                                            deviceID: deviceID,
                                                            kdf: configuration.kdf)
            try store.write(result.fileData)
            currentFileData = result.fileData
            revision = nextRevision
            ledger.record(nextRevision)
            return result.code
        } catch {
            throw Self.map(error)
        }
    }

    // MARK: - 事件

    public func events() -> AsyncStream<VaultEvent> {
        let (stream, continuation) = AsyncStream<VaultEvent>.makeStream()
        let id = UUID()
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.dropContinuation(id) }
        }
        return stream
    }

    private func dropContinuation(_ id: UUID) {
        continuations[id] = nil
    }

    private func emit(_ event: VaultEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    // MARK: - 错误映射

    public static func map(_ error: Error) -> VaultError {
        if let vaultError = error as? VaultError { return vaultError }
        if let migration = error as? SchemaMigrator.MigrationError {
            switch migration {
            case .tooNew: return VaultError(.schemaTooNew)
            case .unreadable: return VaultError(.corrupted)
            }
        }
        guard let crypto = error as? CryptoError else {
            return VaultError(.io(error.localizedDescription))
        }
        switch crypto {
        case .credentialRejected: return VaultError(.wrongCredential)
        case .integrityFailure: return VaultError(.fileTampered)
        case .biometryUnavailable: return VaultError(.biometryUnavailable)
        case .unsupportedVersion, .unsupportedKDF: return VaultError(.schemaTooNew)
        case .badMagic, .malformedHeader: return VaultError(.corrupted)
        case .keychainFailure(let status): return VaultError(.io("钥匙串错误 \(status)"))
        default: return VaultError(.corrupted)
        }
    }
}
