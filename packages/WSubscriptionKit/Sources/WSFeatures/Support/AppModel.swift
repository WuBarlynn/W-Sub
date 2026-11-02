#if os(iOS)
import Foundation
import SwiftUI
import WSCore
import WSCrypto
import WSVault

public enum AppTab: String, CaseIterable, Identifiable, Sendable {
    case dashboard, library, stats, settings
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .dashboard: return "概览"
        case .library: return "订阅"
        case .stats: return "统计"
        case .settings: return "设置"
        }
    }

    public var symbol: String {
        switch self {
        case .dashboard: return "square.grid.2x2.fill"
        case .library: return "list.bullet.rectangle.portrait.fill"
        case .stats: return "chart.bar.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

/// 应用状态机：引导 → 锁定 → 就绪。所有密钥相关操作都经它转发给 VaultStore。
@MainActor
public final class AppModel: ObservableObject {
    public enum Phase: Equatable {
        case launching
        case onboarding
        case locked
        case ready
    }

    @Published public private(set) var phase: Phase = .launching
    @Published public private(set) var snapshot: VaultSnapshot?
    @Published public private(set) var isBusy = false
    @Published public private(set) var flowError: String?
    @Published public private(set) var notice: String?
    @Published public private(set) var biometryKind: BiometricKeyManager.BiometryKind = .none
    @Published public private(set) var biometryRegistered = false
    @Published public private(set) var folderName = ""
    @Published public private(set) var detectedRollback = false

    @Published public private(set) var failedAttempts = 0
    @Published public private(set) var lockoutUntil: Date?

    @Published public var selectedTab: AppTab = .dashboard

    /// 外观与自动锁定这类「解锁前就要知道」的偏好，额外镜像到 UserDefaults。
    /// 数据本体仍只在加密文件里，这里不存任何敏感信息。
    @Published public var appearance: Appearance {
        didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) }
    }
    @Published public var lockTimeout: LockTimeout {
        didSet { defaults.set(lockTimeout.rawValue, forKey: Keys.lockTimeout) }
    }

    private var store: VaultStore?
    private let defaults = UserDefaults.standard
    private let bookmarks: VaultBookmarkStore
    private let biometrics: BiometricKeyManager
    private let reminders = ReminderScheduler()
    private var eventTask: Task<Void, Never>?
    private var backgroundedAt: Date?

    public init(bookmarks: VaultBookmarkStore = VaultBookmarkStore(),
                biometrics: BiometricKeyManager = BiometricKeyManager()) {
        self.bookmarks = bookmarks
        self.biometrics = biometrics
        self.biometryKind = biometrics.biometryKind()
        self.appearance = Appearance(rawValue: UserDefaults.standard.string(forKey: Keys.appearance) ?? "")
            ?? .system
        self.lockTimeout = LockTimeout(rawValue: UserDefaults.standard.string(forKey: Keys.lockTimeout) ?? "")
            ?? .thirtySeconds
    }

    // MARK: - 启动

    public func bootstrap() async {
        biometryKind = biometrics.biometryKind()

        #if DEBUG
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "-ws-tab"),
           index + 1 < ProcessInfo.processInfo.arguments.count,
           let tab = AppTab(rawValue: ProcessInfo.processInfo.arguments[index + 1]) {
            selectedTab = tab
        }
        if ProcessInfo.processInfo.arguments.contains("-ws-demo") {
            await startDemo()
            return
        }
        #endif

        guard let record = bookmarks.load() else {
            phase = .onboarding
            return
        }
        folderName = record.displayPath
        do {
            let access = try FolderAccess.from(bookmark: record.bookmark)
            guard access.probe() else {
                notice = "上次使用的文件夹已不可访问，请重新选择"
                phase = .onboarding
                return
            }
            let store = VaultStore(store: VaultFileStore(access: access, fileName: record.fileName))
            self.store = store
            guard await store.hasFile else {
                notice = "这个文件夹里还没有数据文件"
                phase = .onboarding
                return
            }
            biometryRegistered = (await store.headerSummary())?.hasBiometric ?? false
            subscribe(to: store)
            phase = .locked
        } catch {
            notice = AppModel.describe(error)
            phase = .onboarding
        }
    }

    // MARK: - 建库

    @discardableResult
    public func createVault(directory: URL,
                            passphrase: String,
                            enableBiometry: Bool) async throws -> String {
        isBusy = true
        defer { isBusy = false }
        flowError = nil

        let bookmark = try FolderAccess.bookmark(for: directory)
        let access = FolderAccess(url: directory, mode: .securityScoped)
        let store = VaultStore(store: VaultFileStore(access: access))
        self.store = store

        var publicKey: Data?
        if enableBiometry, biometryKind != .none {
            publicKey = try? biometrics.createKey()
        }

        let result = try await store.createVault(initial: VaultSnapshot(),
                                                 passphrase: passphrase,
                                                 biometricPublicKey: publicKey)
        bookmarks.save(VaultBookmarkStore.Record(bookmark: bookmark,
                                                 fileName: "WSubscription.vault",
                                                 displayPath: directory.lastPathComponent))
        folderName = directory.lastPathComponent
        biometryRegistered = publicKey != nil
        snapshot = result.snapshot
        subscribe(to: store)
        await finishUnlockSideEffects()
        return result.recoveryKey
    }

    // MARK: - 解锁

    public func unlock(passphrase: String) async {
        guard let store else { return }
        guard !isLockedOut else { return }
        isBusy = true
        flowError = nil
        defer { isBusy = false }

        do {
            snapshot = try await store.unlock(passphrase: passphrase)
            failedAttempts = 0
            lockoutUntil = nil
            detectedRollback = await store.detectedRollback
            phase = .ready
            await finishUnlockSideEffects()
        } catch {
            registerFailure(error)
        }
    }

    public func unlockWithBiometry() async {
        guard let store, biometryRegistered else { return }
        isBusy = true
        flowError = nil
        defer { isBusy = false }

        let manager = biometrics
        do {
            snapshot = try await store.unlockWithBiometry { ephemeral in
                try manager.sharedSecret(ephemeralPublicKey: ephemeral)
            }
            failedAttempts = 0
            detectedRollback = await store.detectedRollback
            phase = .ready
            await finishUnlockSideEffects()
        } catch {
            let vaultError = VaultStore.map(error)
            if vaultError.kind == .biometryUnavailable {
                biometryRegistered = false
                flowError = "Face ID 已失效（可能新增或删除了面容），请用密码解锁并在设置中重新启用"
            } else {
                flowError = AppModel.describe(vaultError)
            }
        }
    }

    public func unlockWithRecoveryKey(_ key: String) async {
        guard let store else { return }
        isBusy = true
        flowError = nil
        defer { isBusy = false }
        do {
            snapshot = try await store.unlockWithRecoveryKey(key)
            failedAttempts = 0
            lockoutUntil = nil
            phase = .ready
            await finishUnlockSideEffects()
        } catch {
            registerFailure(error)
        }
    }

    /// 引导流程最后一步：用户确认已保存恢复码后才进入主界面。
    public func completeOnboarding() {
        guard phase == .onboarding, snapshot != nil else { return }
        phase = .ready
    }

    public func lock() async {
        await store?.lock(flushFirst: true)
        snapshot = nil
        phase = .locked
        selectedTab = .dashboard
        flowError = nil
    }

    public var isLockedOut: Bool {
        guard let lockoutUntil else { return false }
        return lockoutUntil > Date()
    }

    private func registerFailure(_ error: Error) {
        let vaultError = VaultStore.map(error)
        if vaultError.kind == .wrongCredential {
            failedAttempts += 1
            if failedAttempts >= 3 {
                let delay = min(300, pow(2, Double(failedAttempts - 2)) * 2)
                lockoutUntil = Date().addingTimeInterval(delay)
            }
            let remaining = max(0, 5 - failedAttempts)
            flowError = remaining > 0
                ? "密码不正确，还可以尝试 \(remaining) 次"
                : "密码不正确"
        } else {
            flowError = AppModel.describe(vaultError)
        }
    }

    private func finishUnlockSideEffects() async {
        guard let snapshot else { return }
        // 以文件里的设置为准（多设备之间保持一致）
        if appearance != snapshot.settings.appearance { appearance = snapshot.settings.appearance }
        if lockTimeout != snapshot.settings.lockTimeout { lockTimeout = snapshot.settings.lockTimeout }
        await reminders.reschedule(for: snapshot)
    }

    // MARK: - 数据操作

    public func mutate(_ body: @Sendable (inout VaultSnapshot) throws -> Void) async {
        guard let store else { return }
        do {
            try await store.update(body)
            snapshot = await store.currentSnapshot
            if let snapshot {
                await reminders.reschedule(for: snapshot)
            }
        } catch {
            notice = AppModel.describe(error)
        }
    }

    public func save(_ subscription: Subscription) async {
        var updated = subscription
        updated.updatedAt = Date()
        if let store { updated.deviceID = store.deviceID }
        let record = updated
        await mutate { snapshot in
            snapshot.upsert(record)
        }
    }

    public func delete(_ subscription: Subscription) async {
        let deviceID = store?.deviceID ?? UUID()
        await mutate { snapshot in
            snapshot.removeSubscription(id: subscription.id, deviceID: deviceID)
        }
    }

    public func togglePause(_ subscription: Subscription) async {
        var updated = subscription
        updated.state = subscription.state == .paused ? .active : .paused
        await save(updated)
    }

    public func saveFromTemplate(_ template: SubscriptionTemplate, amount: Decimal) async {
        let money = Money(decimal: amount, currencyCode: snapshot?.settings.primaryCurrency ?? "CNY")
            ?? Money(minorUnits: 0, currencyCode: "CNY")
        let subscription = Subscription(name: template.name,
                                        vendor: template.vendor,
                                        categoryID: template.categoryID,
                                        price: money,
                                        cycle: template.defaultCycle,
                                        anchorDate: Date(),
                                        reminderOffsets: snapshot?.settings.defaultReminderOffsets ?? [3],
                                        symbolName: template.symbol,
                                        tintHex: template.hex,
                                        brandID: template.brand)
        await save(subscription)
    }

    public func flush() async {
        do { try await store?.flush() } catch { notice = AppModel.describe(error) }
    }

    // MARK: - 安全设置

    public func changePassphrase(to newValue: String) async -> Bool {
        guard let store else { return false }
        do {
            try await store.changePassphrase(to: newValue)
            snapshot = await store.currentSnapshot
            notice = "密码已更新，旧密码立即失效"
            return true
        } catch {
            notice = AppModel.describe(error)
            return false
        }
    }

    public func setBiometry(_ enabled: Bool) async {
        guard let store else { return }
        do {
            if enabled {
                let key = try biometrics.createKey()
                try await store.enableBiometry(publicKey: key)
                biometryRegistered = true
            } else {
                try await store.disableBiometry()
                biometrics.deleteKey()
                biometryRegistered = false
            }
            snapshot = await store.currentSnapshot
        } catch {
            notice = AppModel.describe(error)
        }
    }

    public func regenerateRecoveryKey() async -> String? {
        guard let store else { return nil }
        do {
            let code = try await store.regenerateRecoveryKey()
            return code
        } catch {
            notice = AppModel.describe(error)
            return nil
        }
    }

    public func updateSettings(_ body: @Sendable (inout AppSettings) -> Void) async {
        await mutate { snapshot in body(&snapshot.settings) }
    }

    // MARK: - 生命周期

    public func handleBackground() {
        backgroundedAt = Date()
        guard phase == .ready else { return }
        Task { await flush() }
    }

    public func handleActive() {
        defer { backgroundedAt = nil }
        guard phase == .ready, let backgroundedAt else { return }
        let timeout = lockTimeout.seconds
        if Date().timeIntervalSince(backgroundedAt) >= timeout {
            Task { await lock() }
        }
    }

    // MARK: - 事件订阅

    private func subscribe(to store: VaultStore) {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            for await event in await store.events() {
                guard let self else { return }
                switch event {
                case .changed(let snapshot):
                    self.snapshot = snapshot
                case .saved:
                    break
                case .locked:
                    if self.phase == .ready { self.phase = .locked }
                case .unlocked:
                    break
                case .warning(let message):
                    self.notice = message
                }
            }
        }
    }

    // MARK: - 错误文案

    public static func describe(_ error: Error) -> String {
        if let vault = error as? VaultError {
            if let suggestion = vault.recoverySuggestion {
                return "\(vault.errorDescription ?? "出错了")。\(suggestion)"
            }
            return vault.errorDescription ?? "出错了"
        }
        if let crypto = error as? CryptoError {
            return crypto.errorDescription ?? "加密操作失败"
        }
        return error.localizedDescription
    }

    private enum Keys {
        static let appearance = "ws.pref.appearance.v1"
        static let lockTimeout = "ws.pref.locktimeout.v1"
    }

    public func clearMessages() {
        flowError = nil
        notice = nil
    }

    // MARK: - 演示数据（仅 Debug，便于在没有真机 Face ID 的环境里检查界面）

    #if DEBUG
    private func startDemo() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WSDemoVault", isDirectory: true)
        // 每次都以最新示例数据重建，避免旧文件干扰预览
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let access = FolderAccess(url: directory)
        let store = VaultStore(store: VaultFileStore(access: access),
                              configuration: .init(fileName: "WSubscription.vault",
                                                   autosaveDelay: .milliseconds(400),
                                                   kdf: .testing))
        self.store = store
        folderName = "WSDemoVault"

        if await store.hasFile {
            snapshot = try? await store.unlock(passphrase: "demo-pass")
        } else {
            let result = try? await store.createVault(initial: DemoData.snapshot(), passphrase: "demo-pass")
            snapshot = result?.snapshot
        }
        subscribe(to: store)
        phase = snapshot == nil ? .locked : .ready

        if ProcessInfo.processInfo.arguments.contains("-ws-lock") {
            biometryRegistered = false
            await lock()
        }
    }
    #endif
}
#endif
