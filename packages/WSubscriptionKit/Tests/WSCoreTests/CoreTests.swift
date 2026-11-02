import XCTest
@testable import WSCore

final class MoneyTests: XCTestCase {
    func testIntegerArithmeticIsExact() {
        let a = Money(decimal: Decimal(string: "0.1")!, currencyCode: "CNY")!
        let b = Money(decimal: Decimal(string: "0.2")!, currencyCode: "CNY")!
        XCTAssertEqual((a + b).minorUnits, 30)
        XCTAssertEqual((a + b).decimal, Decimal(string: "0.30"))
    }

    func testFractionDigitsPerCurrency() {
        XCTAssertEqual(Money(minorUnits: 8800, currencyCode: "CNY").fractionDigits, 2)
        XCTAssertEqual(Money(minorUnits: 1500, currencyCode: "JPY").fractionDigits, 0)
        XCTAssertEqual(Money(minorUnits: 1_500_000, currencyCode: "KWD").fractionDigits, 3)
        XCTAssertEqual(Money(minorUnits: 1500, currencyCode: "JPY").decimal, 1500)
    }

    func testRoundingOnConversion() {
        let price = Money(minorUnits: 8800, currencyCode: "CNY")
        let monthly = BillingCycle.annually.monthlyEquivalent(of: price)
        XCTAssertEqual(monthly.minorUnits, 733) // 8800 / 12 = 733.33 → 733
    }

    func testInvalidDecimalOverflowReturnsNil() {
        XCTAssertNil(Money(decimal: Decimal(string: "1e30")!, currencyCode: "CNY"))
    }
}

final class BillingCycleTests: XCTestCase {
    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }

    func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    func testMonthlyEquivalents() {
        let price = Money(minorUnits: 12000, currencyCode: "CNY") // ¥120
        XCTAssertEqual(BillingCycle.weekly.monthlyEquivalent(of: price).minorUnits, 520_00)
        XCTAssertEqual(BillingCycle.monthly.monthlyEquivalent(of: price).minorUnits, 120_00)
        XCTAssertEqual(BillingCycle.quarterly.monthlyEquivalent(of: price).minorUnits, 40_00)
        XCTAssertEqual(BillingCycle.semiAnnually.monthlyEquivalent(of: price).minorUnits, 20_00)
        XCTAssertEqual(BillingCycle.annually.monthlyEquivalent(of: price).minorUnits, 10_00)
        XCTAssertEqual(BillingCycle.oneTime.monthlyEquivalent(of: price).minorUnits, 0)
        XCTAssertEqual(BillingCycle.customMonths(3).monthlyEquivalent(of: price).minorUnits, 40_00)
    }

    func testWeekdayCyclesUseRealDays() {
        let anchor = day(2026, 1, 5) // 周一
        let next = BillingCycle.weekly.nextDate(after: day(2026, 1, 20), anchor: anchor, calendar: calendar)!
        XCTAssertEqual(calendar.component(.day, from: next), 26)
    }

    func testMonthEndClampingDoesNotDrift() {
        let anchor = day(2026, 1, 31)
        // 1/31 + 1 月 → 2/28
        let feb = BillingCycle.monthly.nextDate(after: day(2026, 1, 31), anchor: anchor, calendar: calendar)!
        XCTAssertEqual(calendar.component(.month, from: feb), 2)
        XCTAssertEqual(calendar.component(.day, from: feb), 28)
        // 再下一个月必须回到 31 日（而不是一路跌到 28）
        let march = BillingCycle.monthly.nextDate(after: feb, anchor: anchor, calendar: calendar)!
        XCTAssertEqual(calendar.component(.month, from: march), 3)
        XCTAssertEqual(calendar.component(.day, from: march), 31)
    }

    func testLeapYearClamp() {
        let anchor = day(2028, 1, 31) // 2028 是闰年
        let feb = BillingCycle.monthly.nextDate(after: day(2028, 1, 31), anchor: anchor, calendar: calendar)!
        XCTAssertEqual(calendar.component(.day, from: feb), 29)
    }

    func testAnnualOnLeapDay() {
        let anchor = day(2028, 2, 29)
        let next = BillingCycle.annually.nextDate(after: day(2028, 3, 1), anchor: anchor, calendar: calendar)!
        XCTAssertEqual(calendar.component(.year, from: next), 2029)
        XCTAssertEqual(calendar.component(.day, from: next), 28)
    }

    func testDatesInIntervalCountsBillingHits() {
        let anchor = day(2026, 1, 1)
        let interval = DateInterval(start: calendar.startOfDay(for: day(2026, 1, 1)),
                                    end: calendar.startOfDay(for: day(2026, 4, 1)))
        XCTAssertEqual(BillingCycle.monthly.dates(in: interval, anchor: anchor, calendar: calendar).count, 3)
        XCTAssertEqual(BillingCycle.weekly.dates(in: interval, anchor: anchor, calendar: calendar).count, 13)
    }

    func testOneTimeHasNoNextDate() {
        XCTAssertNil(BillingCycle.oneTime.nextDate(after: day(2026, 1, 1), anchor: day(2026, 1, 1), calendar: calendar))
    }
}

final class SubscriptionTests: XCTestCase {
    func testDaysUntilRenewal() {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = c.date(from: DateComponents(year: 2026, month: 5, day: 10, hour: 9))!
        let sub = Subscription(name: "Test", categoryID: "streaming",
                               price: Money(minorUnits: 3000, currencyCode: "CNY"),
                               cycle: .monthly,
                               anchorDate: c.date(from: DateComponents(year: 2026, month: 1, day: 15, hour: 9))!,
                               deviceID: UUID())
        XCTAssertEqual(sub.daysUntilNextBilling(from: now, calendar: c), 5)
    }

    func testEndedSubscriptionHasNoNextBilling() {
        let sub = Subscription(name: "Test", categoryID: "streaming",
                               price: Money(minorUnits: 3000, currencyCode: "CNY"),
                               state: .ended, deviceID: UUID())
        XCTAssertNil(sub.nextBillingDate())
    }
}

final class VaultAggregationTests: XCTestCase {
    func makeSnapshot() -> VaultSnapshot {
        var snapshot = VaultSnapshot()
        snapshot.settings.primaryCurrency = "CNY"
        snapshot.subscriptions = [
            Subscription(name: "Netflix", categoryID: "streaming",
                         price: Money(minorUnits: 8800, currencyCode: "CNY"),
                         cycle: .monthly, state: .active, deviceID: UUID()),
            Subscription(name: "iCloud", categoryID: "cloud",
                         price: Money(minorUnits: 7200, currencyCode: "CNY"),
                         cycle: .annually, state: .active, deviceID: UUID()),
            Subscription(name: "Paused", categoryID: "cloud",
                         price: Money(minorUnits: 9900, currencyCode: "CNY"),
                         cycle: .monthly, state: .paused, deviceID: UUID())
        ]
        return snapshot
    }

    func testMonthlyTotalExcludesPaused() {
        let snapshot = makeSnapshot()
        // 88.00 + 72.00/12 = 88.00 + 6.00 = 94.00
        XCTAssertEqual(snapshot.monthlyTotal().minorUnits, 9400)
    }

    func testCategoryBreakdownSumsToTotal() {
        let snapshot = makeSnapshot()
        let slices = snapshot.categoryBreakdown()
        let total = slices.reduce(Int64(0)) { $0 + $1.monthly.minorUnits }
        XCTAssertEqual(total, snapshot.monthlyTotal().minorUnits)
        XCTAssertEqual(slices.first?.category.id, "streaming")
    }

    func testCrossCurrencyUsesManualRate() {
        var snapshot = makeSnapshot()
        snapshot.settings.manualRates["USD"] = 7
        snapshot.subscriptions.append(
            Subscription(name: "Spotify", categoryID: "music",
                         price: Money(minorUnits: 1099, currencyCode: "USD"),
                         cycle: .monthly, state: .active, deviceID: UUID())
        )
        // 94.00 + 10.99 * 7 = 170.93
        XCTAssertEqual(snapshot.monthlyTotal().minorUnits, 17093)
    }
}

final class MergeTests: XCTestCase {
    func testNewerTimestampWins() {
        let deviceA = UUID()
        let deviceB = UUID()
        var local = VaultSnapshot()
        var remote = VaultSnapshot()
        local.schemaVersion = 1
        remote.schemaVersion = 1

        let id = UUID()
        var a = Subscription(id: id, name: "A", categoryID: "cloud",
                             price: Money(minorUnits: 100, currencyCode: "CNY"),
                             updatedAt: Date(timeIntervalSince1970: 100), deviceID: deviceA)
        a.name = "Local"
        var b = a
        b.name = "Remote"
        b.updatedAt = Date(timeIntervalSince1970: 200)
        b.deviceID = deviceB
        local.subscriptions = [a]
        remote.subscriptions = [b]

        let merged = LWWMerger.merge(local: local, remote: remote)
        XCTAssertEqual(merged.subscriptions.count, 1)
        XCTAssertEqual(merged.subscriptions.first?.name, "Remote")
    }

    func testTombstoneDeletesWhenNewer() {
        var local = VaultSnapshot()
        let id = UUID()
        local.subscriptions = [
            Subscription(id: id, name: "Old", categoryID: "cloud",
                         price: Money(minorUnits: 100, currencyCode: "CNY"),
                         updatedAt: Date(timeIntervalSince1970: 100), deviceID: UUID())
        ]
        var remote = local
        remote.subscriptions = []
        remote.tombstones = [Tombstone(id: id, deletedAt: Date(timeIntervalSince1970: 200), deviceID: UUID())]

        let merged = LWWMerger.merge(local: local, remote: remote)
        XCTAssertTrue(merged.subscriptions.isEmpty)
    }

    func testRecordEditedAfterDeletionSurvives() {
        let id = UUID()
        var local = VaultSnapshot()
        local.subscriptions = [
            Subscription(id: id, name: "Resurrected", categoryID: "cloud",
                         price: Money(minorUnits: 100, currencyCode: "CNY"),
                         updatedAt: Date(timeIntervalSince1970: 300), deviceID: UUID())
        ]
        local.tombstones = [Tombstone(id: id, deletedAt: Date(timeIntervalSince1970: 200), deviceID: UUID())]
        let merged = LWWMerger.merge(local: local, remote: VaultSnapshot())
        XCTAssertEqual(merged.subscriptions.count, 1)
    }

    func testMergeIsDeterministic() {
        let id = UUID()
        var a = Subscription(id: id, name: "A", categoryID: "cloud",
                             price: Money(minorUnits: 100, currencyCode: "CNY"),
                             updatedAt: Date(timeIntervalSince1970: 100), deviceID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        var b = a
        a.name = "FromA"
        b.name = "FromB"
        b.deviceID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

        var left = VaultSnapshot(); left.subscriptions = [a]
        var right = VaultSnapshot(); right.subscriptions = [b]

        let first = LWWMerger.merge(local: left, remote: right).subscriptions.first?.name
        for _ in 0..<50 {
            let again = LWWMerger.merge(local: left, remote: right).subscriptions.first?.name
            XCTAssertEqual(again, first)
        }
        XCTAssertEqual(first, "FromB")
    }
}

final class TemplateCatalogTests: XCTestCase {
    func testCatalogLoads() {
        XCTAssertGreaterThan(TemplateCatalog.all.count, 30)
    }

    func testSearchByChineseAlias() {
        let results = TemplateCatalog.search("奈飞")
        XCTAssertEqual(results.first?.id, "netflix")
    }

    func testEveryTemplateCategoryExists() {
        let ids = Set(Category.builtIns.map(\.id))
        for template in TemplateCatalog.all {
            XCTAssertTrue(ids.contains(template.categoryID), "\(template.id) 指向了不存在的分类")
        }
    }
}

final class SchemaTests: XCTestCase {
    func testRoundTrip() throws {
        var snapshot = VaultSnapshot()
        snapshot.subscriptions = [
            Subscription(name: "Test", categoryID: "ai",
                         price: Money(minorUnits: 14000, currencyCode: "CNY"),
                         cycle: .customMonths(3), deviceID: UUID())
        ]
        let data = try SchemaMigrator.encode(snapshot)
        let decoded = try SchemaMigrator.decode(data)
        XCTAssertEqual(decoded.subscriptions.first?.price.minorUnits, 14000)
        XCTAssertEqual(decoded.subscriptions.first?.cycle, .customMonths(3))
    }

    func testUnknownCycleFallsBackToMonthly() throws {
        let json = """
        {"kind":"everyFortnight"}
        """
        let cycle = try JSONDecoder().decode(BillingCycle.self, from: Data(json.utf8))
        XCTAssertEqual(cycle, .monthly)
    }

    func testTooNewSchemaIsRejected() {
        let json = #"{"schemaVersion": 99, "subscriptions": []}"#
        XCTAssertThrowsError(try SchemaMigrator.decode(Data(json.utf8)))
    }
}
