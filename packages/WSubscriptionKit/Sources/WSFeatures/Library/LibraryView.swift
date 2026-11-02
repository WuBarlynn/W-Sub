#if os(iOS)
import SwiftUI
import WSDesignSystem
import WSCore

public struct LibraryView: View {
    @EnvironmentObject private var model: AppModel

    @State private var query = ""
    @State private var mode: Mode = .time
    @State private var showAdd = false

    public init() {}

    enum Mode: String, CaseIterable, Identifiable {
        case time, category
        var id: String { rawValue }
        var title: String { self == .time ? "按时间" : "按分类" }
    }

    private var snapshot: VaultSnapshot { model.snapshot ?? VaultSnapshot() }

    private var filtered: [Subscription] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return snapshot.subscriptions }
        return snapshot.subscriptions.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed)
            || $0.vendor.localizedCaseInsensitiveContains(trimmed)
            || $0.tags.contains { $0.localizedCaseInsensitiveContains(trimmed) }
        }
    }

    private var byTime: [(String, [Subscription])] {
        let active = filtered.filter { $0.state == .active }
            .sorted { ($0.nextBillingDate() ?? .distantFuture) < ($1.nextBillingDate() ?? .distantFuture) }
        let inactive = filtered.filter { $0.state != .active }
        var sections: [(String, [Subscription])] = []
        if !active.isEmpty { sections.append(("进行中", active)) }
        if !inactive.isEmpty { sections.append(("已暂停 / 已结束", inactive)) }
        return sections
    }

    private var byCategory: [(WSCore.Category, [Subscription])] {
        snapshot.sortedCategories.compactMap { category in
            let items = filtered.filter { $0.categoryID == category.id }
            return items.isEmpty ? nil : (category, items)
        }
    }

    public var body: some View {
        NavigationStack {
            Screen {
                List {
                    if filtered.isEmpty {
                        WSEmptyState(symbol: "tray",
                                     title: query.isEmpty ? "还没有订阅" : "没有匹配的订阅",
                                     message: query.isEmpty ? "点右上角 + ，从 177 个常见服务里选一个" : "换个关键词试试")
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    } else if mode == .time {
                        ForEach(byTime, id: \.0) { title, items in
                            Section {
                                rows(items, trailing: .priceAndDate)
                            } header: {
                                sectionHeader(title, count: items.count)
                            }
                        }
                    } else {
                        ForEach(byCategory, id: \.0.id) { category, items in
                            Section {
                                rows(items, trailing: .priceAndCycle)
                            } header: {
                                sectionHeader(category.name, count: items.count)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索订阅")
            }
            .navigationTitle("全部订阅")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("排序", selection: $mode) {
                            ForEach(Mode.allCases) { item in
                                Label(item.title, systemImage: item == .time ? "clock" : "square.grid.2x2")
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .accessibilityLabel("切换排序")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAdd = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 15, weight: .semibold))
                    }
                }
            }
            .sheet(isPresented: $showAdd) {
                TemplatePickerView()
            }
        }
    }

    private func rows(_ items: [Subscription], trailing: SubscriptionRowCell.Trailing) -> some View {
        ForEach(items) { subscription in
            NavigationLink {
                SubscriptionDetailView(subscription: subscription)
            } label: {
                SubscriptionRowCell(subscription: subscription, trailing: trailing)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    Task { await model.delete(subscription) }
                } label: {
                    Label("删除", systemImage: "trash")
                }
                Button {
                    Task { await model.togglePause(subscription) }
                } label: {
                    Label(subscription.state == .paused ? "恢复" : "暂停",
                          systemImage: subscription.state == .paused ? "play.fill" : "pause.fill")
                }
                .tint(.orange)
            }
        }
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(count)")
                .foregroundStyle(.tertiary)
        }
        .font(.system(size: 13, weight: .medium))
        .textCase(nil)
    }
}
#endif
