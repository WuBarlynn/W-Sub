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

/// 概览 = 顶部两张白色支出卡 + 下面一叠黑色订阅卡。
/// 黑色卡片是真的叠在一起：后面两张缩小、往上露边，上滑把最上面一张翻走，
/// 最上面永远是离得最近的一笔扣款，翻到底就是最晚的一笔。
/// 卡片底部会一直延伸到底部标签栏后面，不在栏上面被切断。
public struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showAdd = false
    @State private var index = 0
    @State private var drag: CGFloat = 0
    @State private var detail: Subscription?

    public init() {}

    private var snapshot: VaultSnapshot { model.snapshot ?? VaultSnapshot() }
    private var currency: String { snapshot.settings.primaryCurrency }

    private var items: [Subscription] {
        snapshot.subscriptions.sorted { lhs, rhs in
            if lhs.state != .active || rhs.state != .active {
                if lhs.state == rhs.state { return lhs.name < rhs.name }
                return lhs.state == .active
            }
            let left = lhs.nextBillingDate() ?? .distantFuture
            let right = rhs.nextBillingDate() ?? .distantFuture
            if left == right { return lhs.name < rhs.name }
            return left < right
        }
    }

    private var monthlyPoints: [MonthPoint] { snapshot.monthlySpend(monthsBack: 6) }

    private var monthDelta: Double? {
        guard monthlyPoints.count >= 2 else { return nil }
        let previous = monthlyPoints[monthlyPoints.count - 2].amount.minorUnits
        guard previous > 0 else { return nil }
        let current = monthlyPoints[monthlyPoints.count - 1].amount.minorUnits
        return Double(current - previous) / Double(previous)
    }

    private var pendingThisYear: Int {
        let calendar = Calendar.ws
        guard let yearEnd = calendar.dateInterval(of: .year, for: Date())?.end else { return 0 }
        let interval = DateInterval(start: calendar.startOfDay(for: Date()), end: yearEnd)
        return snapshot.activeSubscriptions.reduce(0) { total, sub in
            total + sub.cycle.dates(in: interval, anchor: sub.anchorDate, calendar: calendar).count
        }
    }

    private var stack: [(item: Subscription, depth: Int)] {
        guard !items.isEmpty else { return [] }
        let start = min(max(0, index), items.count - 1)
        let end = min(start + 3, items.count)
        return (start..<end).map { (items[$0], $0 - start) }
    }

    public var body: some View {
        NavigationStack {
            Screen {
                VStack(spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        SpendTrendCard(points: monthlyPoints,
                                       total: monthlyPoints.last?.amount ?? .zero(currency),
                                       delta: monthDelta)
                        YearProgressCard(remaining: snapshot.remainingThisYear(),
                                         pendingCount: pendingThisYear)
                    }

                    if items.isEmpty {
                        SurfaceCard {
                            WSEmptyState(symbol: "plus.circle",
                                         title: "还没有订阅",
                                         message: "点右上角添加一项",
                                         actionTitle: "添加订阅") { showAdd = true }
                        }
                        Spacer(minLength: 0)
                    } else {
                        deckHeader
                        deck
                    }
                }
                .padding(.horizontal, WSTheme.pagePadding)
                .padding(.top, 6)
            }
            .navigationTitle(AppTab.dashboard.title)
            .navigationBarTitleDisplayMode(.inline)
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
            .navigationDestination(item: $detail) { item in
                SubscriptionDetailView(subscription: item)
            }
            .sheet(isPresented: $showAdd) {
                TemplatePickerView()
            }
        }
    }

    private var deckHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("离得最近")
                .font(.system(size: 13, weight: .semibold))
            Text("\(min(index + 1, items.count)) / \(items.count)")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
            Spacer(minLength: 8)
            Text("上滑翻到下一张")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 4)
    }

    private var deck: some View {
        GeometryReader { proxy in
            // 多出来的 44pt 让卡片一直延伸到底部标签栏后面，而不是在栏上方被截断
            let cardHeight = proxy.size.height + 44
            ZStack(alignment: .top) {
                ForEach(stack, id: \.item.id) { entry in
                    stackedCard(entry, height: cardHeight)
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .padding(.top, 30)
    }

    @ViewBuilder
    private func stackedCard(_ entry: (item: Subscription, depth: Int), height: CGFloat) -> some View {
        let card = SubscriptionDeckCard(subscription: entry.item, depth: entry.depth)
            .frame(height: height)
            .scaleEffect(scale(for: entry.depth), anchor: .top)
            .offset(y: offset(for: entry.depth) + (entry.depth == 0 ? drag : 0))
            .zIndex(Double(10 - entry.depth))

        if entry.depth == 0 {
            card
                .gesture(dragGesture)
                .onTapGesture { detail = entry.item }
        } else {
            card.allowsHitTesting(false)
        }
    }

    private func scale(for depth: Int) -> CGFloat {
        switch depth {
        case 0: return 1
        case 1: return 0.945
        default: return 0.89
        }
    }

    private func offset(for depth: Int) -> CGFloat {
        switch depth {
        case 0: return 0
        case 1: return -16
        default: return -30
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                drag = min(0, value.translation.height)
            }
            .onEnded { value in
                if value.translation.height < -70, index < items.count - 1 {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                        drag = -900
                    }
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(210))
                        withAnimation(.easeOut(duration: 0.2)) {
                            index = min(index + 1, items.count - 1)
                            drag = 0
                        }
                    }
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        drag = 0
                    }
                }
            }
    }
}

// MARK: - 顶部：两张白色支出卡

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
        .frame(height: 136, alignment: .topLeading)
        .background(Color.wsCard, in: RoundedRectangle(cornerRadius: WSTheme.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: WSTheme.cardRadius, style: .continuous)
                .strokeBorder(Color.wsHairline, lineWidth: 0.5)
        }
    }
}

private struct SpendTrendCard: View {
    let points: [MonthPoint]
    let total: Money
    let delta: Double?

    @Environment(\.colorScheme) private var scheme

    private var peak: Int64 { max(1, points.map(\.amount.minorUnits).max() ?? 1) }

    var body: some View {
        TallStatCard(title: "本月支出") {
            Text(total.formatted())
                .font(.wsNumber(21, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.top, 3)

            Spacer(minLength: 8)

            HStack(alignment: .bottom, spacing: 4) {
                ForEach(points) { point in
                    let ratio = Double(point.amount.minorUnits) / Double(peak)
                    let isCurrent = point.id == points.last?.id
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(isCurrent ? WSTheme.accent : WSTheme.accent.opacity(scheme == .dark ? 0.34 : 0.18))
                        .frame(height: max(4, 30 * ratio))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 30, alignment: .bottom)

            Spacer(minLength: 8)

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
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.top, 3)

            Spacer(minLength: 8)

            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .stroke(WSTheme.accent.opacity(0.14), lineWidth: 5)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(WSTheme.accent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(pendingCount) 笔待扣")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text("今年已过 \(Int(progress * 100))%")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 2)
        }
    }
}

// MARK: - 黑色订阅卡（可叠放）

private struct SubscriptionDeckCard: View {
    let subscription: Subscription
    var depth: Int = 0

    private var isActive: Bool { subscription.state == .active }

    @Environment(\.colorScheme) private var scheme

    private var surface: Color {
        // 深色模式下页面本来就是黑的，卡片要略微提亮才看得出是一张卡
        switch (depth, scheme) {
        case (0, .dark): return Color(hex: "#1A1B20")
        case (1, .dark): return Color(hex: "#24252C")
        case (_, .dark): return Color(hex: "#2E2F38")
        case (0, _): return Color(hex: "#111216")
        case (1, _): return Color(hex: "#1E1F25")
        default: return Color(hex: "#2B2C34")
        }
    }

    private var primaryText: Color { .white }
    private var secondaryText: Color { .white.opacity(0.55) }
    private var tertiaryText: Color { .white.opacity(0.38) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                IconTile(brand: subscription.brandID,
                         symbol: subscription.symbolName,
                         hex: subscription.tintHex,
                         name: subscription.name,
                         customID: subscription.customIconID,
                         size: 56)

                VStack(alignment: .leading, spacing: 4) {
                    Text(subscription.name)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(primaryText)
                        .lineLimit(1)
                    Text(meta)
                        .font(.system(size: 12))
                        .foregroundStyle(secondaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text(subscription.cycle.shortLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.white.opacity(0.10),
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            Spacer(minLength: 16)

            Text(isActive ? (subscription.isTrial ? "试用结束后" : "下次扣款") : "订阅状态")
                .font(.system(size: 11))
                .foregroundStyle(tertiaryText)

            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(subscription.price.formatted())
                    .font(.wsNumber(42, weight: .bold))
                    .foregroundStyle(primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                Text(countdown)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(countdownTint)
                    .lineLimit(1)
            }
            .padding(.top, 2)

            Spacer(minLength: 18)

            HStack(alignment: .top, spacing: 10) {
                stat("周期", subscription.cycle.displayName)
                stat("上次扣款", subscription.lastBillingDate().map { WSDate.monthDay($0) } ?? "—")
                stat("下次扣款", subscription.nextBillingDate().map { WSDate.monthDay($0) } ?? "—")
            }
            .padding(.bottom, 14)

            if let progress {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule(style: .continuous)
                            .fill(.white.opacity(0.12))
                        Capsule(style: .continuous)
                            .fill(.white.opacity(0.85))
                            .frame(width: max(4, proxy.size.width * progress.fraction))
                    }
                }
                .frame(height: 5)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        // 卡片本身铺到屏幕底部（标签栏后面），但内容要留在标签栏上方
        .padding(.bottom, 104)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(surface, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(.white.opacity(depth == 0 ? 0.06 : 0.10), lineWidth: 0.5)
        }
        .opacity(isActive ? 1 : 0.75)
        .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(tertiaryText)
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 当前计费周期走过的比例：上次扣款 → 下次扣款。试用期用建账日 → 试用结束日。
    private var progress: (start: Date, end: Date, fraction: Double)? {
        guard isActive, !subscription.cycle.isOneTime else { return nil }

        let calendar = Calendar.ws
        let end: Date?
        let start: Date?
        if subscription.isTrial, let trialEnd = subscription.trialEndDate {
            end = calendar.startOfDay(for: trialEnd)
            start = calendar.startOfDay(for: subscription.createdAt)
        } else {
            end = subscription.nextBillingDate()
            start = subscription.lastBillingDate()
        }
        guard let end, let start else { return nil }

        let span = end.timeIntervalSince(start)
        guard span > 0 else { return nil }
        let elapsed = Date().timeIntervalSince(start)
        return (start, end, min(1, max(0, elapsed / span)))
    }

    private var meta: String {
        let cycle = subscription.cycle.displayName
        return subscription.vendor.isEmpty ? cycle : "\(subscription.vendor) · \(cycle)"
    }

    private var countdown: String {
        guard isActive else { return subscription.state.displayName }
        if subscription.isTrial, let days = subscription.trialDaysRemaining {
            return days <= 0 ? "试用今天结束" : "试用还剩 \(days) 天"
        }
        guard let days = subscription.daysUntilNextBilling() else { return "无后续" }
        if days <= 0 { return "今天扣款" }
        if days == 1 { return "明天扣款" }
        if days <= 60 { return "\(days) 天后" }
        return subscription.nextBillingDate().map { WSDate.monthDay($0) } ?? "—"
    }

    private var countdownTint: Color {
        guard isActive else { return .white.opacity(0.5) }
        if subscription.isTrial { return Color(hex: "#C9A6FF") }
        guard let days = subscription.daysUntilNextBilling() else { return .white.opacity(0.5) }
        if days <= 3 { return Color(hex: "#FF9B7A") }
        return .white.opacity(0.55)
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
