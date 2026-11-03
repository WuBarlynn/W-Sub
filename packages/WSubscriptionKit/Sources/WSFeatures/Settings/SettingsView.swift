#if os(iOS)
import SwiftUI
import UserNotifications
import UniformTypeIdentifiers
import WSDesignSystem
import WSCore

public struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    @State private var showChangePassphrase = false
    @State private var showRecovery = false
    @State private var recoveryCode: String?
    @State private var confirmDisableBiometry = false
    @State private var backupURL: URL?
    @State private var csvURL: URL?
    @State private var notificationsOn = false
    @State private var iconCount = IconStore.shared.count()
    @State private var confirmCleanIcons = false
    @State private var confirmImportBackup = false
    @State private var showImportBackup = false
    @State private var rateDrafts: [String: String] = [:]

    private static let vaultType: [UTType] = {
        [UTType(filenameExtension: "vault") ?? .data]
    }()

    public init() {}

    private var snapshot: VaultSnapshot { model.snapshot ?? VaultSnapshot() }

    /// 用到的外币（主币种之外），需要给它们设汇率才能真正加总
    private var foreignCurrencies: [String] {
        let primary = snapshot.settings.primaryCurrency
        let codes = Set(snapshot.subscriptions.map { $0.price.currencyCode })
        return codes.filter { $0 != primary }.sorted()
    }

    private func rateDraft(_ code: String) -> Binding<String> {
        Binding(
            get: {
                rateDrafts[code]
                    ?? NSDecimalNumber(decimal: snapshot.settings.manualRates[code] ?? 1).stringValue
            },
            set: { text in
                rateDrafts[code] = text
                guard let value = Decimal(string: text), value > 0 else { return }
                Task { await model.updateSettings { $0.manualRates[code] = value } }
            }
        )
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("安全") {
                    Button { showChangePassphrase = true } label: {
                        row("修改密码", "key.fill")
                    }
                    .buttonStyle(.plain)

                    Toggle(isOn: Binding(
                        get: { model.biometryRegistered },
                        set: { newValue in
                            if newValue { Task { await model.setBiometry(true) } }
                            else { confirmDisableBiometry = true }
                        }
                    )) {
                        row(model.biometryKind == .faceID ? "Face ID 解锁" : "生物识别解锁",
                            model.biometryKind == .faceID ? "faceid" : "touchid")
                    }
                    .disabled(model.biometryKind == .none)

                    Picker(selection: Binding(
                        get: { model.lockTimeout },
                        set: { newValue in
                            model.lockTimeout = newValue
                            Task { await model.updateSettings { $0.lockTimeout = newValue } }
                        }
                    )) {
                        ForEach(LockTimeout.allCases) { timeout in
                            Text(timeout.displayName).tag(timeout)
                        }
                    } label: {
                        row("自动锁定", "clock.fill")
                    }

                    Button { Task { await model.lock() } } label: {
                        row("立即锁定", "lock.fill", tint: Color(hex: "#D9363E"))
                    }
                    .buttonStyle(.plain)
                }

                Section("数据") {
                    Button {
                        Task {
                            backupURL = nil
                            backupURL = await model.exportEncryptedBackup()
                        }
                    } label: {
                        row("导出加密备份", "lock.doc")
                    }
                    .buttonStyle(.plain)

                    Button { confirmImportBackup = true } label: {
                        row("导入备份", "square.and.arrow.down")
                    }
                    .buttonStyle(.plain)

                    Button { Task { await model.flush() } } label: {
                        row("立即保存", "checkmark.circle.fill")
                    }
                    .buttonStyle(.plain)

                    Button {
                        Task {
                            recoveryCode = await model.regenerateRecoveryKey()
                            showRecovery = recoveryCode != nil
                        }
                    } label: {
                        row("重新生成恢复码", "number.square.fill")
                    }
                    .buttonStyle(.plain)

                    Button { csvURL = makeCSV() } label: {
                        row("导出 CSV（明文）", "square.and.arrow.up")
                    }
                    .buttonStyle(.plain)

                    if iconCount > 0 {
                        Button { confirmCleanIcons = true } label: {
                            LabeledContent {
                                Text("\(iconCount)").foregroundStyle(.secondary)
                            } label: {
                                row("清理自定义图标", "photo.on.rectangle")
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                Section("记账") {
                    Picker("主币种", selection: Binding(
                        get: { snapshot.settings.primaryCurrency },
                        set: { code in
                            Task { await model.updateSettings { $0.primaryCurrency = code } }
                        }
                    )) {
                        ForEach(CurrencyCatalog.common) { item in
                            Text("\(item.symbol) \(item.code)").tag(item.code)
                        }
                    }

                    if foreignCurrencies.isEmpty {
                        Text("没有外币订阅")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(foreignCurrencies, id: \.self) { code in
                            HStack(spacing: 8) {
                                Text("1 \(code) =")
                                    .font(.system(size: 14))
                                Spacer(minLength: 8)
                                TextField("1", text: rateDraft(code))
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                    .frame(maxWidth: 90)
                                Text(snapshot.settings.primaryCurrency)
                                    .font(.system(size: 14))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("外观") {
                    Picker("主题", selection: Binding(
                        get: { model.appearance },
                        set: { newValue in
                            model.appearance = newValue
                            Task { await model.updateSettings { $0.appearance = newValue } }
                        }
                    )) {
                        ForEach(Appearance.allCases) { item in
                            Text(item.displayName).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)

                    Toggle(isOn: Binding(
                        get: { notificationsOn },
                        set: { newValue in
                            guard newValue else { return }
                            Task { notificationsOn = await ReminderScheduler().requestAuthorization() }
                        }
                    )) {
                        row("续费提醒", "bell.badge.fill")
                    }
                }

                Section("关于") {
                    LabeledContent("版本", value: "1.0")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.wsPage)
            .navigationTitle("设置")
            .sheet(isPresented: $showChangePassphrase) { ChangePassphraseView() }
            .sheet(isPresented: $showRecovery) { RecoveryCodeSheet(code: recoveryCode ?? "") }
            .sheet(isPresented: Binding(get: { backupURL != nil },
                                        set: { if !$0 { backupURL = nil } })) {
                if let backupURL { BackupExportSheet(url: backupURL) }
            }
            .sheet(isPresented: Binding(get: { csvURL != nil },
                                        set: { if !$0 { csvURL = nil } })) {
                if let csvURL { CSVExportSheet(url: csvURL) }
            }
            .fileImporter(isPresented: $showImportBackup,
                          allowedContentTypes: Self.vaultType,
                          allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    Task { await model.importVault(from: url) }
                case .failure:
                    break
                }
            }
            .onAppear {
                iconCount = IconStore.shared.count()
                Task {
                    let settings = await UNUserNotificationCenter.current().notificationSettings()
                    notificationsOn = settings.authorizationStatus == .authorized
                }
            }
            .confirmationDialog("关闭生物识别解锁？", isPresented: $confirmDisableBiometry, titleVisibility: .visible) {
                Button("关闭", role: .destructive) { Task { await model.setBiometry(false) } }
                Button("取消", role: .cancel) {}
            }
            .confirmationDialog("删除全部自定义图标？", isPresented: $confirmCleanIcons, titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    IconStore.shared.removeAll()
                    iconCount = 0
                }
                Button("取消", role: .cancel) {}
            }
            .confirmationDialog("导入备份会替换当前所有数据", isPresented: $confirmImportBackup, titleVisibility: .visible) {
                Button("选择备份文件", role: .destructive) { showImportBackup = true }
                Button("取消", role: .cancel) {}
            } message: {
                Text("导入后需要用那份备份的密码解锁。")
            }
        }
    }

    private func row(_ title: String, _ symbol: String, tint: Color = .secondary) -> some View {
        Label {
            Text(title).foregroundStyle(.primary)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
    }

    private func makeCSV() -> URL? {
        guard let snapshot = model.snapshot else { return nil }
        var lines = ["名称,分类,金额,币种,周期,下次扣款,状态,备注"]
        for sub in snapshot.subscriptions {
            lines.append([
                sub.name.replacingOccurrences(of: ",", with: "，"),
                snapshot.category(id: sub.categoryID).name,
                "\(sub.price.decimal)",
                sub.price.currencyCode,
                sub.cycle.displayName,
                sub.nextBillingDate().map { WSDate.full($0) } ?? "",
                sub.state.displayName,
                sub.note.replacingOccurrences(of: ",", with: "，")
            ].joined(separator: ","))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WSub-订阅清单.csv")
        do {
            try lines.joined(separator: "\n").data(using: .utf8)?.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}

struct ChangePassphraseView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var first = ""
    @State private var second = ""
    @State private var error: String?
    @State private var isWorking = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("新密码", text: $first)
                        .textContentType(.newPassword)
                    SecureField("再输入一次", text: $second)
                        .textContentType(.newPassword)
                }
                if let error {
                    Section {
                        Text(error).font(.system(size: 12)).foregroundStyle(Color(hex: "#C4320A"))
                    }
                }
            }
            .navigationTitle("修改密码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isWorking ? "保存中…" : "保存") {
                        Task { await submit() }
                    }
                    .disabled(first.count < 8 || first != second || isWorking)
                }
            }
        }
    }

    private func submit() async {
        isWorking = true
        defer { isWorking = false }
        let ok = await model.changePassphrase(to: first)
        if ok { dismiss() } else { error = model.notice ?? "修改失败" }
    }
}

struct RecoveryCodeSheet: View {
    let code: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text(code)
                    .font(.system(size: 17, weight: .medium, design: .monospaced))
                    .lineSpacing(7)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(Color.wsCard, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.wsHairline, lineWidth: 0.5)
                    }

                Button {
                    UIPasteboard.general.string = code
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Spacer()
            }
            .padding(20)
            .navigationTitle("恢复码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

/// 加密备份导出：文件本身就是加密的，密码不变
struct BackupExportSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Text("加密备份已就绪")
                    .font(.system(size: 17, weight: .semibold))
                Text("文件保持加密，用当前密码解锁。可存到「文件」或 iCloud。")
                    .font(.wsMeta)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                ShareLink(item: url) {
                    Label("分享 / 存储到「文件」", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal, 24)

                Button("取消") { dismiss() }
                    .font(.system(size: 14))
            }
            .padding(.top, 28)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

struct CSVExportSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Text("CSV 是明文")
                    .font(.system(size: 17, weight: .semibold))
                Text("导出后不再受加密保护。")
                    .font(.wsMeta)
                    .foregroundStyle(.secondary)

                ShareLink(item: url) {
                    Label("导出", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal, 24)

                Button("取消") { dismiss() }
                    .font(.system(size: 14))
            }
            .padding(.top, 28)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
#endif
