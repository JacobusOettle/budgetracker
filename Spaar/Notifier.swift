import Foundation
import UserNotifications

enum Notifier {
    static func requestAuthorization() async {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])
    }

    static func post(title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}

/// Daily "any payments missing?" reminder, for online purchases and taps the
/// automation missed.
enum ReminderScheduler {
    static let identifier = "missed-payment-reminder"
    static let enabledKey = "reminder.enabled"
    static let hourKey = "reminder.hour"
    static let minuteKey = "reminder.minute"
    static let defaultHour = 20

    static func apply(defaults: UserDefaults = .standard) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        let enabled = defaults.object(forKey: enabledKey) as? Bool ?? true
        guard enabled else { return }
        var time = DateComponents()
        time.hour = defaults.object(forKey: hourKey) as? Int ?? defaultHour
        time.minute = defaults.object(forKey: minuteKey) as? Int ?? 0

        let content = UNMutableNotificationContent()
        content.title = "Any payments missing?"
        content.body = "Add online purchases or anything Spaar didn't catch today."
        content.sound = .default
        let trigger = UNCalendarNotificationTrigger(dateMatching: time, repeats: true)
        try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
    }
}
