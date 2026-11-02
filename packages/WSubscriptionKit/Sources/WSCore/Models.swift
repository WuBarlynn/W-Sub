import Foundation

// MARK: - 分类

public struct Category: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var symbolName: String
    public var tintHex: String
    /// 内置品牌图标（Assets 里的名字），nil 时回退到 symbolName
    public var brandID: String?
    /// 用户自定义图标的文件名（存于 App Support/Icons），优先级最高
    public var customIconID: UUID?
    public var sortIndex: Int
    public var isBuiltIn: Bool
    public var isHidden: Bool

    public init(id: String, name: String, symbolName: String, tintHex: String,
                sortIndex: Int, isBuiltIn: Bool = true, isHidden: Bool = false) {
        self.id = id
        self.name = name
        self.symbolName = symbolName
        self.tintHex = tintHex
        self.sortIndex = sortIndex
        self.isBuiltIn = isBuiltIn
        self.isHidden = isHidden
    }

    public static let builtIns: [Category] = [
        Category(id: "streaming", name: "流媒体", symbolName: "play.tv.fill", tintHex: "#E5484D", sortIndex: 0),
        Category(id: "music", name: "音乐", symbolName: "music.note", tintHex: "#30A46C", sortIndex: 1),
        Category(id: "software", name: "软件会员", symbolName: "app.badge.fill", tintHex: "#3E63DD", sortIndex: 2),
        Category(id: "cloud", name: "云服务", symbolName: "cloud.fill", tintHex: "#0EA5C6", sortIndex: 3),
        Category(id: "ai", name: "AI 工具", symbolName: "sparkles", tintHex: "#8E4EC6", sortIndex: 4),
        Category(id: "fitness", name: "健身健康", symbolName: "figure.run", tintHex: "#F76B15", sortIndex: 5),
        Category(id: "news", name: "新闻阅读", symbolName: "newspaper.fill", tintHex: "#8D6E4A", sortIndex: 6),
        Category(id: "games", name: "游戏娱乐", symbolName: "gamecontroller.fill", tintHex: "#D6409F", sortIndex: 7),
        Category(id: "education", name: "学习教育", symbolName: "graduationcap.fill", tintHex: "#C2410C", sortIndex: 8),
        Category(id: "life", name: "生活会员", symbolName: "bag.fill", tintHex: "#DB2777", sortIndex: 9),
        Category(id: "security", name: "安全网络", symbolName: "lock.shield.fill", tintHex: "#0E7490", sortIndex: 10),
        Category(id: "other", name: "其他", symbolName: "square.grid.2x2.fill", tintHex: "#7C7C86", sortIndex: 11)
    ]

    public static let fallback = builtIns.last!
}

// MARK: - 价格变更（涨价记录）

public struct PriceChange: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var date: Date
    public var from: Money?
    public var to: Money
    public var note: String?

    public init(id: UUID = UUID(), date: Date, from: Money?, to: Money, note: String? = nil) {
        self.id = id
        self.date = date
        self.from = from
        self.to = to
        self.note = note
    }
}

// MARK: - 订阅

public enum SubscriptionState: String, Codable, Hashable, Sendable, CaseIterable {
    case active
    case paused
    case ended

    public var displayName: String {
        switch self {
        case .active: return "进行中"
        case .paused: return "已暂停"
        case .ended: return "已结束"
        }
    }
}

public struct Subscription: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var vendor: String
    public var categoryID: String
    public var price: Money
    public var cycle: BillingCycle
    /// 首次扣款日：后续所有扣款日由它与周期推导，保证不漂移。
    public var anchorDate: Date
    public var state: SubscriptionState
    public var isTrial: Bool
    public var trialEndDate: Date?
    public var endDate: Date?
    public var autoRenew: Bool
    public var reminderOffsets: [Int]
    public var symbolName: String
    public var tintHex: String
    /// 内置品牌图标（Assets 里的名字），nil 时回退到 symbolName
    public var brandID: String?
    /// 用户自定义图标的文件名（存于 App Support/Icons），优先级最高
    public var customIconID: UUID?
    public var note: String
    public var tags: [String]
    public var priceHistory: [PriceChange]
    public var createdAt: Date
    public var updatedAt: Date
    public var deviceID: UUID

    public init(id: UUID = UUID(),
                name: String,
                vendor: String = "",
                categoryID: String,
                price: Money,
                cycle: BillingCycle = .monthly,
                anchorDate: Date = Date(),
                state: SubscriptionState = .active,
                isTrial: Bool = false,
                trialEndDate: Date? = nil,
                endDate: Date? = nil,
                autoRenew: Bool = true,
                reminderOffsets: [Int] = [3],
                symbolName: String = "creditcard.fill",
                tintHex: String = "#7C7C86",
                brandID: String? = nil,
                customIconID: UUID? = nil,
                note: String = "",
                tags: [String] = [],
                priceHistory: [PriceChange] = [],
                createdAt: Date = Date(),
                updatedAt: Date = Date(),
                deviceID: UUID = UUID()) {
        self.id = id
        self.name = name
        self.vendor = vendor
        self.categoryID = categoryID
        self.price = price
        self.cycle = cycle
        self.anchorDate = anchorDate
        self.state = state
        self.isTrial = isTrial
        self.trialEndDate = trialEndDate
        self.endDate = endDate
        self.autoRenew = autoRenew
        self.reminderOffsets = reminderOffsets
        self.symbolName = symbolName
        self.tintHex = tintHex
        self.brandID = brandID
        self.customIconID = customIconID
        self.note = note
        self.tags = tags
        self.priceHistory = priceHistory
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deviceID = deviceID
    }

    // MARK: 派生值（一律现算，不写库，避免不一致）

    public func nextBillingDate(after reference: Date = Date(), calendar: Calendar = .ws) -> Date? {
        guard state == .active else { return nil }
        if isTrial, let trialEndDate { return calendar.startOfDay(for: trialEndDate) }
        let next = cycle.nextDate(after: reference, anchor: anchorDate, calendar: calendar)
        if let endDate, let next, next > calendar.startOfDay(for: endDate) { return nil }
        return next
    }

    public func daysUntilNextBilling(from now: Date = Date(), calendar: Calendar = .ws) -> Int? {
        guard let next = nextBillingDate(after: now, calendar: calendar) else { return nil }
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: next).day
    }

    public var monthlyEquivalent: Money { cycle.monthlyEquivalent(of: price) }
    public var annualEquivalent: Money { cycle.annualEquivalent(of: price) }

    /// 每天花多少（用于「一杯咖啡钱」式表达）。
    public var dailyEquivalent: Money {
        price.multiplied(by: Decimal(1) / Decimal(30)).rounded()
    }

    public var isBillable: Bool { state == .active && !isTrial }

    public var trialDaysRemaining: Int? {
        guard isTrial, let trialEndDate else { return nil }
        return Calendar.ws.dateComponents([.day], from: Calendar.ws.startOfDay(for: Date()),
                                          to: Calendar.ws.startOfDay(for: trialEndDate)).day
    }

    /// 上一次已经发生的扣款日。用于账单卡上「上次扣款」这一栏。
    /// 往回找 25 个月，覆盖到最长的年付周期；买断只在建账日当天算一次。
    public func lastBillingDate(before reference: Date = Date(),
                                calendar: Calendar = .ws) -> Date? {
        let today = calendar.startOfDay(for: reference)
        if cycle.isOneTime {
            return anchorDate <= today ? calendar.startOfDay(for: anchorDate) : nil
        }
        guard let start = calendar.date(byAdding: .month, value: -25, to: today) else { return nil }
        let interval = DateInterval(start: start, end: today.addingTimeInterval(1))
        return cycle.dates(in: interval, anchor: anchorDate, calendar: calendar).last
    }

    public var lastPriceIncrease: PriceChange? {
        priceHistory.last(where: { $0.from != nil && $0.to.minorUnits > ($0.from?.minorUnits ?? 0) })
    }
}

// MARK: - 用户自建模板

public struct UserTemplate: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var vendor: String
    public var categoryID: String
    public var symbolName: String
    public var tintHex: String
    /// 内置品牌图标（Assets 里的名字），nil 时回退到 symbolName
    public var brandID: String?
    /// 用户自定义图标的文件名（存于 App Support/Icons），优先级最高
    public var customIconID: UUID?
    public var cycle: BillingCycle
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, vendor: String = "", categoryID: String,
                symbolName: String, tintHex: String, cycle: BillingCycle, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.vendor = vendor
        self.categoryID = categoryID
        self.symbolName = symbolName
        self.tintHex = tintHex
        self.cycle = cycle
        self.createdAt = createdAt
    }
}

// MARK: - 删除墓碑（合并用）

public struct Tombstone: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var deletedAt: Date
    public var deviceID: UUID

    public init(id: UUID, deletedAt: Date = Date(), deviceID: UUID) {
        self.id = id
        self.deletedAt = deletedAt
        self.deviceID = deviceID
    }
}

// MARK: - 设置

public enum LockTimeout: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case immediate
    case thirtySeconds
    case oneMinute
    case fiveMinutes

    public var id: String { rawValue }

    public var seconds: TimeInterval {
        switch self {
        case .immediate: return 0
        case .thirtySeconds: return 30
        case .oneMinute: return 60
        case .fiveMinutes: return 300
        }
    }

    public var displayName: String {
        switch self {
        case .immediate: return "立即"
        case .thirtySeconds: return "30 秒后"
        case .oneMinute: return "1 分钟后"
        case .fiveMinutes: return "5 分钟后"
        }
    }
}

public enum Appearance: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case system, light, dark
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }
}

public struct AppSettings: Codable, Hashable, Sendable {
    public var primaryCurrency: String
    public var monthlyBudgetMinor: Int64?
    public var lockTimeout: LockTimeout
    public var biometryEnabled: Bool
    public var defaultReminderOffsets: [Int]
    public var appearance: Appearance
    public var reduceGlassMotion: Bool
    public var manualRates: [String: Decimal]

    public init(primaryCurrency: String = "CNY",
                monthlyBudgetMinor: Int64? = nil,
                lockTimeout: LockTimeout = .thirtySeconds,
                biometryEnabled: Bool = false,
                defaultReminderOffsets: [Int] = [3],
                appearance: Appearance = .system,
                reduceGlassMotion: Bool = false,
                manualRates: [String: Decimal] = [:]) {
        self.primaryCurrency = primaryCurrency
        self.monthlyBudgetMinor = monthlyBudgetMinor
        self.lockTimeout = lockTimeout
        self.biometryEnabled = biometryEnabled
        self.defaultReminderOffsets = defaultReminderOffsets
        self.appearance = appearance
        self.reduceGlassMotion = reduceGlassMotion
        self.manualRates = manualRates
    }

    public var monthlyBudget: Money? {
        guard let monthlyBudgetMinor else { return nil }
        return Money(minorUnits: monthlyBudgetMinor, currencyCode: primaryCurrency)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        primaryCurrency = try c.decodeIfPresent(String.self, forKey: .primaryCurrency) ?? "CNY"
        monthlyBudgetMinor = try c.decodeIfPresent(Int64.self, forKey: .monthlyBudgetMinor)
        lockTimeout = try c.decodeIfPresent(LockTimeout.self, forKey: .lockTimeout) ?? .thirtySeconds
        biometryEnabled = try c.decodeIfPresent(Bool.self, forKey: .biometryEnabled) ?? false
        defaultReminderOffsets = try c.decodeIfPresent([Int].self, forKey: .defaultReminderOffsets) ?? [3]
        appearance = try c.decodeIfPresent(Appearance.self, forKey: .appearance) ?? .system
        reduceGlassMotion = try c.decodeIfPresent(Bool.self, forKey: .reduceGlassMotion) ?? false
        manualRates = try c.decodeIfPresent([String: Decimal].self, forKey: .manualRates) ?? [:]
    }
}

// MARK: - 聚合根

public struct VaultSnapshot: Codable, Sendable, Hashable {
    public var schemaVersion: Int
    public var documentID: UUID
    public var createdAt: Date
    public var subscriptions: [Subscription]
    public var categories: [Category]
    public var templates: [UserTemplate]
    public var tombstones: [Tombstone]
    public var settings: AppSettings

    public init(schemaVersion: Int = SchemaMigrator.currentVersion,
                documentID: UUID = UUID(),
                createdAt: Date = Date(),
                subscriptions: [Subscription] = [],
                categories: [Category] = Category.builtIns,
                templates: [UserTemplate] = [],
                tombstones: [Tombstone] = [],
                settings: AppSettings = AppSettings()) {
        self.schemaVersion = schemaVersion
        self.documentID = documentID
        self.createdAt = createdAt
        self.subscriptions = subscriptions
        self.categories = categories
        self.templates = templates
        self.tombstones = tombstones
        self.settings = settings
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        documentID = try c.decodeIfPresent(UUID.self, forKey: .documentID) ?? UUID()
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        subscriptions = try c.decodeIfPresent([Subscription].self, forKey: .subscriptions) ?? []
        categories = try c.decodeIfPresent([Category].self, forKey: .categories) ?? Category.builtIns
        templates = try c.decodeIfPresent([UserTemplate].self, forKey: .templates) ?? []
        tombstones = try c.decodeIfPresent([Tombstone].self, forKey: .tombstones) ?? []
        settings = try c.decodeIfPresent(AppSettings.self, forKey: .settings) ?? AppSettings()
    }

    // MARK: 查询便捷方法

    public var sortedCategories: [Category] {
        categories.sorted { $0.sortIndex < $1.sortIndex }
    }

    public func category(id: String) -> Category {
        categories.first(where: { $0.id == id }) ?? .fallback
    }

    public var activeSubscriptions: [Subscription] {
        subscriptions.filter { $0.state == .active }
    }

    public var billableSubscriptions: [Subscription] {
        subscriptions.filter { $0.isBillable }
    }

    public var primaryCurrency: String { settings.primaryCurrency }

    public func monthlyTotal(currency: String? = nil) -> Money {
        let code = currency ?? settings.primaryCurrency
        let amounts: [Money] = billableSubscriptions.map { sub in
            let monthly = sub.monthlyEquivalent
            guard monthly.currencyCode != code else { return monthly }
            let rate = settings.manualRates[monthly.currencyCode] ?? 1
            return monthly.converting(to: code, rate: rate)
        }
        return amounts.reduce(Money.zero(code), +)
    }

    public func annualTotal(currency: String? = nil) -> Money {
        monthlyTotal(currency: currency).multiplied(by: 12).rounded()
    }

    public func nearest(after now: Date = Date(), limit: Int = 5) -> [UpcomingRenewal] {
        subscriptions
            .compactMap { sub -> UpcomingRenewal? in
                guard let date = sub.nextBillingDate(after: now) else { return nil }
                let days = Calendar.ws.dateComponents([.day],
                                                      from: Calendar.ws.startOfDay(for: now),
                                                      to: Calendar.ws.startOfDay(for: date)).day ?? 0
                return UpcomingRenewal(subscription: sub, date: date, daysAway: days)
            }
            .sorted { $0.date < $1.date }
            .prefix(limit)
            .map { $0 }
    }
}

public struct UpcomingRenewal: Identifiable, Hashable, Sendable {
    public var id: UUID { subscription.id }
    public var subscription: Subscription
    public var date: Date
    public var daysAway: Int
}
