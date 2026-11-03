#if os(iOS)
import Foundation
import WSCore

/// 界面统一用中文日期，避免系统语言是英文时出现「Saturday Nov 7」这种混排。
public enum WSDate {
    public static let locale = Locale(identifier: "zh_Hans_CN")

    public static func monthDay(_ date: Date) -> String {
        date.formatted(.dateTime.month().day().locale(locale))
    }

    /// 月日 + 年份：同年只显示月日，跨年才带年份（例如「11月7日」「2027年1月3日」）。
    /// 主页卡片、订阅列表这类紧凑场景用，避免常年重复显示当年年份。
    public static func monthDayWithYear(_ date: Date, now: Date = Date(), calendar: Calendar = .ws) -> String {
        let isThisYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        if isThisYear {
            return date.formatted(.dateTime.month().day().locale(locale))
        }
        return date.formatted(.dateTime.year().month().day().locale(locale))
    }

    /// 始终带年份（详情页、导出等需要完整日期的场景）。
    public static func full(_ date: Date) -> String {
        date.formatted(.dateTime.year().month().day().locale(locale))
    }

    public static func weekdayWide(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).locale(locale))
    }

    public static func monthAbbrev(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).locale(locale))
    }

    /// 今天 / 明天 / 后天 / 周三
    public static func relativeDay(_ date: Date, calendar: Calendar = .ws) -> String {
        if calendar.isDateInToday(date) { return "今天" }
        if calendar.isDateInTomorrow(date) { return "明天" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: Date()), to: date).day ?? 0
        if days == 2 { return "后天" }
        return date.formatted(.dateTime.weekday(.wide).locale(locale))
    }
}
#endif
