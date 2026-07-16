import Foundation
import UserNotifications

/// Local notifications for one-off reminders.
@MainActor
enum NotificationService {

    static func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        default:
            return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        }
    }

    static func schedule(for reminder: Reminder) {
        guard reminder.dueDate > Date() else { return }

        let content = UNMutableNotificationContent()
        content.title = reminder.title
        content.body = "Reminder from Loom"
        content.sound = .default

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: reminder.dueDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(
            identifier: reminder.notificationId,
            content: content,
            trigger: trigger
        )
        BlockNotificationService.addDirectRequestMakingRoom(request)
    }

    static func cancel(_ reminder: Reminder) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [reminder.notificationId])
        center.removeDeliveredNotifications(withIdentifiers: [reminder.notificationId])
    }
}
