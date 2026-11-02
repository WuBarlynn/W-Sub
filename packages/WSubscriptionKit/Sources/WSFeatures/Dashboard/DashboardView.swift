#if os(iOS)
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

// MARK: - 首页

public struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showAdd = false

    public init() {}

    private var snapshot: VaultSnapshot { model.snapshot ?? VaultSnapshot() }

    /// 全部订阅，按「下次扣款」排序，暂停的排最后 —— 不再按日期分组。
    private var items: [Subscription] {
        snapshot.subscriptions.sorted { lhs, rhs in
            if lhs.state != .active || rhs.state != .active {
                if lhs.state == rhs.state { return lhs.name < rhs.name }
                return lhs.state == .active
            }
            let l = lhs.nextBillingDate() ?? .distantFuture
            let r = rhs.nextBillingDate() ?? .distantFuture
            if l == r { return lhs.name < rhs.name }
            return l < r
        }
    }

    public var body: some View {
        NavigationStack {
            Screen {
                ScrollView {
                    VStack(spacing: 12) {
                        summary
                        ForEach(items) { item in
                            NavigationLink {
                                SubscriptionDetailView(subscription: item)
                            } label: {
                                SubscriptionCard(subscription: item)
                            }
                            .buttonStyle(.plain)
                        }
                        if items.isEmpty {
                            SurfaceCard {
                                WSEmptyState(symbol: "plus.circle",
                                             title: "还没有订阅",
                                             message: "点右上角添加",
                                             actionTitle: "添加订阅") { showAdd = true }
                            }
                        }
                    }
                    .padding(.horizontal, WSTheme.pagePadding)
                    .padding(.top, 2)
                    .padding(.bottom, 28)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle("订阅")
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

    private var summary: some View {
        let total = snapshot.monthlyTotal()
        return HStack(spacing: 12) {
            SurfaceCard(padding: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("本月")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text(total.formatted())
                        .font(.wsNumber(20, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }
            SurfaceCard(padding: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("下次")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text(nextText)
                        .font(.wsNumber(20, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }
        }
    }

    private var nextText: String {
        guard let next = items.first(where: { $0.state == .active }),
              let date = next.nextBillingDate() else { return "—" }
        let calendar = Calendar.ws
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: Date()), to: date).day ?? 0
        switch days {
        case 0: return "今天"
        case 1: return "明天"
        case 2: return "后天"
        default: return "\(days) 天"
        }
    }
}

// MARK: - 订阅卡片

public struct SubscriptionCard: View {
    private let subscription: Subscription

    public init(subscription: Subscription) {
        self.subscription = subscription
    }

    public var body: some View {
        HStack(spacing: 12) {
            IconTile(brand: subscription.brandID,
                     symbol: subscription.symbolName,
                     hex: subscription.tintHex,
                     name: subscription.name,
                     customID: subscription.customIconID,
                     size: 46)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(subscription.name)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if subscription.isTrial {
                        WSTag("试用", tint: Color(hex: "#8E4EC6"))
                    }
                }
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                Text(subscription.price.formatted())
                    .font(.wsNumber(16, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(trailing)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.secondary.opacity(subscription.state == .active ? 1 : 0.6))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.wsCard, in: RoundedRectangle(cornerRadius: WSTheme.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: WSTheme.cardRadius, style: .continuous)
                .strokeBorder(Color.wsHairline, lineWidth: 0.5)
        }
        .opacity(subscription.state == .active ? 1 : 0.55)
        .contentShape(RoundedRectangle(cornerRadius: WSTheme.cardRadius, style: .continuous))
    }

    private var subtitle: String {
        if subscription.isTrial, let days = subscription.trialDaysRemaining, days >= 0 {
            return "试用还剩 \(days) 天"
        }
        if subscription.state == .paused { return "已暂停" }
        let cycle = subscription.cycle == .oneTime ? "买断" : subscription.cycle.displayName
        return subscription.vendor.isEmpty ? cycle : "\(subscription.vendor) · \(cycle)"
    }

    private var trailing: String {
        if subscription.state != .active { return "—" }
        guard let date = subscription.nextBillingDate() else { return "无后续" }
        let calendar = Calendar.ws
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: Date()), to: date).day ?? 0
        if days <= 0 { return "今天扣款" }
        if days == 1 { return "明天扣款" }
        return WSDate.monthDay(date)
    }
}

// MARK: - 兼容旧调用的行视图

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
