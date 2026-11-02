#if os(iOS)
import Foundation
import SwiftUI
import WSDesignSystem
import WSCore

public struct MainShellView: View {
    @EnvironmentObject private var model: AppModel

    public init() {}

    public var body: some View {
        TabView(selection: $model.selectedTab) {
            Tab(AppTab.dashboard.title, systemImage: AppTab.dashboard.symbol, value: AppTab.dashboard) {
                HomeView()
            }
            Tab(AppTab.library.title, systemImage: AppTab.library.symbol, value: AppTab.library) {
                LibraryView()
            }
            Tab(AppTab.stats.title, systemImage: AppTab.stats.symbol, value: AppTab.stats) {
                StatsView()
            }
            Tab(AppTab.settings.title, systemImage: AppTab.settings.symbol, value: AppTab.settings) {
                SettingsView()
            }
        }
        .modifier(TabBarMinimizeModifier())
        .overlay(alignment: .top) {
            if let notice = model.notice {
                Text(notice)
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.regularMaterial, in: Capsule(style: .continuous))
                    .overlay { Capsule().strokeBorder(Color.wsHairline, lineWidth: 0.5) }
                    .padding(.top, 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onTapGesture { model.clearMessages() }
                    .task {
                        try? await Task.sleep(for: .seconds(3))
                        withAnimation { model.clearMessages() }
                    }
            }
        }
    }
}

// MARK: - 概览

/// 概览页回答三个问题：下一笔什么时候扣、这个月花了多少、后面还排着几笔。
/// 完整的订阅清单不在这里重复，那是「订阅」页的职责。
public struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showAdd = false

    public init() {}

    private var snapshot: VaultSnapshot { model.snapshot ?? VaultSnapshot() }
    private var currency: String { snapshot.settings.primaryCurrency }

    /// 已经发生的扣款先不算，只取未来 5 笔：第一笔做主角，其余做时间轴。
    private var upcoming: [UpcomingRenewal] { snapshot.nearest(after: Date(), limit: 5) }
    private var laterUpcoming: [UpcomingRenewal] { Array(upcoming.dropFirst().prefix(4)) }

    private var monthlyPoints: [MonthPoint] { snapshot.monthlySpend(monthsBack: 6) }

    private var pendingThisYear: Int {
        let calendar = Calendar.ws
        guard let yearEnd = calendar.dateInterval(of: .year, for: Date())?.end else { return 0 }
        let interval = DateInterval(start: calendar.startOfDay(for: Date()), end: yearEnd)
        return snapshot.activeSubscriptions.reduce(0) { total, sub in
            total + sub.cycle.dates(in: interval, anchor: sub.anchorDate, calendar: calendar).count
        }
    }

    public var body: some View {
        NavigationStack {
            Screen {
                ScrollView {
                    VStack(spacing: 14) {
                        if snapshot.subscriptions.isEmpty {
                            emptyCard
                        } else {
                            hero
                            HStack(alignment: .top, spacing: 12) {
                                SpendTrendCard(points: monthlyPoints,
                                               total: monthlyPoints.last?.amount ?? .zero(currency))
                                YearProgressCard(remaining: snapshot.remainingThisYear(),
                                                 pendingCount: pendingThisYear)
                            }
                            if !laterUpcoming.isEmpty {
                                TimelineSection(renewals: laterUpcoming, snapshot: snapshot)
                            }
                            allSubscriptionsLink
                        }
                    }
                    .padding(.horizontal, WSTheme.pagePadding)
                    .padding(.top, 2)
                    .padding(.bottom, 28)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle(AppTab.dashboard.title)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { await model.lock() }
                    } label: {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .accessibilityLabel("锁定")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAdd = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .accessibilityLabel("添加订阅")
                }
            }
            .sheet(isPresented: $showAdd) {
                TemplatePickerView()
            }
        }
    }

    @ViewBuilder
    private var hero: some View {
        if let next = upcoming.first {
            NavigationLink {
                SubscriptionDetailView(subscription: next.subscription)
            } label: {
                NextRenewalCard(renewal: next)
            }
            .buttonStyle(.plain)
        } else {
            SurfaceCard {
                VStack(alignment: .leading, spacing: 5) {
                    Text("没有进行中的订阅")
                        .font(.system(size: 15, weight: .medium))
                    Text("添加一条，这里会显示下一笔扣款")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var emptyCard: some View {
        SurfaceCard {
            WSEmptyState(symbol: "plus.circle",
                         title: "还没有订阅",
                         message: "点右上角添加一项",
                         actionTitle: "添加订阅") { showAdd = true }
        }
    }

    private var allSubscriptionsLink: some View {
        Button {
            model.selectedTab = .library
        } label: {
            HStack(spacing: 8) {
                Text("全部 \(snapshot.subscriptions.count) 项订阅")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text("按时间与分类")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .frame(height: 50)
            .frame(maxWidth: .infinity)
            .background(Color.wsCard, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.wsHairline, lineWidth: 0.5)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 下一笔（主卡）

/// 首页的头号卡片：深色底，把「哪一天、多少钱、什么周期」一次说清。
/// 颜色固定为石墨色，明暗模式下都成立，也不会随品牌色变成奇怪的颜色。
private struct NextRenewalCard: View {
    let renewal: UpcomingRenewal

    @Environment(\.colorScheme) private var scheme

    private var sub: Subscription { renewal.subscription }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("下一笔扣款")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer(minLength: 8)
                Text(WSDate.monthDay(renewal.date))
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.42))
            }

            HStack(spacing: 13) {
                IconTile(brand: sub.brandID,
                         symbol: sub.symbolName,
                         hex: sub.tintHex,
                         name: sub.name,
                         customID: sub.customIconID,
                         size: 58)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(sub.name)
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        if sub.isTrial, !sub.name.contains("试用") {
                            Text("试用")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.white.opacity(0.16),
                                            in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        }
                    }
                    Text(meta)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.3))
            }
            .padding(.top, 15)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(sub.price.formatted())
                    .font(.wsNumber(30, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                Text(countdown)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer(minLength: 0)
            }
            .padding(.top, 13)

            Rectangle()
                .fill(.white.opacity(0.10))
                .frame(height: 0.5)
                .padding(.vertical, 13)

            HStack(spacing: 10) {
                stat("上次扣款", sub.lastBillingDate().map { WSDate.monthDay($0) } ?? "—")
                stat("月均", sub.cycle.isOneTime ? "—" : sub.monthlyEquivalent.formatted())
                stat("每年", sub.cycle.isOneTime ? "—" : sub.annualEquivalent.formatted())
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(scheme == .dark ? Color(hex: "#1D222C") : Color(hex: "#171B22"),
                    in: RoundedRectangle(cornerRadius: WSTheme.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: WSTheme.cardRadius, style: .continuous)
                .strokeBorder(.white.opacity(scheme == .dark ? 0.10 : 0.06), lineWidth: 0.5)
        }
        .contentShape(RoundedRectangle(cornerRadius: WSTheme.cardRadius, style: .continuous))
    }

    private var meta: String {
        let cycle = sub.cycle.displayName
        return sub.vendor.isEmpty ? cycle : "\(sub.vendor) · \(cycle)"
    }

    private var countdown: String {
        if sub.isTrial {
            // 名字里已经带了「试用」就不再重复一遍
            let prefix = sub.name.contains("试用") ? "" : "试用"
            return renewal.daysAway <= 0 ? "\(prefix)今天结束" : "\(prefix)还剩 \(renewal.daysAway) 天"
        }
        switch renewal.daysAway {
        case ..<0: return "已到期"
        case 0: return "今天扣款"
        case 1: return "明天扣款"
        default: return "\(renewal.daysAway) 天后"
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.4))
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 并排两张较高的数据卡

private struct TallStatCard<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: 152, alignment: .topLeading)
        .background(Color.wsCard, in: RoundedRectangle(cornerRadius: WSTheme.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: WSTheme.cardRadius, style: .continuous)
                .strokeBorder(Color.wsHairline, lineWidth: 0.5)
        }
    }
}

/// 本月支出 + 近 6 个月小柱状图 + 环比。
private struct SpendTrendCard: View {
    let points: [MonthPoint]
    let total: Money

    @Environment(\.colorScheme) private var scheme

    private var peak: Int64 { max(1, points.map(\.amount.minorUnits).max() ?? 1) }

    private var delta: Double? {
        guard points.count >= 2 else { return nil }
        let previous = points[points.count - 2].amount.minorUnits
        guard previous > 0 else { return nil }
        return Double(points[points.count - 1].amount.minorUnits - previous) / Double(previous)
    }

    var body: some View {
        TallStatCard(title: "本月支出") {
            Text(total.formatted())
                .font(.wsNumber(21, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.top, 3)

            Spacer(minLength: 10)

            HStack(alignment: .bottom, spacing: 4) {
                ForEach(points) { point in
                    let ratio = Double(point.amount.minorUnits) / Double(peak)
                    let isCurrent = point.id == points.last?.id
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(isCurrent ? WSTheme.accent : WSTheme.accent.opacity(scheme == .dark ? 0.34 : 0.18))
                        .frame(height: max(4, 34 * ratio))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 34, alignment: .bottom)

            Spacer(minLength: 10)

            HStack(spacing: 3) {
                if let delta {
                    Image(systemName: delta >= 0 ? "arrow.up.right" : "arrow.down.right")
                        .font(.system(size: 9, weight: .bold))
                    Text(String(format: "%+.0f%% 较上月", delta * 100))
                        .font(.system(size: 10))
                } else {
                    Text("上月没有扣款")
                        .font(.system(size: 10))
                }
            }
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
    }
}

/// 今年剩余 + 年进度环 + 待扣笔数。
private struct YearProgressCard: View {
    let remaining: Money
    let pendingCount: Int

    private var progress: Double {
        let calendar = Calendar.ws
        guard let days = calendar.range(of: .day, in: .year, for: Date())?.count,
              let today = calendar.ordinality(of: .day, in: .year, for: Date()),
              days > 0 else { return 0 }
        return min(1, Double(today) / Double(days))
    }

    var body: some View {
        TallStatCard(title: "今年剩余") {
            Text(remaining.formatted())
                .font(.wsNumber(21, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.top, 3)

            Spacer(minLength: 10)

            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .stroke(WSTheme.accent.opacity(0.14), lineWidth: 5)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(WSTheme.accent,
                                style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(pendingCount) 笔待扣")
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text("今年已过 \(Int(progress * 100))%")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)
        }
    }
}

// MARK: - 后续扣款时间轴

private struct TimelineSection: View {
    let renewals: [UpcomingRenewal]
    let snapshot: VaultSnapshot

    private var total: Money {
        let code = snapshot.primaryCurrency
        return renewals.reduce(Money.zero(code)) { sum, item in
            sum + snapshot.convert(item.subscription.price, to: code)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("后续扣款")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                Text("\(renewals.count) 笔 · \(total.formatted())")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 4)

            SurfaceCard(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(renewals.enumerated()), id: \.element.id) { index, item in
                        NavigationLink {
                            SubscriptionDetailView(subscription: item.subscription)
                        } label: {
                            TimelineRow(renewal: item,
                                        isFirst: index == 0,
                                        isLast: index == renewals.count - 1)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}

private struct TimelineRow: View {
    let renewal: UpcomingRenewal
    let isFirst: Bool
    let isLast: Bool

    private var sub: Subscription { renewal.subscription }
    private let rowHeight: CGFloat = 58

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                Text(dayText)
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                Text(weekText)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 38, alignment: .leading)

            ZStack {
                if !isLast {
                    Rectangle()
                        .fill(Color.wsHairline)
                        .frame(width: 1, height: rowHeight)
                        .offset(y: rowHeight / 2)
                }
                Circle()
                    .fill(isFirst ? WSTheme.accent : Color.secondary.opacity(0.3))
                    .frame(width: 7, height: 7)
            }
            .frame(width: 14)

            IconTile(brand: sub.brandID,
                     symbol: sub.symbolName,
                     hex: sub.tintHex,
                     name: sub.name,
                     customID: sub.customIconID,
                     size: 34)
                .padding(.trailing, 10)

            VStack(alignment: .leading, spacing: 2) {
                Text(sub.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(sub.cycle.shortLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(sub.price.formatted())
                .font(.wsNumber(14, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 14)
        .frame(height: rowHeight)
        .contentShape(Rectangle())
    }

    private var dayText: String {
        let components = Calendar.ws.dateComponents([.month, .day], from: renewal.date)
        return "\(components.month ?? 0)/\(components.day ?? 0)"
    }

    private var weekText: String {
        renewal.date.formatted(.dateTime.weekday(.abbreviated).locale(WSDate.locale))
    }
}

// MARK: - 订阅页使用的紧凑行

public struct SubscriptionRowCell: View {
    public enum Trailing {
        case priceAndCycle
        case priceAndDate
        case dayCount
    }

    private let subscription: Subscription
    private let trailing: Trailing

    public init(subscription: Subscription, trailing: Trailing = .priceAndCycle) {
        self.subscription = subscription
        self.trailing = trailing
    }

    public var body: some View {
        HStack(spacing: 12) {
            IconTile(brand: subscription.brandID,
                     symbol: subscription.symbolName,
                     hex: subscription.tintHex,
                     name: subscription.name,
                     customID: subscription.customIconID,
                     size: 42)

            VStack(alignment: .leading, spacing: 3) {
                Text(subscription.name)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(subscription.vendor.isEmpty ? subscription.cycle.displayName : subscription.vendor)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                Text(subscription.price.formatted())
                    .font(.wsNumber(15, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(trailingText)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 10)
    }

    private var trailingText: String {
        switch trailing {
        case .priceAndCycle:
            return subscription.cycle.shortLabel
        case .priceAndDate:
            guard let date = subscription.nextBillingDate() else { return "已结束" }
            return WSDate.monthDay(date)
        case .dayCount:
            guard let days = subscription.daysUntilNextBilling() else { return "—" }
            return days <= 0 ? "今天" : "\(days) 天"
        }
    }
}
#endif
