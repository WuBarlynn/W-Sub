import Foundation

public extension Calendar {
    /// 全 App 统一使用公历 + 当前时区，避免农历/佛历设备上日期漂移。
    static var ws: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        calendar.locale = .autoupdatingCurrent
        return calendar
    }
}

/// 计费周期。所有周期都能折算成「月均」，用于概览与统计。
public enum BillingCycle: Hashable, Sendable, Codable {
    case weekly
    case biweekly
    case monthly
    case quarterly
    case semiAnnually
    case annually
    case customDays(Int)
    case customMonths(Int)
    case oneTime

    public var isOneTime: Bool {
        if case .oneTime = self { return true }
        return false
    }

    /// 折算系数；一次性购买返回 nil（不参与月度统计）。
    public var monthsEquivalent: Decimal? {
        switch self {
        case .weekly: return Decimal(52) / 12
        case .biweekly: return Decimal(26) / 12
        case .monthly: return 1
        case .quarterly: return 1.0 / 3.0
        case .semiAnnually: return 1.0 / 6.0
        case .annually: return 1.0 / 12.0
        case .customDays(let n):
            guard n > 0 else { return nil }
            return (Decimal(36525) / 100 / Decimal(n)) / 12
        case .customMonths(let n):
            guard n > 0 else { return nil }
            return 1 / Decimal(n)
        case .oneTime: return nil
        }
    }

    public func monthlyEquivalent(of amount: Money) -> Money {
        guard let factor = monthsEquivalent else { return Money(minorUnits: 0, currencyCode: amount.currencyCode) }
        return amount.multiplied(by: factor).rounded()
    }

    /// 年化（一次性购买不计入）。
    public func annualEquivalent(of amount: Money) -> Money {
        monthlyEquivalent(of: amount).multiplied(by: 12).rounded()
    }

    // MARK: - 展示

    public var displayName: String {
        switch self {
        case .weekly: return String(localized: "每周")
        case .biweekly: return String(localized: "每两周")
        case .monthly: return String(localized: "每月")
        case .quarterly: return String(localized: "每季度")
        case .semiAnnually: return String(localized: "每半年")
        case .annually: return String(localized: "每年")
        case .customDays(let n): return String(localized: "每 \(n) 天")
        case .customMonths(let n): return String(localized: "每 \(n) 个月")
        case .oneTime: return String(localized: "一次性")
        }
    }

    public var shortLabel: String {
        switch self {
        case .weekly: return String(localized: "周付")
        case .biweekly: return String(localized: "双周")
        case .monthly: return String(localized: "月付")
        case .quarterly: return String(localized: "季付")
        case .semiAnnually: return String(localized: "半年")
        case .annually: return String(localized: "年付")
        case .customDays: return String(localized: "自定")
        case .customMonths: return String(localized: "自定")
        case .oneTime: return String(localized: "买断")
        }
    }

    public static let presets: [BillingCycle] = [.weekly, .monthly, .quarterly, .semiAnnually, .annually]

    // MARK: - 日期推进

    /// 下一个扣款日（严格晚于 reference 所在的那一天）。
    /// 以 anchor 为锚点推进整周期，月末做夹取（1/31 → 2/28 → 3/31），不会逐月漂移。
    public func nextDate(after reference: Date,
                         anchor: Date,
                         calendar: Calendar = .ws) -> Date? {
        if isOneTime { return nil }
        let refDay = calendar.startOfDay(for: reference)
        let anchorDay = calendar.startOfDay(for: anchor)
        if anchorDay > refDay { return anchorDay }

        var step = 1
        while step <= 6_000 {
            let candidate = calendar.startOfDay(for: date(step: step, from: anchorDay, calendar: calendar))
            if candidate > refDay { return candidate }
            step += 1
        }
        return nil
    }

    /// 从 anchor 起、落在给定区间内的所有扣款日（用于时间线与统计）。
    public func dates(in interval: DateInterval,
                      anchor: Date,
                      calendar: Calendar = .ws,
                      limit: Int = 500) -> [Date] {
        if isOneTime {
            let day = calendar.startOfDay(for: anchor)
            return (day >= interval.start && day < interval.end) ? [day] : []
        }
        var result: [Date] = []
        var step = 0
        while step <= 6_000 && result.count < limit {
            let candidate = calendar.startOfDay(for: date(step: step, from: anchor, calendar: calendar))
            if candidate >= interval.end { break }
            if candidate >= interval.start { result.append(candidate) }
            step += 1
            if step == 6_000 { break }
        }
        return result
    }

    private func date(step: Int, from anchor: Date, calendar: Calendar) -> Date {
        switch self {
        case .weekly:
            return calendar.date(byAdding: .day, value: 7 * step, to: anchor) ?? anchor
        case .biweekly:
            return calendar.date(byAdding: .day, value: 14 * step, to: anchor) ?? anchor
        case .monthly:
            return Self.addMonths(step, to: anchor, calendar: calendar)
        case .quarterly:
            return Self.addMonths(3 * step, to: anchor, calendar: calendar)
        case .semiAnnually:
            return Self.addMonths(6 * step, to: anchor, calendar: calendar)
        case .annually:
            return Self.addMonths(12 * step, to: anchor, calendar: calendar)
        case .customDays(let n):
            return calendar.date(byAdding: .day, value: max(1, n) * step, to: anchor) ?? anchor
        case .customMonths(let n):
            return Self.addMonths(max(1, n) * step, to: anchor, calendar: calendar)
        case .oneTime:
            return anchor
        }
    }

    /// 加月份并保持「锚点日」：1/31 + 1 月 = 2/28（闰年 2/29），+ 2 月 = 3/31。
    static func addMonths(_ months: Int, to date: Date, calendar: Calendar) -> Date {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return date }
        let totalMonths = year * 12 + (month - 1) + months
        var comps = DateComponents()
        comps.year = totalMonths / 12
        comps.month = totalMonths % 12 + 1
        comps.day = 1
        guard let firstOfMonth = calendar.date(from: comps) else { return date }
        let dayCount = calendar.range(of: .day, in: .month, for: firstOfMonth)?.count ?? 28
        comps.day = min(day, dayCount)
        return calendar.date(from: comps) ?? date
    }
}

// MARK: - Codable（带 kind 判别，保证未来新增周期不破坏旧文件）

extension BillingCycle {
    private enum CodingKeys: String, CodingKey { case kind, value }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "weekly": self = .weekly
        case "biweekly": self = .biweekly
        case "monthly": self = .monthly
        case "quarterly": self = .quarterly
        case "semiAnnually": self = .semiAnnually
        case "annually": self = .annually
        case "customDays": self = .customDays(try container.decode(Int.self, forKey: .value))
        case "customMonths": self = .customMonths(try container.decode(Int.self, forKey: .value))
        case "oneTime": self = .oneTime
        default:
            // 未知周期（来自更新版本的 App）降级为月付，避免整份文件打不开。
            self = .monthly
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .weekly: try container.encode("weekly", forKey: .kind)
        case .biweekly: try container.encode("biweekly", forKey: .kind)
        case .monthly: try container.encode("monthly", forKey: .kind)
        case .quarterly: try container.encode("quarterly", forKey: .kind)
        case .semiAnnually: try container.encode("semiAnnually", forKey: .kind)
        case .annually: try container.encode("annually", forKey: .kind)
        case .customDays(let value):
            try container.encode("customDays", forKey: .kind)
            try container.encode(value, forKey: .value)
        case .customMonths(let value):
            try container.encode("customMonths", forKey: .kind)
            try container.encode(value, forKey: .value)
        case .oneTime: try container.encode("oneTime", forKey: .kind)
        }
    }
}
