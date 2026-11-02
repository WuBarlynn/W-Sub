import Foundation

public struct SubscriptionTemplate: Identifiable, Hashable, Sendable, Decodable {
    public var id: String
    public var name: String
    public var vendor: String
    public var categoryID: String
    /// 内置品牌图标名（Assets 中没有对应资源时为 nil）
    public var brand: String?
    /// color = 自带背景的全彩标；mono = 单色标，由界面铺底色
    public var style: String
    /// 品牌主色（用于文字、图表）
    public var hex: String
    /// 图标方块底色（多数等于品牌色，流媒体多为深色）
    public var tile: String
    public var symbol: String
    public var defaultCycle: BillingCycle
    public var aliases: [String]
    public var popularity: Int

    public init(id: String, name: String, vendor: String, categoryID: String, brand: String?,
                style: String = "mono", hex: String, tile: String? = nil,
                symbol: String, defaultCycle: BillingCycle, aliases: [String], popularity: Int) {
        self.id = id
        self.name = name
        self.vendor = vendor
        self.categoryID = categoryID
        self.brand = brand
        self.style = style
        self.hex = hex
        self.tile = tile ?? hex
        self.symbol = symbol
        self.defaultCycle = defaultCycle
        self.aliases = aliases
        self.popularity = popularity
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, vendor, categoryID, brand, style, hex, tile, symbol, defaultCycle, aliases, popularity
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        vendor = try c.decodeIfPresent(String.self, forKey: .vendor) ?? ""
        categoryID = try c.decode(String.self, forKey: .categoryID)
        brand = try c.decodeIfPresent(String.self, forKey: .brand)
        style = try c.decodeIfPresent(String.self, forKey: .style) ?? "mono"
        hex = try c.decodeIfPresent(String.self, forKey: .hex) ?? "#7C7C86"
        tile = try c.decodeIfPresent(String.self, forKey: .tile) ?? hex
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? "creditcard.fill"
        defaultCycle = try c.decodeIfPresent(BillingCycle.self, forKey: .defaultCycle) ?? .monthly
        aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
        popularity = try c.decodeIfPresent(Int.self, forKey: .popularity) ?? 40
    }
}

/// 预置模板库。模板只描述「结构与默认值」，不写死价格 —— 价格随时会变，写死等于骗人。
public enum TemplateCatalog {
    public static let all: [SubscriptionTemplate] = load()

    public static func popular(limit: Int = 12) -> [SubscriptionTemplate] {
        Array(all.sorted { $0.popularity > $1.popularity }.prefix(limit))
    }

    public static func inCategory(_ id: String) -> [SubscriptionTemplate] {
        all.filter { $0.categoryID == id }.sorted { $0.popularity > $1.popularity }
    }

    public static func search(_ query: String) -> [SubscriptionTemplate] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return all.sorted { $0.popularity > $1.popularity } }
        return all
            .filter { template in
                template.name.lowercased().contains(trimmed)
                || template.vendor.lowercased().contains(trimmed)
                || template.id.contains(trimmed)
                || template.aliases.contains { $0.lowercased().contains(trimmed) }
            }
            .sorted { $0.popularity > $1.popularity }
    }

    public static func template(id: String) -> SubscriptionTemplate? {
        all.first { $0.id == id }
    }

    private static func load() -> [SubscriptionTemplate] {
        guard let url = Bundle.module.url(forResource: "templates", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            assertionFailure("模板库缺失")
            return []
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            assertionFailure("模板库解析失败")
            return []
        }
        return payload.templates
    }

    private struct Payload: Decodable {
        var templates: [SubscriptionTemplate]
    }
}
