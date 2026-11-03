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

/// 独立成一个视图。卡片叠用 UIKit 驱动：`UIPanGestureRecognizer` 每帧直接改 `layer.transform`
/// （Core Animation 合成），绕过 SwiftUI 的视图 diff 管线，ProMotion 屏可跑满 120Hz。
/// 卡片本身仍是 SwiftUI（`UIHostingController`），只是「拖动/翻页」这个高频操作交给 UIKit。
@MainActor
private struct SubscriptionDeck: UIViewRepresentable {
    let items: [Subscription]
    @Binding var index: Int
    let onSelect: (Subscription) -> Void

    private let stackGap: CGFloat = 10

    func makeCoordinator() -> Coordinator {
        Coordinator(items: items, index: $index, onSelect: onSelect, stackGap: stackGap)
    }

    func makeUIView(context: Context) -> DeckView {
        let view = DeckView(coordinator: context.coordinator)
        view.rebuild()
        return view
    }

    func updateUIView(_ view: DeckView, context: Context) {
        view.coordinator.items = items
        view.coordinator.onSelect = onSelect
        view.coordinator.isDark = context.environment.colorScheme == .dark
        view.rebuild()
    }

    // MARK: - UIKit 卡片叠视图

    @MainActor
    final class DeckView: UIView {
        let coordinator: Coordinator
        var cardViews: [(container: UIView, hosting: UIHostingController<SubscriptionDeckCard>, dimLayer: CALayer)] = []

        init(coordinator: Coordinator) {
            self.coordinator = coordinator
            super.init(frame: .zero)
            clipsToBounds = true
            isMultipleTouchEnabled = false
            backgroundColor = .clear

            let pan = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.handlePan(_:)))
            pan.maximumNumberOfTouches = 1
            addGestureRecognizer(pan)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func layoutSubviews() {
            super.layoutSubviews()
            coordinator.cardHeight = max(300, bounds.height - coordinator.stackGap * 2.4)
            applyTransforms(animated: false)
        }

        func rebuild() {
            cardViews.forEach { $0.hosting.view.removeFromSuperview() }
            cardViews = []
            let indices = coordinator.visibleIndices
            for i in indices {
                let item = coordinator.items[i]
                let card = SubscriptionDeckCard(subscription: item, isDark: coordinator.isDark)
                let hosting = UIHostingController(rootView: card)
                hosting.view.backgroundColor = .clear
                let container = UIView()
                container.backgroundColor = .clear
                container.clipsToBounds = true
                container.layer.cornerRadius = 32
                container.layer.cornerCurve = .continuous
                container.addSubview(hosting.view)
                // 压黑层
                let dim = CALayer()
                dim.backgroundColor = UIColor.black.cgColor
                dim.cornerRadius = 32
                dim.cornerCurve = .continuous
                dim.isHidden = true
                container.layer.addSublayer(dim)
                // 后面的卡先加（在下面），当前卡最后加（在上面）
                addSubview(container)
                cardViews.append((container, hosting, dim))
            }
            setNeedsLayout()
            layoutIfNeeded()
            // 点击进详情（只响应当前卡）
            let tap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleTap(_:)))
            addGestureRecognizer(tap)
        }

        /// 层级：用 subview 顺序表达（bringSubviewToFront）。
        /// 上滑时当前卡最上；下滑返回时上一张升到最上。后面的卡按距离排在下面。
        func arrangeZOrder() {
            let current = coordinator.index.wrappedValue
            let returning = coordinator.position < CGFloat(current)
            // 先全部移到最底，再按「从后往前」的顺序叠上来
            for entry in cardViews { sendSubviewToBack(entry.container) }
            for (i, entry) in cardViews.enumerated() {
                let itemIndex = coordinator.visibleIndices[i]
                if itemIndex == current { bringSubviewToFront(entry.container) }
                else if itemIndex == current - 1, returning { bringSubviewToFront(entry.container) }
            }
        }

        func applyTransforms(animated: Bool, completion: ((Bool) -> Void)? = nil) {
            let height = coordinator.cardHeight
            let width = bounds.width
            let gap = coordinator.stackGap
            for (i, entry) in cardViews.enumerated() {
                let itemIndex = coordinator.visibleIndices[i]
                let d = CGFloat(itemIndex) - coordinator.position
                let container = entry.container
                container.frame = CGRect(x: 0, y: 0, width: width, height: height)
                entry.hosting.view.frame = container.bounds
                entry.dimLayer.frame = container.bounds

                // scaleX / offsetY / opacity —— 全部写进 layer，Core Animation 合成
                let scaleX = d >= 0 ? 1 - 0.05 * min(2, d) : 1
                let offsetY: CGFloat = d >= 0 ? gap * d : d * height
                let opacity = d >= 0 ? max(0.24, 1 - 0.42 * min(2, d)) : 1

                let transform = CGAffineTransform(translationX: 0, y: offsetY)
                    .scaledBy(x: scaleX, y: 1)
                let animations = {
                    container.layer.transform = CATransform3DMakeAffineTransform(transform)
                    container.layer.opacity = Float(opacity)
                    entry.hosting.view.layer.transform = CATransform3DIdentity
                    entry.hosting.view.layer.opacity = 1
                    // 后面的卡叠一层黑（d > 0）
                    entry.dimLayer.isHidden = d <= 0
                    entry.dimLayer.opacity = d > 0 ? Float(0.22 * min(2, d)) : 0
                    // 层级：下滑返回时上一张在最上
                    self.arrangeZOrder()
                }
                if animated {
                    UIView.animate(withDuration: 0.36, delay: 0,
                                   usingSpringWithDamping: 0.9,
                                   initialSpringVelocity: 0,
                                   options: [.allowUserInteraction, .beginFromCurrentState],
                                   animations: animations, completion: completion)
                } else {
                    animations()
                    completion?(true)
                }
            }
        }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject {
        var items: [Subscription]
        var index: Binding<Int>
        var onSelect: (Subscription) -> Void
        let stackGap: CGFloat

        var isDark: Bool = false
        var position: CGFloat = 0
        var cardHeight: CGFloat = 420
        private var dragStartPosition: CGFloat = 0
        private var dragStartY: CGFloat = 0

        init(items: [Subscription], index: Binding<Int>, onSelect: @escaping (Subscription) -> Void, stackGap: CGFloat) {
            self.items = items
            self.index = index
            self.onSelect = onSelect
            self.stackGap = stackGap
        }

        var visibleIndices: [Int] {
            guard !items.isEmpty else { return [] }
            let current = index.wrappedValue
            let lower = max(0, current - 1)
            let upper = min(items.count - 1, current + 2)
            guard lower <= upper else { return [] }
            return Array(lower...upper)
        }

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view as? DeckView else { return }
            switch gesture.state {
            case .began:
                dragStartPosition = position
                dragStartY = gesture.translation(in: view).y
            case .changed:
                let dy = gesture.translation(in: view).y - dragStartY
                let delta = -dy / max(1, cardHeight)
                position = rubberBand(dragStartPosition + delta)
                view.applyTransforms(animated: false)
            case .ended, .cancelled:
                let translation = -gesture.translation(in: view).y / max(1, cardHeight)
                let velocity = gesture.velocity(in: view).y
                let predicted = -velocity * 0.25 / max(1, cardHeight)
                let base = dragStartPosition.rounded()
                var target = base
                if translation > 0.18 || predicted > 0.45 {
                    target = base + 1
                } else if translation < -0.18 || predicted < -0.45 {
                    target = base - 1
                }
                target = min(max(0, target), CGFloat(max(0, items.count - 1)))
                position = target
                view.applyTransforms(animated: true) { _ in
                    let settled = Int(self.position.rounded())
                    if settled != self.index.wrappedValue {
                        DispatchQueue.main.async { self.index.wrappedValue = settled }
                    }
                }
            default:
                break
            }
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            let point = gesture.location(in: gesture.view)
            guard let view = gesture.view as? DeckView else { return }
            // 只响应当前卡
            let current = index.wrappedValue
            for (i, entry) in view.cardViews.enumerated() where visibleIndices[i] == current {
                if entry.container.frame.contains(point) {
                    onSelect(items[current])
                    return
                }
            }
        }

        private func rubberBand(_ value: CGFloat) -> CGFloat {
            let maxIndex = CGFloat(max(0, items.count - 1))
            if value < 0 { return value * 0.28 }
            if value > maxIndex { return maxIndex + (value - maxIndex) * 0.28 }
            return value
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

    /// 拖动时外层每帧都会重建这个值；相等就跳过 body，避免整张卡重排。
    /// 卡片不持有任何随 position 变化的字段，淡入效果在 deck 层的 overlay 上完成。
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
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .strokeBorder(.white.opacity(colorScheme == .dark ? 0.12 : 0.05), lineWidth: 0.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
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
        // 顶部横条覆盖卡片顶部两个圆角，避免圆角处露出深色背景形成黑边
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 32, bottomLeadingRadius: 0,
                                          bottomTrailingRadius: 0, topTrailingRadius: 32,
                                          style: .continuous))
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
                            Text(WSDate.monthDayWithYear(date))
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
                stat("上次扣款", subscription.isTrial ? "—" : (subscription.lastBillingDate().map { WSDate.monthDayWithYear($0) } ?? "—"))
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
                        in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
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
        return subscription.nextBillingDate().map { WSDate.monthDayWithYear($0) } ?? "—"
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
            return WSDate.monthDayWithYear(date)
        case .dayCount:
            guard let days = subscription.daysUntilNextBilling() else { return "—" }
            return days <= 0 ? "今天" : "\(days) 天"
        }
    }
}
#endif
