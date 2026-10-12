import Foundation
import Observation
import UserNotifications

/// A weekly local notification prompting a coach review. The notification itself
/// carries no health data; the review only runs once the app is opened from it.
@Observable
final class WeeklyReminder: NSObject, UNUserNotificationCenterDelegate {
    private nonisolated static let identifier = "weekly-review"
    private static let enabledKey = "weeklyReminderEnabled"
    private static let weekdayKey = "weeklyReminderWeekday"
    private static let minuteKey = "weeklyReminderMinute"

    private(set) var isEnabled: Bool
    /// 1 is Sunday, matching `Calendar`.
    private(set) var weekday: Int
    private(set) var minuteOfDay: Int
    /// The user has refused notifications for this app in system settings.
    private(set) var isDenied = false
    /// Set when the app was opened from the reminder; cleared by whoever acts on it.
    var openedFromReminder = false

    override init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        weekday = defaults.object(forKey: Self.weekdayKey) as? Int ?? 1
        minuteOfDay = defaults.object(forKey: Self.minuteKey) as? Int ?? 18 * 60
        super.init()
        // Must be in place before launch finishes so a tap that starts the app is delivered.
        UNUserNotificationCenter.current().delegate = self
    }

    /// Turns the reminder on or off, or moves it. Asks for permission the first time.
    func update(enabled: Bool, weekday: Int, minuteOfDay: Int) async {
        let center = UNUserNotificationCenter.current()
        var enabled = enabled
        if enabled {
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            isDenied = !granted
            enabled = granted
        }
        self.isEnabled = enabled
        self.weekday = weekday
        self.minuteOfDay = minuteOfDay
        let defaults = UserDefaults.standard
        defaults.set(enabled, forKey: Self.enabledKey)
        defaults.set(weekday, forKey: Self.weekdayKey)
        defaults.set(minuteOfDay, forKey: Self.minuteKey)

        center.removePendingNotificationRequests(withIdentifiers: [Self.identifier])
        guard enabled else { return }
        let content = UNMutableNotificationContent()
        content.title = "Weekly review"
        content.body = "Open Long Game to review your training week with the coach."
        content.sound = .default
        let when = DateComponents(hour: minuteOfDay / 60, minute: minuteOfDay % 60, weekday: weekday)
        let trigger = UNCalendarNotificationTrigger(dateMatching: when, repeats: true)
        try? await center.add(UNNotificationRequest(identifier: Self.identifier, content: content, trigger: trigger))
    }

    /// Picks up a permission change made in system settings while the app was away.
    func refresh() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        isDenied = status == .denied
        if isDenied, isEnabled { await update(enabled: false, weekday: weekday, minuteOfDay: minuteOfDay) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.notification.request.identifier == Self.identifier else { return }
        await MainActor.run { openedFromReminder = true }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
