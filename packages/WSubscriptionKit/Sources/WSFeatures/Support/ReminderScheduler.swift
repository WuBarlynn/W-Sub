#if os(iOS)
import Foundation
import SwiftUI
import UserNotifications
import WSCore

/// 续订提醒。iOS 待处理通知有 64 条硬上限，超过部分按「最近触发」优先保留。
public struct ReminderScheduler: Sendable {
    public static let maxScheduled = 56

    public init() {}

    public func reschedule(for snapshot: VaultSnapshot, now: Date = Date()) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            return
        }
        center.removeAllPendingNotificationRequests()

        var candidates: [(date: Date, name: String, amount: String, id: String)] = []
        let calendar = Calendar.ws

        for sub in snapshot.subscriptions where sub.state == .active {
            let offsets = sub.reminderOffsets.isEmpty ? [3] : sub.reminderOffsets
            for offset in offsets.prefix(2) {
                guard let renewal = sub.nextBillingDate(after: now, calendar: calendar) else { continue }
                guard let fireDay = calendar.date(byAdding: .day, value: -offset, to: renewal) else { continue }
                var fire = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: fireDay) ?? fireDay
                if fire < now { continue }
                // 静默时段：22:00–08:00 顺延到 08:00
                let hour = calendar.component(.hour, from: fire)
                if hour >= 22 || hour < 8 {
                    fire = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: fire) ?? fire
                }
                candidates.append((fire, sub.name,
                                   sub.price.formatted(),
                                   "sub.\(sub.id.uuidString).\(offset)"))
            }
        }

        let selected = candidates.sorted { $0.date < $1.date }.prefix(Self.maxScheduled)
        for item in selected {
            let content = UNMutableNotificationContent()
            content.title = item.date.timeIntervalSince(now) > 86_400
                ? "\(item.name) 即将续费"
                : "\(item.name) 明天续费"
            content.body = "\(item.amount) · 可在订阅详情里调整或取消"
            content.sound = .default
            content.threadIdentifier = "renewals"
            content.userInfo = ["subscriptionName": item.name]

            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: item.date)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let request = UNNotificationRequest(identifier: item.id, content: content, trigger: trigger)
            try? await center.add(request)
        }
    }

    public func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }
}
#endif
