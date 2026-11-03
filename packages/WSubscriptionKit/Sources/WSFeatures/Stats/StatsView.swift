#if os(iOS)
import SwiftUI
import WSDesignSystem
import WSCore

public struct StatsView: View {
    @EnvironmentObject private var model: AppModel

    @State private var range: Range = .sixMonths
    @State private var expandedCategory: String?

    public init() {}

    private enum Range: String, CaseIterable, Identifiable {
        case sixMonths = "近 6 个月"
        case twelveMonths = "近 12 个月"
        var id: String { rawValue }
        var months: Int { self == .sixMonths ? 6 : 12 }
    }

    private var snapshot: VaultSnapshot { model.snapshot ?? VaultSnapshot() }
    private var currency: String { snapshot.settings.primaryCurrency }
    private var points: [MonthPoint] { snapshot.monthlySpend(monthsBack: range.months) }
    private var maxMinor: Int64 { max(1, points.map(\.amount.minorUnits).max() ?? 1) }

    public var body: some View {
        NavigationStack {
            Screen {
                ScrollView {
                    VStack(spacing: 18) {
                        totals
                        chart
                        summary
                        breakdown
                    }
                    .padding(.horizontal, WSTheme.pagePadding)
                    .padding(.top, 4)
                    .padding(.bottom, 100)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle("统计")
        }
    }

    // MARK: - 顶部汇总（四格）

    private var totals: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            totalCell("本月支出", snapshot.monthlyTotal().formatted(), "按月均折算")
            totalCell("年度支出", snapshot.annualTotal().formatted(), "月均 × 12")
            totalCell("今年已付", paidThisYear().formatted(), "实际扣款累计")
            totalCell("今年剩余", snapshot.remainingThisYear().formatted(), "到 12 月 31 日")
        }
    }

    private func totalCell(_ title: String, _ value: String, _ note: String) -> some View {
        SurfaceCard(padding: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.wsNumber(20, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// 今年已付（1 月 1 日到今天实际扣款累计）
    private func paidThisYear() -> Money {
        let calendar = Calendar.ws
        guard let yearStart = calendar.dateInterval(of: .year, for: Date())?.start else {
            return .zero(currency)
        }
        let interval = DateInterval(start: yearStart, end: Date())
        var sum = Money.zero(currency)
        for sub in snapshot.subscriptions where sub.state == .active {
            let hits = sub.billableDates(in: interval, calendar: calendar).count
            guard hits > 0 else { continue }
            sum = sum + snapshot.convert(sub.price, to: currency).multiplied(by: Decimal(hits))
        }
        return sum
    }

    // MARK: - 图表（可切换范围）

    private var chart: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                WSSectionTitle("实际扣款")
                Spacer()
                Picker("范围", selection: $range) {
                    ForEach(Range.allCases) { r in
                        Text(r.rawValue).tag(r)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
            }

            SurfaceCard(padding: 16) {
                VStack(spacing: 10) {
                    HStack(alignment: .bottom, spacing: range.months == 6 ? 10 : 6) {
                        ForEach(points) { point in
                            let ratio = Double(point.amount.minorUnits) / Double(maxMinor)
                            VStack(spacing: 5) {
                                Text(point.amount.minorUnits == 0
                                     ? "—"
                                     : point.amount.decimal.formatted(.currency(code: currency).precision(.fractionLength(0))))
                                    .font(.system(size: 8, weight: .medium))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.5)

                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(WSTheme.accent.opacity(point.amount.minorUnits == 0 ? 0.12 : 1))
                                    .frame(height: max(4, 92 * ratio))

                                Text(WSDate.monthAbbrev(point.month))
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(height: 140, alignment: .bottom)

                    // 范围汇总：总支出 + 最高月 + 月均
                    HStack {
                        chartStat("合计", points.reduce(Money.zero(currency)) { $0 + $1.amount }.formatted())
                        chartStat("最高月", points.map(\.amount).max()?.formatted() ?? "—")
                        chartStat("月均", (points.reduce(Money.zero(currency)) { $0 + $1.amount })
                            .multiplied(by: Decimal(1) / Decimal(range.months)).rounded().formatted())
                    }
                }
            }
        }
    }

    private func chartStat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.wsNumber(13, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 总览

    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            WSSectionTitle("总览")
            SurfaceCard(padding: 0) {
                VStack(spacing: 0) {
                    summaryRow("订阅总数", "\(snapshot.subscriptions.count) 项")
                    WSRowDivider(inset: 16)
                    summaryRow("进行中", "\(snapshot.activeSubscriptions.count) 项")
                    WSRowDivider(inset: 16)
                    summaryRow("已暂停 / 已结束", "\(snapshot.subscriptions.count - snapshot.activeSubscriptions.count) 项")
                    WSRowDivider(inset: 16)
                    summaryRow("月均单笔最高", topSubscriptionName)
                    WSRowDivider(inset: 16)
                    summaryRow("下一次扣款", nextBillingText)
                }
            }
        }
    }

    private func summaryRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 14))
                .foregroundStyle(.primary)
            Spacer()
            Text(value)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var topSubscriptionName: String {
        guard let top = snapshot.billableSubscriptions
            .max(by: { $0.monthlyEquivalent.minorUnits < $1.monthlyEquivalent.minorUnits }) else { return "—" }
        return "\(top.name) · \(top.monthlyEquivalent.formatted())"
    }

    private var nextBillingText: String {
        guard let next = snapshot.nearest(after: Date(), limit: 1).first else { return "—" }
        return "\(next.subscription.name) · \(WSDate.monthDayWithYear(next.date))"
    }

    // MARK: - 分类明细（可展开）

    private var breakdown: some View {
        VStack(alignment: .leading, spacing: 8) {
            WSSectionTitle("分类明细")
            let slices = snapshot.categoryBreakdown()
            if slices.isEmpty {
                SurfaceCard {
                    WSEmptyState(symbol: "chart.bar", title: "还没有数据", message: "添加订阅后会自动汇总")
                }
            } else {
                SurfaceCard(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(slices.enumerated()), id: \.element.id) { index, slice in
                            let isExpanded = expandedCategory == slice.category.id
                            VStack(spacing: 0) {
                                Button {
                                    withAnimation(.easeInOut(duration: 0.18)) {
                                        expandedCategory = isExpanded ? nil : slice.category.id
                                    }
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: slice.category.symbolName)
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundStyle(Color(hex: slice.category.tintHex))
                                            .frame(width: 26, height: 26)
                                            .background(Color(hex: slice.category.tintHex).opacity(0.10),
                                                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                                        VStack(alignment: .leading, spacing: 5) {
                                            HStack {
                                                Text(slice.category.name)
                                                    .font(.system(size: 14, weight: .medium))
                                                Text("\(slice.count)")
                                                    .font(.system(size: 11))
                                                    .foregroundStyle(.tertiary)
                                                Spacer()
                                                Text(slice.monthly.formatted())
                                                    .font(.wsNumber(14, weight: .medium))
                                                Text("\(Int((slice.share * 100).rounded()))%")
                                                    .font(.system(size: 11))
                                                    .foregroundStyle(.tertiary)
                                                    .frame(width: 32, alignment: .trailing)
                                            }
                                            GeometryReader { proxy in
                                                ZStack(alignment: .leading) {
                                                    Capsule().fill(Color.primary.opacity(0.06))
                                                    Capsule()
                                                        .fill(Color(hex: slice.category.tintHex))
                                                        .frame(width: max(3, proxy.size.width * slice.share))
                                                }
                                            }
                                            .frame(height: 3)
                                        }

                                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(.tertiary)
                                            .padding(.leading, 4)
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 12)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                // 展开的分类订阅明细
                                if isExpanded {
                                    VStack(spacing: 0) {
                                        ForEach(categorySubscriptions(slice.category.id)) { sub in
                                            HStack(spacing: 10) {
                                                Text(sub.name)
                                                    .font(.system(size: 13))
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                                Spacer()
                                                Text(sub.cycle.shortLabel)
                                                    .font(.system(size: 11))
                                                    .foregroundStyle(.tertiary)
                                                Text(sub.monthlyEquivalent.formatted())
                                                    .font(.wsNumber(12, weight: .medium))
                                                    .foregroundStyle(.secondary)
                                            }
                                            .padding(.horizontal, 16)
                                            .padding(.vertical, 8)
                                            .padding(.leading, 38)
                                        }
                                    }
                                    .background(Color.primary.opacity(0.03))
                                }
                            }

                            if index < slices.count - 1 {
                                WSRowDivider(inset: 54)
                            }
                        }
                    }
                }
            }
        }
    }

    private func categorySubscriptions(_ categoryID: String) -> [Subscription] {
        snapshot.subscriptions
            .filter { $0.categoryID == categoryID && $0.state == .active }
            .sorted { $0.monthlyEquivalent.minorUnits > $1.monthlyEquivalent.minorUnits }
    }
}
#endif
