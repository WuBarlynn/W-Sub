#if os(iOS)
import SwiftUI
import WSDesignSystem
import WSCore

public struct StatsView: View {
    @EnvironmentObject private var model: AppModel

    public init() {}

    private var snapshot: VaultSnapshot { model.snapshot ?? VaultSnapshot() }
    private var currency: String { snapshot.settings.primaryCurrency }
    private var points: [MonthPoint] { snapshot.monthlySpend(monthsBack: 6) }
    private var maxMinor: Int64 { max(1, points.map(\.amount.minorUnits).max() ?? 1) }

    public var body: some View {
        NavigationStack {
            Screen {
                ScrollView {
                    VStack(spacing: 18) {
                        totals
                        chart
                        breakdown
                    }
                    .padding(.horizontal, WSTheme.pagePadding)
                    .padding(.top, 4)
                    .padding(.bottom, 32)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle("统计")
        }
    }

    private var totals: some View {
        HStack(spacing: 10) {
            totalCell("本月", snapshot.monthlyTotal().formatted(), "按月均折算")
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
                    .font(.wsNumber(22, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var chart: some View {
        VStack(alignment: .leading, spacing: 8) {
            WSSectionTitle("近 6 个月实际扣款")
            SurfaceCard(padding: 16) {
                HStack(alignment: .bottom, spacing: 10) {
                    ForEach(points) { point in
                        let ratio = Double(point.amount.minorUnits) / Double(maxMinor)
                        VStack(spacing: 6) {
                            Text(point.amount.minorUnits == 0
                                 ? "—"
                                 : point.amount.decimal.formatted(.currency(code: currency).precision(.fractionLength(0))))
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)

                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(WSTheme.accent.opacity(point.amount.minorUnits == 0 ? 0.12 : 1))
                                .frame(height: max(4, 92 * ratio))

                            Text(WSDate.monthAbbrev(point.month))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 140, alignment: .bottom)
            }
        }
    }

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
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)

                            if index < slices.count - 1 {
                                WSRowDivider(inset: 54)
                            }
                        }
                    }
                }
            }
        }
    }
}
#endif
