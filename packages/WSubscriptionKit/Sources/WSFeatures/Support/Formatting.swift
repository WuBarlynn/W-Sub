#if os(iOS)
import Foundation
import WSCore

/// 界面统一用中文日期，避免系统语言是英文时出现「Saturday Nov 7」这种混排。
public enum WSDate {
    public static let locale = Locale(identifier: "zh_Hans_CN")

    public static func monthDay(_ date: Date) -> String {
        date.formatted(.dateTime.month().day().locale(locale))
    }

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
