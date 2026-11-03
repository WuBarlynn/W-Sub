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

/// 概览 = 两张白色支出卡 + 一叠黑色订阅卡。
/// 卡片严格限制在堆叠区域内滑动（整页不滚），上滑下一张、下滑上一张，
/// 顺序是「离得最近 → 最晚」，最后一张就是最远的那笔扣款。
public struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showAdd = false
    @State private var index = 0
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
            total + sub.billableDates(in: interval, calendar: calendar).count
        }
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
                        SubscriptionDeck(items: items, index: $index) { detail = $0 }
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
            Text("上滑下一张 · 下滑上一张")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - 卡片叠

/// 独立成一个视图，`position` 只在这里变，父视图（支出卡那部分）不会跟着每帧重算。
/// 卡片用固定的 zIndex 和固定的窗口范围，翻页过程中不增删视图，所以不会闪。
private struct SubscriptionDeck: View {
    let items: [Subscription]
    @Binding var index: Int
    let onSelect: (Subscription) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var position: CGFloat = 0
    @State private var dragStart: CGFloat?
    /// 后面的卡向下错开的距离：堆叠在底部露边
    private let stackGap: CGFloat = 11

    var body: some View {
        GeometryReader { proxy in
            let height = max(300, proxy.size.height - stackGap * 2.4)
            ZStack(alignment: .top) {
                ForEach(visible, id: \.item.id) { entry in
                    card(entry, height: height)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipped()
            .contentShape(Rectangle())
            .gesture(dragGesture)
            .onAppear { cardHeight = height }
            .onChange(of: height) { _, newValue in cardHeight = newValue }
        }
    }

    /// 窗口以已提交的 index 为基准：拖动与翻页动画过程中不增删视图。
    private var visible: [(item: Subscription, index: Int)] {
        guard !items.isEmpty else { return [] }
        let lower = max(0, index - 1)
        let upper = min(items.count - 1, index + 2)
        guard lower <= upper else { return [] }
        return (lower...upper).map { (items[$0], $0) }
    }

    private func card(_ entry: (item: Subscription, index: Int), height: CGFloat) -> some View {
        let i = entry.index
        // d 只由 position 决定：0 = 就位，正数 = 堆叠在下面，负数 = 已翻走
        let d = CGFloat(i) - position
        return SubscriptionDeckCard(subscription: entry.item, isDark: colorScheme == .dark)
            .equatable()
            .frame(height: height)
            .overlay {
                // 越靠后的卡压一层黑，层次连续；卡片本体不参与每帧重算
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(.black.opacity(0.26 * Double(min(2, max(0, d)))))
            }
            .scaleEffect(scale(d), anchor: .top)
            .offset(y: offset(d, height: height))
            // 层级在整次拖动中固定，避免动画期间重排
            .zIndex(Double(100 - abs(i - index) * 2))
            .allowsHitTesting(i == index)
            .onTapGesture { if i == index { onSelect(entry.item) } }
    }

    // MARK: 变换：d 的单一连续函数（没有 index 分支，这是消除跳动的关键）

    /// 堆叠中的卡略小；正在翻走的卡保持原尺寸飞出。
    private func scale(_ d: CGFloat) -> CGFloat {
        d >= 0 ? 1 - 0.04 * min(2, d) : 1
    }

    /// d >= 0：堆叠的卡向下错开 stackGap，底部露边；
    /// d < 0：翻走的卡按 1:1 跟手向上飞出（d 每减 1，位移正好一整张卡高）。
    private func offset(_ d: CGFloat, height: CGFloat) -> CGFloat {
        d >= 0 ? stackGap * d : d * height
    }

    // MARK: 手势

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragStart == nil { dragStart = position }
                let start = dragStart ?? position
                position = rubberBand(start - value.translation.height / max(1, cardHeight))
            }
            .onEnded { value in
                let start = dragStart ?? position
                dragStart = nil

                // 位移过卡片高度的 18%，或快速一甩（预测过 45%）才翻页
                let translation = -value.translation.height / max(1, cardHeight)
                let predicted = -value.predictedEndTranslation.height / max(1, cardHeight)
                let base = start.rounded()

                var target = base
                if translation > 0.18 || predicted > 0.45 {
                    target = base + 1
                } else if translation < -0.18 || predicted < -0.45 {
                    target = base - 1
                }
                target = min(max(0, target), CGFloat(max(0, items.count - 1)))

                withAnimation(.spring(response: 0.36, dampingFraction: 0.9)) {
                    position = target
                } completion: {
                    // index 只在动画彻底落位后提交：
                    // 窗口、层级、页码计数都不在拖动中途变化
                    let settled = Int(position.rounded())
                    if settled != index { index = settled }
                }
            }
    }

    /// 手指位移换算成 position 的基准高度（拖动开始时记一次）
    @State private var cardHeight: CGFloat = 420

    private func rubberBand(_ value: CGFloat) -> CGFloat {
        let maxIndex = CGFloat(max(0, items.count - 1))
        if value < 0 { return value * 0.28 }
        if value > maxIndex { return maxIndex + (value - maxIndex) * 0.28 }
        return value
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
        .frame(height: 132, alignment: .topLeading)
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
                        .frame(height: max(4, 28 * ratio))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 28, alignment: .bottom)

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
                .frame(width: 36, height: 36)

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

// MARK: - 黑色订阅卡

private struct SubscriptionDeckCard: View, Equatable {
    nonisolated let subscription: Subscription
    nonisolated let isDark: Bool

    /// 拖动时外层每帧都会重新构建这个值；相等就跳过 body，避免整张卡重排
    nonisolated static func == (lhs: SubscriptionDeckCard, rhs: SubscriptionDeckCard) -> Bool {
        lhs.subscription == rhs.subscription && lhs.isDark == rhs.isDark
    }

    private var colorScheme: ColorScheme { isDark ? .dark : .light }

    private var isActive: Bool { subscription.state == .active }

    /// 深色卡片本体；浅色模式下页面是浅灰，卡片要足够黑才立得住。
    private var surface: Color {
        colorScheme == .dark ? Color(hex: "#2A2C34") : Color(hex: "#141519")
    }



    private var bandText: Color { Color(hex: "#16171B") }

    var body: some View {
        VStack(spacing: 0) {
            headerBand
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(surface)
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(.white.opacity(colorScheme == .dark ? 0.12 : 0.05), lineWidth: 0.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    // 顶部横条：浅色半透明底，图标和名字都放在这条上，深色卡片里也能一眼看清
    private var headerBand: some View {
        HStack(spacing: 10) {
            IconTile(brand: subscription.brandID,
                     symbol: subscription.symbolName,
                     hex: subscription.tintHex,
                     name: subscription.name,
                     customID: subscription.customIconID,
                     size: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text(subscription.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(bandText)
                    .lineLimit(1)
                Text(subscription.vendor.isEmpty ? subscription.cycle.displayName : subscription.vendor)
                    .font(.system(size: 11))
                    .foregroundStyle(bandText.opacity(0.55))
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            HStack(spacing: 5) {
                if !isActive {
                    bandTag(subscription.state.displayName)
                }
                if subscription.isTrial {
                    bandTag("试用")
                }
                bandTag(subscription.cycle.shortLabel)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 62)
        .frame(maxWidth: .infinity)
        .background(.white.opacity(colorScheme == .dark ? 0.88 : 0.92))
    }

    private func bandTag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(bandText.opacity(0.7))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(bandText.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(isActive ? (subscription.isTrial ? "试用结束后" : "下次扣款") : "订阅状态")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
                Spacer(minLength: 8)
                Text(countdown)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(countdownTint)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.white.opacity(0.09),
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .padding(.top, 16)

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(subscription.price.formatted())
                        .font(.wsNumber(38, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    Text(dailyLine)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.38))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }

                Spacer(minLength: 8)

                if let progress {
                    VStack(spacing: 3) {
                    ZStack {
                        Circle()
                            .stroke(.white.opacity(0.12), lineWidth: 6)
                        Circle()
                            .trim(from: 0, to: progress.fraction)
                            .stroke(.white.opacity(0.9),
                                    style: StrokeStyle(lineWidth: 6, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text("\(Int(progress.fraction * 100))%")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                            .monospacedDigit()
                    }
                    .frame(width: 58, height: 58)
                    Text("本期")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.34))
                    }
                }
            }
            .padding(.top, 8)

            if !upcoming.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text("接下来")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.32))
                    ForEach(upcoming, id: \.self) { date in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(.white.opacity(0.22))
                                .frame(width: 4, height: 4)
                            Text(WSDate.monthDay(date))
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.5))
                            Spacer(minLength: 8)
                            Text(subscription.price.formatted())
                                .font(.wsNumber(11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.62))
                        }
                    }
                }
                .padding(.top, 16)
            }

            Spacer(minLength: 14)

            Rectangle()
                .fill(.white.opacity(0.08))
                .frame(height: 0.5)
                .padding(.bottom, 12)

            HStack(alignment: .top, spacing: 10) {
                stat("周期", subscription.cycle.displayName)
                stat("上次扣款", subscription.isTrial ? "—" : (subscription.lastBillingDate().map { WSDate.monthDay($0) } ?? "—"))
                stat("已订", subscribedText)
            }

            Spacer(minLength: 12)

            // 底部淡紫色横条：分类 + 提醒 + 续费方式，一眼扫到结尾
            HStack(spacing: 8) {
                Image(systemName: subscription.autoRenew && isActive
                      ? "arrow.triangle.2.circlepath"
                      : "pause.circle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
                Text(isActive ? categoryName : subscription.state.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)
                Text("·")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
                Text(reminderText)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(subscription.cycle.shortLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .frame(maxWidth: .infinity)
            .background(Color(hex: "#8E7CC3").opacity(0.24),
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Color(hex: "#A996E3").opacity(0.30), lineWidth: 0.5)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 4)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.36))
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var dailyLine: String {
        let daily = subscription.dailyEquivalent.formatted()
        guard subscription.cycle.monthsEquivalent != nil else {
            return "一次性买断"
        }
        return "月均 \(subscription.monthlyEquivalent.formatted()) · 每天约 \(daily)"
    }

    /// 接下来三次扣款（不含已过去的），用来填卡片中段，也让「周期」有具体落点
    private var upcoming: [Date] {
        guard isActive, subscription.cycle.monthsEquivalent != nil else { return [] }
        var result: [Date] = []
        var reference = Date()
        if let first = subscription.nextBillingDate() {
            result.append(first)
            reference = first
        }
        while result.count < 3 {
            guard let next = subscription.cycle.nextDate(after: reference, anchor: subscription.anchorDate)
            else { break }
            if let end = subscription.endDate,
               next > Calendar.ws.startOfDay(for: end) { break }
            result.append(next)
            reference = next
        }
        return result
    }

    private var subscribedText: String {
        let calendar = Calendar.ws
        let days = calendar.dateComponents([.day],
                                           from: calendar.startOfDay(for: subscription.createdAt),
                                           to: calendar.startOfDay(for: Date())).day ?? 0
        if days < 31 { return "\(max(1, days)) 天" }
        let months = days / 30
        if months < 24 { return "\(months) 个月" }
        return "\(months / 12) 年"
    }

    private var categoryName: String {
        Category.builtIns.first { $0.id == subscription.categoryID }?.name ?? "其他"
    }

    private var reminderText: String {
        guard let first = subscription.reminderOffsets.min() else { return "不提醒" }
        return first <= 0 ? "当天提醒" : "提前 \(first) 天提醒"
    }

    private func remainingDays(in progress: (start: Date, end: Date, fraction: Double)) -> Int {
        max(0, Calendar.ws.dateComponents([.day], from: Calendar.ws.startOfDay(for: Date()),
                                          to: Calendar.ws.startOfDay(for: progress.end)).day ?? 0)
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

    private var countdown: String {
        guard isActive else { return subscription.state.displayName }
        if subscription.isTrial, let days = subscription.trialDaysRemaining {
            return days <= 0 ? "今天结束" : "还剩 \(days) 天"
        }
        guard let days = subscription.daysUntilNextBilling() else { return "无后续" }
        if days <= 0 { return "今天" }
        if days == 1 { return "明天" }
        if days <= 60 { return "\(days) 天后" }
        return subscription.nextBillingDate().map { WSDate.monthDay($0) } ?? "—"
    }

    private var countdownTint: Color {
        guard isActive else { return .white.opacity(0.55) }
        if subscription.isTrial { return Color(hex: "#C9A6FF") }
        guard let days = subscription.daysUntilNextBilling() else { return .white.opacity(0.55) }
        if days <= 3 { return Color(hex: "#FF9B7A") }
        return .white.opacity(0.62)
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
