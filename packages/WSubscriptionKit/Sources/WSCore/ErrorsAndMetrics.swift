import Foundation

public struct VaultError: Error, LocalizedError, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case folderPermissionLost
        case vaultNotFound
        case wrongCredential
        case biometryUnavailable
        case fileTampered
        case revisionRollback
        case diskFull
        case schemaTooNew
        case corrupted
        case notUnlocked
        case io(String)
    }

    public var kind: Kind
    public var attemptsRemaining: Int?

    public init(_ kind: Kind, attemptsRemaining: Int? = nil) {
        self.kind = kind
        self.attemptsRemaining = attemptsRemaining
    }

    public var errorDescription: String? {
        switch kind {
        case .folderPermissionLost: return "文件夹访问权限已失效，可能被移动或删除了"
        case .vaultNotFound: return "所选文件夹里没有找到数据文件"
        case .wrongCredential: return "密码不正确"
        case .biometryUnavailable: return "此设备暂时无法使用生物识别"
        case .fileTampered: return "数据文件校验失败，可能已被外部修改"
        case .revisionRollback: return "文件版本比本机记录更旧"
        case .diskFull: return "存储空间不足"
        case .schemaTooNew: return "这个数据文件由更新版本的 App 创建，请先升级 App"
        case .corrupted: return "数据文件已损坏"
        case .notUnlocked: return "保险箱尚未解锁"
        case .io(let message): return "读写失败：\(message)"
        }
    }

    public var recoverySuggestion: String? {
        switch kind {
        case .folderPermissionLost: return "重新选择同一个文件夹即可恢复"
        case .vaultNotFound: return "选择包含 WSubscription.vault 的文件夹，或新建一个"
        case .wrongCredential: return "再试一次，或使用 Face ID / 恢复码解锁"
        case .biometryUnavailable: return "改用密码解锁"
        case .fileTampered, .revisionRollback: return "可以从同目录的 WSubscription.vault.bak 恢复"
        case .schemaTooNew: return "更新 App 后再打开"
        default: return nil
        }
    }
}

// MARK: - 统计

public struct CategorySlice: Identifiable, Hashable, Sendable {
    public var id: String { category.id }
    public var category: Category
    public var monthly: Money
    public var share: Double
    public var count: Int
}

public struct MonthPoint: Identifiable, Hashable, Sendable {
    public var id: Date { month }
    public var month: Date
    public var amount: Money
    public var label: String
}

public extension VaultSnapshot {
    func categoryBreakdown(currency: String? = nil) -> [CategorySlice] {
        let code = currency ?? settings.primaryCurrency
        let total = monthlyTotal(currency: code)
        var buckets: [String: (money: Money, count: Int)] = [:]

        for sub in billableSubscriptions {
            let monthly = convert(sub.monthlyEquivalent, to: code)
            var bucket = buckets[sub.categoryID] ?? (Money.zero(code), 0)
            bucket.money = bucket.money + monthly
            bucket.count += 1
            buckets[sub.categoryID] = bucket
        }

        return buckets
            .map { key, value in
                CategorySlice(
                    category: category(id: key),
                    monthly: value.money,
                    share: total.minorUnits > 0 ? Double(value.money.minorUnits) / Double(total.minorUnits) : 0,
                    count: value.count
                )
            }
            .sorted { $0.monthly.minorUnits > $1.monthly.minorUnits }
    }

    /// 最近 N 个月的实际扣款额（按每条订阅的真实扣款日累加，不是月度均值 × 12）。
    func monthlySpend(monthsBack: Int = 6, now: Date = Date(), calendar: Calendar = .ws) -> [MonthPoint] {
        let code = settings.primaryCurrency
        let currentMonthStart = calendar.dateInterval(of: .month, for: now)?.start ?? now
        var points: [MonthPoint] = []

        for offset in stride(from: monthsBack - 1, through: 0, by: -1) {
            guard let monthStart = calendar.date(byAdding: .month, value: -offset, to: currentMonthStart),
                  let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart) else { continue }
            let interval = DateInterval(start: monthStart, end: monthEnd.addingTimeInterval(-1))

            var sum = Money.zero(code)
            for sub in subscriptions where sub.state == .active {
                let hits = sub.cycle.dates(in: interval, anchor: sub.anchorDate, calendar: calendar).count
                guard hits > 0 else { continue }
                sum = sum + convert(sub.price, to: code).multiplied(by: Decimal(hits))
            }

            let label = monthStart.formatted(.dateTime.month(.abbreviated))
            points.append(MonthPoint(month: monthStart, amount: sum, label: label))
        }
        return points
    }

    func convert(_ money: Money, to code: String) -> Money {
        guard money.currencyCode != code else { return money }
        let rate = settings.manualRates[money.currencyCode] ?? 1
        return money.converting(to: code, rate: rate)
    }

    /// 「今年还要付多少」：从今天到年底的实际扣款总额。
    func remainingThisYear(now: Date = Date(), calendar: Calendar = .ws) -> Money {
        let code = settings.primaryCurrency
        guard let yearStart = calendar.dateInterval(of: .year, for: now)?.end else { return .zero(code) }
        let interval = DateInterval(start: calendar.startOfDay(for: now), end: yearStart)
        var sum = Money.zero(code)
        for sub in subscriptions where sub.state == .active {
            let hits = sub.cycle.dates(in: interval, anchor: sub.anchorDate, calendar: calendar).count
            guard hits > 0 else { continue }
            sum = sum + convert(sub.price, to: code).multiplied(by: Decimal(hits))
        }
        return sum
    }
}
