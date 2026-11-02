#if os(iOS)
import SwiftUI
import WSDesignSystem
import WSCore

struct TemplatePickerView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var selected: SubscriptionTemplate?
    @State private var showCustom = false

    private var currency: String { model.snapshot?.settings.primaryCurrency ?? "CNY" }

    private let columns = [GridItem(.adaptive(minimum: 92), spacing: 10)]

    var body: some View {
        NavigationStack {
            Screen {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if query.isEmpty {
                            ForEach(sections, id: \.0.id) { category, templates in
                                VStack(alignment: .leading, spacing: 10) {
                                    WSSectionTitle(category.name)
                                    grid(templates)
                                }
                            }
                        } else {
                            let results = TemplateCatalog.search(query)
                            if results.isEmpty {
                                WSEmptyState(symbol: "magnifyingglass",
                                             title: "没有找到",
                                             message: "可以直接从空白开始，或稍后在编辑页搜索在线图标")
                            } else {
                                grid(results)
                            }
                        }

                        Button {
                            showCustom = true
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "square.and.pencil")
                                Text("从空白开始")
                                    .font(.system(size: 15, weight: .medium))
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.roundedRectangle(radius: 14))
                    }
                    .padding(.horizontal, WSTheme.pagePadding)
                    .padding(.bottom, 28)
                }
            }
            .navigationTitle("添加订阅")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "搜索 Netflix、腾讯视频…")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .sheet(item: $selected) { template in
                SubscriptionEditorView(template: template, currency: currency)
            }
            .sheet(isPresented: $showCustom) {
                SubscriptionEditorView(currency: currency)
            }
        }
    }

    private func grid(_ templates: [SubscriptionTemplate]) -> some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(templates) { template in
                TemplateCell(template: template)
                    .onTapGesture { selected = template }
            }
        }
    }

    private var sections: [(WSCore.Category, [SubscriptionTemplate])] {
        let categories = model.snapshot?.sortedCategories ?? Category.builtIns
        return categories.compactMap { category in
            let templates = TemplateCatalog.inCategory(category.id)
            return templates.isEmpty ? nil : (category, templates)
        }
    }
}

struct TemplateCell: View {
    let template: SubscriptionTemplate

    var body: some View {
        VStack(spacing: 7) {
            IconTile(brand: template.brand,
                     symbol: template.symbol,
                     hex: template.hex,
                     name: template.name,
                     size: 42)
            Text(template.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color.wsCard, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.wsHairline, lineWidth: 0.5)
        }
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
#endif
