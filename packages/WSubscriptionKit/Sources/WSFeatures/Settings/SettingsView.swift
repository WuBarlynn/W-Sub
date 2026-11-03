#if os(iOS)
import SwiftUI
import UserNotifications
import UniformTypeIdentifiers
import WSDesignSystem
import WSCore

public struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    @State private var backupURL: URL?
    @State private var csvURL: URL?
    @State private var notificationsOn = false
    @State private var iconCount = IconStore.shared.count()
    @State private var confirmCleanIcons = false
    @State private var confirmImport = false
    @State private var showImport = false
    @State private var rateDrafts: [String: String] = [:]

    private static let jsonType: [UTType] = {
        [UTType.json, UTType(filenameExtension: "json") ?? .data]
    }()

    public init() {}

    private var snapshot: VaultSnapshot { model.snapshot ?? VaultSnapshot() }

    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(v)（\(b)）"
    }

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
                Section {
                    LabeledContent {
                        Text("App 内部「文件」可见")
                            .foregroundStyle(.secondary)
                    } label: {
                        row("数据位置", "folder.fill")
                    }
                    Text("数据保存在 App 自己的文件夹里，可在系统「文件」App 的「我的 iPhone > W Sub」中打开。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Section("数据") {
                    Button {
                        Task {
                            backupURL = nil
                            backupURL = await model.exportJSON()
                        }
                    } label: {
                        row("导出数据", "square.and.arrow.up")
                    }
                    .buttonStyle(WSPressButtonStyle())

                    Button { confirmImport = true } label: {
                        row("导入数据", "square.and.arrow.down")
                    }
                    .buttonStyle(WSPressButtonStyle())

                    Button { csvURL = makeCSV() } label: {
                        row("导出 CSV", "tablecells")
                    }
                    .buttonStyle(WSPressButtonStyle())

                    if iconCount > 0 {
                        Button { confirmCleanIcons = true } label: {
                            LabeledContent {
                                Text("\(iconCount)").foregroundStyle(.secondary)
                            } label: {
                                row("清理自定义图标", "photo.on.rectangle")
                            }
                        }
                        .buttonStyle(WSPressButtonStyle())
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
                    LabeledContent("版本", value: version)
                    LabeledContent("作者", value: "WuBarlynn")
                    Button {
                        if let url = URL(string: "https://github.com/WuBarlynn/W-Sub") {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        HStack {
                            row("GitHub 仓库", "link")
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(WSPressButtonStyle())
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.wsPage)
            .navigationTitle("设置")
            .sheet(isPresented: Binding(get: { backupURL != nil },
                                        set: { if !$0 { backupURL = nil } })) {
                if let backupURL { ExportSheet(url: backupURL) }
            }
            .sheet(isPresented: Binding(get: { csvURL != nil },
                                        set: { if !$0 { csvURL = nil } })) {
                if let csvURL { CSVExportSheet(url: csvURL) }
            }
            .fileImporter(isPresented: $showImport,
                          allowedContentTypes: Self.jsonType,
                          allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    Task { await model.importJSON(from: url) }
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
            .confirmationDialog("删除全部自定义图标？", isPresented: $confirmCleanIcons, titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    IconStore.shared.removeAll()
                    iconCount = 0
                }
                Button("取消", role: .cancel) {}
            }
            .confirmationDialog("导入数据会替换当前所有订阅", isPresented: $confirmImport, titleVisibility: .visible) {
                Button("选择文件", role: .destructive) { showImport = true }
                Button("取消", role: .cancel) {}
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

/// 明文数据导出：JSON 文件，可读、可迁移
struct ExportSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Text("数据已就绪")
                    .font(.system(size: 17, weight: .semibold))
                Text("JSON 格式，可存到「文件」或 iCloud，之后可随时导入。")
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
                Text("可用 Numbers / Excel 打开。")
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
