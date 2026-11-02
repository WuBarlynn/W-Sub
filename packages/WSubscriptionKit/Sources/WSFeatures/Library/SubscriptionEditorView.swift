#if os(iOS)
import SwiftUI
import WSDesignSystem
import WSCore

struct SubscriptionEditorView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private let original: Subscription?
    private let currency: String

    @State private var draft: Subscription
    @State private var amountText: String
    @State private var cycleChoice: CycleChoice
    @State private var customMonths: Int
    @State private var reminderDays: Int
    @State private var showIconPicker = false
    @State private var errorText: String?

    init(subscription: Subscription? = nil,
         template: SubscriptionTemplate? = nil,
         currency: String = "CNY") {
        self.original = subscription
        self.currency = currency

        if let subscription {
            _draft = State(initialValue: subscription)
            _amountText = State(initialValue: subscription.price.plainString)
            let (choice, months) = CycleChoice.from(subscription.cycle)
            _cycleChoice = State(initialValue: choice)
            _customMonths = State(initialValue: months)
            _reminderDays = State(initialValue: subscription.reminderOffsets.first ?? 3)
        } else if let template {
            _draft = State(initialValue: Subscription(name: template.name,
                                                      vendor: template.vendor,
                                                      categoryID: template.categoryID,
                                                      price: .zero(currency),
                                                      cycle: template.defaultCycle,
                                                      symbolName: template.symbol,
                                                      tintHex: template.hex,
                                                      brandID: template.brand))
            _amountText = State(initialValue: "")
            let (choice, months) = CycleChoice.from(template.defaultCycle)
            _cycleChoice = State(initialValue: choice)
            _customMonths = State(initialValue: months)
            _reminderDays = State(initialValue: 3)
        } else {
            _draft = State(initialValue: Subscription(name: "",
                                                      categoryID: "other",
                                                      price: .zero(currency)))
            _amountText = State(initialValue: "")
            _cycleChoice = State(initialValue: .monthly)
            _customMonths = State(initialValue: 3)
            _reminderDays = State(initialValue: 3)
        }
    }

    private var categories: [WSCore.Category] {
        model.snapshot?.sortedCategories ?? Category.builtIns
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        IconTile(brand: draft.brandID,
                                 symbol: draft.symbolName,
                                 hex: draft.tintHex,
                                 name: draft.name.isEmpty ? "?" : draft.name,
                                 customID: draft.customIconID,
                                 size: 56)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(draft.name.isEmpty ? "未命名订阅" : draft.name)
                                .font(.system(size: 16, weight: .semibold))
                            Button("更换图标") { showIconPicker = true }
                                .font(.system(size: 13))
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)

                    TextField("名称", text: $draft.name)
                    TextField("服务方（可选）", text: $draft.vendor)

                    HStack(spacing: 8) {
                        Text("金额")
                        Spacer()
                        TextField("0", text: $amountText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 150)
                        Text(currency)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }

                    Picker("周期", selection: $cycleChoice) {
                        ForEach(CycleChoice.allCases) { choice in
                            Text(choice.title).tag(choice)
                        }
                    }
                    if cycleChoice == .customMonths {
                        Stepper("每 \(customMonths) 个月扣款", value: $customMonths, in: 2...24)
                    }
                    DatePicker("首次扣款", selection: $draft.anchorDate, displayedComponents: .date)
                } header: {
                    Text("基本信息")
                }

                Section {
                    Picker("分类", selection: $draft.categoryID) {
                        ForEach(categories) { category in
                            Label(category.name, systemImage: category.symbolName).tag(category.id)
                        }
                    }
                } header: {
                    Text("分类")
                }

                Section {
                    Picker("提前提醒", selection: $reminderDays) {
                        Text("当天").tag(0)
                        Text("提前 1 天").tag(1)
                        Text("提前 3 天").tag(3)
                        Text("提前 7 天").tag(7)
                        Text("提前 14 天").tag(14)
                    }
                    Toggle("自动续费", isOn: $draft.autoRenew)
                } header: {
                    Text("提醒")
                }

                Section {
                    Toggle("正在免费试用", isOn: $draft.isTrial.animation(.easeInOut(duration: 0.2)))
                    if draft.isTrial {
                        DatePicker("试用结束", selection: Binding(
                            get: { draft.trialEndDate ?? draft.anchorDate },
                            set: { draft.trialEndDate = $0 }
                        ), displayedComponents: .date)
                    }
                } header: {
                    Text("试用")
                } footer: {
                    if draft.isTrial {
                        Text("试用期内不计入月度支出，结束时会按正常价格提醒。")
                    }
                }

                Section {
                    TextField("备注", text: $draft.note, axis: .vertical)
                        .lineLimit(2...5)
                } header: {
                    Text("备注")
                }

                if let errorText {
                    Section {
                        Text(errorText)
                            .font(.system(size: 12))
                            .foregroundStyle(Color(hex: "#C4320A"))
                    }
                }
            }
            .navigationTitle(original == nil ? "添加订阅" : "编辑订阅")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .fontWeight(.semibold)
                }
            }
            .sheet(isPresented: $showIconPicker) {
                IconPickerView(currentBrand: draft.brandID, currentCustom: draft.customIconID) { brand, custom in
                    draft.brandID = brand
                    draft.customIconID = custom
                    if let brand, let option = BrandCatalog.all.first(where: { $0.id == brand }) {
                        draft.tintHex = option.hex
                    }
                }
            }
            .onChange(of: draft.categoryID) { _, newValue in
                guard original == nil, draft.brandID == nil, draft.customIconID == nil else { return }
                if let category = model.snapshot?.category(id: newValue) {
                    draft.tintHex = category.tintHex
                    draft.symbolName = category.symbolName
                }
            }
        }
    }

    private func save() {
        let trimmed = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorText = "给这条订阅起个名字"
            return
        }
        let normalized = amountText.replacingOccurrences(of: ",", with: ".")
        let decimal = Decimal(string: normalized) ?? 0
        guard decimal >= 0 else {
            errorText = "金额需要是正数"
            return
        }
        guard let money = Money(decimal: decimal, currencyCode: currency) else {
            errorText = "金额超出范围"
            return
        }

        var result = draft
        result.name = trimmed
        result.price = money
        result.cycle = cycleChoice.toCycle(customMonths: customMonths)
        result.reminderOffsets = [reminderDays]
        if !result.isTrial { result.trialEndDate = nil }
        if result.symbolName.isEmpty { result.symbolName = "creditcard.fill" }

        Task {
            await model.save(result)
            dismiss()
        }
    }
}

enum CycleChoice: String, CaseIterable, Identifiable {
    case weekly, biweekly, monthly, quarterly, semiAnnually, annually, customMonths, oneTime

    var id: String { rawValue }

    var title: String {
        switch self {
        case .weekly: return "每周"
        case .biweekly: return "每两周"
        case .monthly: return "每月"
        case .quarterly: return "每季度"
        case .semiAnnually: return "每半年"
        case .annually: return "每年"
        case .customMonths: return "自定义月数"
        case .oneTime: return "一次性买断"
        }
    }

    func toCycle(customMonths: Int) -> BillingCycle {
        switch self {
        case .weekly: return .weekly
        case .biweekly: return .biweekly
        case .monthly: return .monthly
        case .quarterly: return .quarterly
        case .semiAnnually: return .semiAnnually
        case .annually: return .annually
        case .customMonths: return .customMonths(max(2, customMonths))
        case .oneTime: return .oneTime
        }
    }

    static func from(_ cycle: BillingCycle) -> (CycleChoice, Int) {
        switch cycle {
        case .weekly: return (.weekly, 3)
        case .biweekly: return (.biweekly, 3)
        case .monthly: return (.monthly, 3)
        case .quarterly: return (.quarterly, 3)
        case .semiAnnually: return (.semiAnnually, 3)
        case .annually: return (.annually, 3)
        case .customMonths(let months): return (.customMonths, months)
        case .customDays: return (.monthly, 3)
        case .oneTime: return (.oneTime, 3)
        }
    }
}
#endif
