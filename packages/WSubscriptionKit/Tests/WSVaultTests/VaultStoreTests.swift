import XCTest
@testable import WSVault
import WSCore
import WSCrypto

final class VaultStoreTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wsvault-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = "wsvault.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeStore(name: String = "WSubscription.vault") -> VaultStore {
        let access = FolderAccess(url: directory)
        let fileStore = VaultFileStore(access: access, fileName: name)
        let config = VaultStore.Configuration(fileName: name,
                                              autosaveDelay: .milliseconds(20),
                                              kdf: .testing)
        return VaultStore(store: fileStore,
                          configuration: config,
                          ledger: RevisionLedger(defaults: defaults, key: "rev"),
                          deviceID: UUID())
    }

    // MARK: - 文件夹授权（iCloud 云盘）

    /// 回归：`startAccessingSecurityScopedResource()` 返回 false 只说明「这个 URL 不需要作用域」，
    /// 不代表没有权限。旧实现把 false 当失败，iCloud 云盘这类目录会被一律判成「权限已失效」。
    func testSecurityScopedAccessToleratesMissingScopeFlag() throws {
        let access = FolderAccess(url: directory, mode: .securityScoped)
        XCTAssertNoThrow(try access.verifyWritable())
        XCTAssertTrue(access.probe())
    }

    func testReadOnlyFolderIsRejectedBeforeCreatingVault() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        }

        let access = FolderAccess(url: directory, mode: .securityScoped)
        XCTAssertThrowsError(try access.verifyWritable()) { error in
            XCTAssertEqual((error as? VaultError)?.kind, .notWritableFolder)
        }
    }

    func testBookmarkRoundTripKeepsFolderUsable() throws {
        let bookmark = try FolderAccess.bookmark(for: directory)
        let access = try FolderAccess.from(bookmark: bookmark)
        XCTAssertFalse(access.isStale)
        XCTAssertTrue(access.probe())
        XCTAssertNoThrow(try access.verifyWritable())
    }

    private func sampleSnapshot() -> VaultSnapshot {
        var snapshot = VaultSnapshot()
        snapshot.settings.primaryCurrency = "CNY"
        snapshot.subscriptions = [
            Subscription(name: "Netflix", categoryID: "streaming",
                         price: Money(minorUnits: 8800, currencyCode: "CNY"),
                         cycle: .monthly, deviceID: UUID())
        ]
        return snapshot
    }

    func testCreateWritesFileAndUnlockRestoresData() async throws {
        let store = makeStore()
        let (created, recovery, _) = try await store.createVault(initial: sampleSnapshot(), passphrase: "pw-123456")
        XCTAssertEqual(created.subscriptions.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("WSubscription.vault").path))

        await store.lock()
        let reopened = try await store.unlock(passphrase: "pw-123456")
        XCTAssertEqual(reopened.subscriptions.first?.name, "Netflix")
        XCTAssertEqual(recovery.count, 29)
    }

    func testFileNeverContainsPlaintext() async throws {
        let store = makeStore()
        _ = try await store.createVault(initial: sampleSnapshot(), passphrase: "pw")
        let data = try Data(contentsOf: directory.appendingPathComponent("WSubscription.vault"))
        XCTAssertNil(String(data: data, encoding: .utf8))
        XCTAssertFalse(data.range(of: Data("Netflix".utf8)) != nil)
        XCTAssertTrue(data.starts(with: Data([0x57, 0x53, 0x56, 0x4C])))
    }

    func testWrongPassphraseThrowsTypedError() async throws {
        let store = makeStore()
        _ = try await store.createVault(initial: sampleSnapshot(), passphrase: "right")
        await store.lock()
        do {
            _ = try await store.unlock(passphrase: "wrong")
            XCTFail("应当失败")
        } catch let error as VaultError {
            XCTAssertEqual(error.kind, .wrongCredential)
        }
    }

    func testRecoveryKeyUnlock() async throws {
        let store = makeStore()
        let (_, recovery, _) = try await store.createVault(initial: sampleSnapshot(), passphrase: "pw")
        await store.lock()
        let snapshot = try await store.unlockWithRecoveryKey(recovery)
        XCTAssertEqual(snapshot.subscriptions.count, 1)
    }

    func testUpdatePersistsAfterFlush() async throws {
        let store = makeStore()
        _ = try await store.createVault(initial: sampleSnapshot(), passphrase: "pw")
        try await store.update { snapshot in
            snapshot.subscriptions.append(
                Subscription(name: "iCloud+", categoryID: "cloud",
                             price: Money(minorUnits: 600, currencyCode: "CNY"),
                             cycle: .monthly, deviceID: UUID())
            )
        }
        try await store.flush()
        await store.lock(flushFirst: false)

        let reopened = try await store.unlock(passphrase: "pw")
        XCTAssertEqual(reopened.subscriptions.count, 2)
    }

    func testAutosaveWithoutExplicitFlush() async throws {
        let store = makeStore()
        _ = try await store.createVault(initial: sampleSnapshot(), passphrase: "pw")
        try await store.update { $0.settings.primaryCurrency = "USD" }
        try await Task.sleep(for: .milliseconds(200))
        await store.lock(flushFirst: false)

        let reopened = try await store.unlock(passphrase: "pw")
        XCTAssertEqual(reopened.settings.primaryCurrency, "USD")
    }

    func testBackupFileCreatedOnSecondWrite() async throws {
        let store = makeStore()
        _ = try await store.createVault(initial: sampleSnapshot(), passphrase: "pw")
        try await store.update { $0.settings.primaryCurrency = "USD" }
        try await store.flush()

        let backup = directory.appendingPathComponent("WSubscription.vault.bak")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
    }

    func testChangePassphraseThenOldFails() async throws {
        let store = makeStore()
        _ = try await store.createVault(initial: sampleSnapshot(), passphrase: "old-pass")
        try await store.changePassphrase(to: "new-pass")
        await store.lock(flushFirst: false)

        do {
            _ = try await store.unlock(passphrase: "old-pass")
            XCTFail("旧密码应失效")
        } catch let error as VaultError {
            XCTAssertEqual(error.kind, .wrongCredential)
        }
        let snapshot = try await store.unlock(passphrase: "new-pass")
        XCTAssertEqual(snapshot.subscriptions.count, 1)
    }

    func testRollbackIsDetectedButStillOpens() async throws {
        let store = makeStore()
        _ = try await store.createVault(initial: sampleSnapshot(), passphrase: "pw")
        try await store.update { $0.settings.primaryCurrency = "USD" }
        try await store.flush()
        try await store.update { $0.settings.primaryCurrency = "EUR" }
        try await store.flush()

        let file = directory.appendingPathComponent("WSubscription.vault")
        let backup = directory.appendingPathComponent("WSubscription.vault.bak")
        // 用上一版覆盖当前文件，模拟「从旧备份恢复」
        try FileManager.default.removeItem(at: file)
        try FileManager.default.copyItem(at: backup, to: file)

        await store.lock(flushFirst: false)
        _ = try await store.unlock(passphrase: "pw")
        let detected = await store.detectedRollback
        XCTAssertTrue(detected)
    }

    func testMissingFileThrows() async throws {
        let store = makeStore()
        do {
            _ = try await store.unlock(passphrase: "pw")
            XCTFail("应当失败")
        } catch let error as VaultError {
            XCTAssertEqual(error.kind, .vaultNotFound)
        }
    }

    func testCorruptedFileThrows() async throws {
        let store = makeStore()
        _ = try await store.createVault(initial: sampleSnapshot(), passphrase: "pw")
        try Data("not a vault".utf8).write(to: directory.appendingPathComponent("WSubscription.vault"))
        await store.lock(flushFirst: false)
        do {
            _ = try await store.unlock(passphrase: "pw")
            XCTFail("应当失败")
        } catch let error as VaultError {
            XCTAssertEqual(error.kind, .corrupted)
        }
    }
}
