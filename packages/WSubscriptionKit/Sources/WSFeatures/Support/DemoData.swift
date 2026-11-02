#if os(iOS)
import Foundation
import WSCore

#if DEBUG
/// 仅用于开发与截图预览（通过 `-ws-demo` 启动参数触发）。
public enum DemoData {
    public static func snapshot() -> VaultSnapshot {
        var snapshot = VaultSnapshot()
        snapshot.settings.primaryCurrency = "CNY"
        snapshot.settings.monthlyBudgetMinor = 50_000
        snapshot.settings.biometryEnabled = false

        let calendar = Calendar.ws
        func daysAgo(_ days: Int) -> Date {
            calendar.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        }
        func daysAhead(_ days: Int) -> Date {
            calendar.date(byAdding: .day, value: days, to: Date()) ?? Date()
        }

        snapshot.subscriptions = [
            Subscription(name: "Netflix", vendor: "Netflix", categoryID: "streaming",
                         price: Money(minorUnits: 8_800, currencyCode: "CNY"), cycle: .monthly,
                         anchorDate: daysAgo(205), symbolName: "play.tv.fill", tintHex: "#141414", brandID: "netflix",
                         priceHistory: [PriceChange(date: daysAgo(120), from: Money(minorUnits: 7_800, currencyCode: "CNY"), to: Money(minorUnits: 8_800, currencyCode: "CNY"))]),
            Subscription(name: "Spotify", vendor: "Spotify", categoryID: "music",
                         price: Money(minorUnits: 1_500, currencyCode: "CNY"), cycle: .monthly,
                         anchorDate: daysAgo(208), symbolName: "music.note", tintHex: "#1DB954", brandID: "spotify"),
            Subscription(name: "iCloud+ 200GB", vendor: "Apple", categoryID: "cloud",
                         price: Money(minorUnits: 2_100, currencyCode: "CNY"), cycle: .monthly,
                         anchorDate: daysAgo(190), symbolName: "icloud.fill", tintHex: "#3B99FC", brandID: "icloud-plus"),
            Subscription(name: "ChatGPT Plus", vendor: "OpenAI", categoryID: "ai",
                         price: Money(minorUnits: 14_000, currencyCode: "CNY"), cycle: .monthly,
                         anchorDate: daysAgo(185), symbolName: "sparkles", tintHex: "#0D0D0D", brandID: "chatgpt"),
            Subscription(name: "腾讯视频", vendor: "腾讯", categoryID: "streaming",
                         price: Money(minorUnits: 25_000, currencyCode: "CNY"), cycle: .quarterly,
                         anchorDate: daysAgo(158), symbolName: "play.tv.fill", tintHex: "#FF6022", brandID: "tencent-video"),
            Subscription(name: "Disney+ 试用", vendor: "Disney", categoryID: "streaming",
                         price: Money(minorUnits: 6_800, currencyCode: "CNY"), cycle: .monthly,
                         anchorDate: daysAgo(3), isTrial: true, trialEndDate: daysAhead(4),
                         symbolName: "play.rectangle.fill", tintHex: "#0E1B4D", brandID: "disney-plus"),
            Subscription(name: "Keep 会员", vendor: "Keep", categoryID: "fitness",
                         price: Money(minorUnits: 21_800, currencyCode: "CNY"), cycle: .annually,
                         anchorDate: daysAgo(200), symbolName: "figure.run", tintHex: "#1FB6C9", brandID: "keep"),
            Subscription(name: "微信读书", vendor: "腾讯", categoryID: "news",
                         price: Money(minorUnits: 1_900, currencyCode: "CNY"), cycle: .monthly,
                         anchorDate: daysAgo(197), symbolName: "book.fill", tintHex: "#1AAD19", brandID: "weread"),
            Subscription(name: "优酷", vendor: "阿里巴巴", categoryID: "streaming",
                         price: Money(minorUnits: 1_900, currencyCode: "CNY"), cycle: .monthly,
                         anchorDate: daysAgo(192), state: .paused, symbolName: "play.tv.fill", tintHex: "#1BA6E2", brandID: "youku")
        ]
        return snapshot
    }
}
#endif
#endif
