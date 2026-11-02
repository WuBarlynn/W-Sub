#if os(iOS)
import SwiftUI
import WSDesignSystem
import WSCore

public struct SubscriptionDetailView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private let original: Subscription
    @State private var showEditor = false
    @State private var confirmDelete = false

    public init(subscription: Subscription) {
        self.original = subscription
    }

    private var subscription: Subscription {
        model.snapshot?.subscriptions.first(where: { $0.id == original.id }) ?? original
    }

    private var category: WSCore.Category {
        model.snapshot?.category(id: subscription.categoryID) ?? .fallback
    }

    public var body: some View {
        Screen {
            ScrollView {
                VStack(spacing: 18) {
                    header
                    timelineCard
                    infoCard
                    actionSection
                }
                .padding(.horizontal, WSTheme.pagePadding)
                .padding(.bottom, 32)
            }
        }
        .navigationTitle(subscription.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("编辑") { showEditor = true }
                    .font(.system(size: 15, weight: .medium))
            }
        }
        .sheet(isPresented: $showEditor) {
            SubscriptionEditorView(subscription: subscription,
                                   currency: model.snapshot?.settings.primaryCurrency ?? "CNY")
        }
        .confirmationDialog("删除这条订阅？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                Task {
                    await model.delete(subscription)
                    dismiss()
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会从列表和统计里移除。已经付过的钱仍可凭备份文件找回。")
        }
    }

    // MARK: 头部

    private var header: some View {
        SurfaceCard(padding: 18) {
            HStack(alignment: .top, spacing: 14) {
                IconTile(brand: subscription.brandID,
                         symbol: subscription.symbolName,
                         hex: subscription.tintHex,
                         name: subscription.name,
                         customID: subscription.customIconID,
                         size: 58)

                VStack(alignment: .leading, spacing: 5) {
                    Text(subscription.name)
                        .font(.system(size: 19, weight: .semibold))
                        .lineLimit(2)
                    Text(subscription.vendor.isEmpty ? category.name : "\(subscription.vendor) · \(category.name)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(subscription.price.formatted())
                            .font(.wsNumber(26, weight: .semibold))
                        Text(subscription.cycle.shortLabel)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if subscription.cycle != .oneTime {
                HStack(spacing: 10) {
                    label("月均 \(subscription.monthlyEquivalent.formatted())")
                    label("年均 \(subscription.annualEquivalent.formatted())")
                    if subscription.isTrial, let days = subscription.trialDaysRemaining {
                        label("试用剩 \(days) 天", tint: Color(hex: "#8E4EC6"))
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 4)
            }
        }
    }

    private func label(_ text: String, tint: Color = .secondary) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    // MARK: 扣款时间线

    private var timelineCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            WSSectionTitle("扣款时间线")
            SurfaceCard(padding: 4) {
                VStack(spacing: 0) {
                    let rows = timelineRows
                    if rows.isEmpty {
                        Text("一次性买断，没有后续扣款")
                            .font(.wsMeta)
                            .foregroundStyle(.secondary)
                            .padding(16)
                    } else {
                        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                            timelineRow(row)
                            if index < rows.count - 1 {
                                WSRowDivider(inset: 16)
                            }
                        }
                    }
                }
            }
        }
    }

    private struct TimelineRow {
        let date: Date
        let amount: Money
        let isPast: Bool
    }

    private var timelineRows: [TimelineRow] {
        guard subscription.cycle != .oneTime else { return [] }
        var rows: [TimelineRow] = []
        let calendar = Calendar.ws
        let now = Date()

        // 过去两笔
        if let pastStart = calendar.date(byAdding: .month, value: -14, to: now) {
            let dates = subscription.cycle.dates(in: DateInterval(start: pastStart, end: now),
                                                 anchor: subscription.anchorDate)
            for date in dates.suffix(2) {
                rows.append(TimelineRow(date: date,
                                        amount: subscription.price,
                                        isPast: true))
            }
        }

        // 未来三笔
        var cursor = now
        for _ in 0..<3 {
            guard let next = subscription.cycle.nextDate(after: cursor, anchor: subscription.anchorDate) else { break }
            rows.append(TimelineRow(date: next, amount: subscription.price, isPast: false))
            cursor = next
        }
        return rows
    }

    private func timelineRow(_ row: TimelineRow) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(row.isPast ? Color.wsHairline : Color(hex: subscription.tintHex).opacity(0.18))
                    .frame(width: 9, height: 9)
                if !row.isPast {
                    Circle()
                        .fill(Color(hex: subscription.tintHex))
                        .frame(width: 5, height: 5)
                }
            }
            .frame(width: 12)

            Text(WSDate.full(row.date))
                .font(.system(size: 14, weight: row.isPast ? .regular : .medium))
                .foregroundStyle(row.isPast ? Color.secondary : Color.primary)

            Spacer()

            if row.isPast {
                Text("已扣款")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            Text(row.amount.formatted())
                .font(.wsNumber(14, weight: row.isPast ? .regular : .medium))
                .foregroundStyle(row.isPast ? Color.secondary : Color.primary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: 信息

    private var infoCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            WSSectionTitle("详情")
            SurfaceCard(padding: 4) {
                VStack(spacing: 0) {
                    infoRow("分类", category.name)
                    WSRowDivider(inset: 16)
                    infoRow("首次扣款", WSDate.full(subscription.anchorDate))
                    WSRowDivider(inset: 16)
                    infoRow("状态", statusText)
                    WSRowDivider(inset: 16)
                    infoRow("提醒", reminderText)
                    if !subscription.note.isEmpty {
                        WSRowDivider(inset: 16)
                        infoRow("备注", subscription.note)
                    }
                }
            }
        }
    }

    private var statusText: String {
        switch subscription.state {
        case .active: return subscription.autoRenew ? "进行中 · 自动续费" : "进行中 · 不自动续费"
        case .paused: return "已暂停"
        case .ended: return "已结束"
        }
    }

    private var reminderText: String {
        let offsets = subscription.reminderOffsets.sorted(by: >)
        guard !offsets.isEmpty else { return "不提醒" }
        return offsets.map { $0 == 0 ? "当天" : "提前 \($0) 天" }.joined(separator: " · ")
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(title)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Text(value)
                .font(.system(size: 14))
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: 操作

    private var actionSection: some View {
        VStack(spacing: 10) {
            Button {
                showEditor = true
            } label: {
                Text("编辑订阅")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 14))

            HStack(spacing: 10) {
                Button {
                    Task { await model.togglePause(subscription) }
                } label: {
                    Label(subscription.state == .paused ? "恢复" : "暂停",
                          systemImage: subscription.state == .paused ? "play.fill" : "pause.fill")
                        .font(.system(size: 14, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.roundedRectangle(radius: 14))

                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Label("删除", systemImage: "trash")
                        .font(.system(size: 14, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.roundedRectangle(radius: 14))
                .tint(Color(hex: "#D9363E"))
            }
        }
        .padding(.top, 2)
    }
}
#endif
