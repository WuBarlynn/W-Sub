import Foundation

/// 常用货币清单。只做展示与选择用，符号取各语言里最常见的写法。
public enum CurrencyCatalog {
    public struct Item: Identifiable, Hashable, Sendable {
        public var id: String { code }
        public let code: String
        public let symbol: String
        public let name: String

        public init(code: String, symbol: String, name: String) {
            self.code = code
            self.symbol = symbol
            self.name = name
        }

        public var display: String { "\(symbol) \(code)" }
    }

    public static let common: [Item] = [
        Item(code: "CNY", symbol: "¥", name: "人民币"),
        Item(code: "USD", symbol: "$", name: "美元"),
        Item(code: "HKD", symbol: "HK$", name: "港币"),
        Item(code: "TWD", symbol: "NT$", name: "新台币"),
        Item(code: "JPY", symbol: "¥", name: "日元"),
        Item(code: "EUR", symbol: "€", name: "欧元"),
        Item(code: "GBP", symbol: "£", name: "英镑"),
        Item(code: "KRW", symbol: "₩", name: "韩元"),
        Item(code: "SGD", symbol: "S$", name: "新加坡元"),
        Item(code: "AUD", symbol: "A$", name: "澳元"),
        Item(code: "CAD", symbol: "C$", name: "加元"),
        Item(code: "CHF", symbol: "CHF", name: "瑞士法郎"),
        Item(code: "NZD", symbol: "NZ$", name: "新西兰元"),
        Item(code: "THB", symbol: "฿", name: "泰铢"),
        Item(code: "MYR", symbol: "RM", name: "马币"),
        Item(code: "INR", symbol: "₹", name: "印度卢比"),
        Item(code: "AED", symbol: "AED", name: "迪拉姆"),
        Item(code: "BRL", symbol: "R$", name: "雷亚尔"),
        Item(code: "RUB", symbol: "₽", name: "卢布")
    ]

    public static func item(_ code: String) -> Item? {
        common.first { $0.code == code }
    }

    public static func symbol(_ code: String) -> String {
        item(code)?.symbol ?? code
    }
}
