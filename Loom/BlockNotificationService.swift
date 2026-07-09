import Foundation
import UIKit
import UserNotifications
import SwiftData

// MARK: - Block-start nudges

/// Local notifications when a scheduled block begins — the anti-time-blindness
/// alarm. The plan is useless if it only exists inside an app you're not
/// looking at. Notifications are re-synced after every scheduling change;
/// "Start Session" drops straight into the timer, "Snooze 10 min" re-pings
/// without moving the block.
enum BlockNotificationService {

    static let categoryId = "LOOM_BLOCK_START"
    static let startActionId = "LOOM_START_SESSION"
    static let snoozeActionId = "LOOM_SNOOZE_10"
    private static let idPrefix = "block-"

    /// Pending-notification budget (iOS caps at 64 per app; reminders need room too).
    private static let maxBlocks = 20
    private static let horizonDays = 3

    private struct BlockSnapshot {
        let id: UUID
        let taskId: UUID
        let title: String
        let start: Date
        let minutes: Int
        let firstStep: String?
    }

    static func registerCategory() {
        let start = UNNotificationAction(
            identifier: startActionId,
            title: "Start Session",
            options: [.foreground]
        )
        let snooze = UNNotificationAction(
            identifier: snoozeActionId,
            title: "Snooze 10 min",
            options: []
        )
        let category = UNNotificationCategory(
            identifier: categoryId,
            actions: [start, snooze],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    /// Rebuild the pending block notifications from the current schedule.
    @MainActor
    static func resync(context: ModelContext) {
        let settings = UserSettings.fetchOrCreate(in: context)
        let enabled = settings.blockRemindersEnabled
        let leadMinutes = settings.blockReminderLeadMinutes

        let now = Date()
        guard let horizon = Calendar.current.date(byAdding: .day, value: horizonDays, to: now) else { return }
        let snapshots: [BlockSnapshot] = ((try? context.fetch(FetchDescriptor<ScheduledBlock>())) ?? [])
            .filter { block in
                guard !block.isComplete,
                      block.startTime > now.addingTimeInterval(60),
                      block.startTime < horizon,
                      let task = block.task, !task.isComplete else { return false }
                return true
            }
            .sorted { $0.startTime < $1.startTime }
            .prefix(maxBlocks)
            .compactMap { block in
                guard let task = block.task else { return nil }
                return BlockSnapshot(
                    id: block.id,
                    taskId: task.id,
                    title: task.title,
                    start: block.startTime,
                    minutes: block.durationMinutes,
                    firstStep: task.firstStep
                )
            }

        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { pending in
            let stale = pending.map(\.identifier).filter { $0.hasPrefix(idPrefix) }
            center.removePendingNotificationRequests(withIdentifiers: stale)

            guard enabled else { return }
            center.getNotificationSettings { notifSettings in
                guard notifSettings.authorizationStatus == .authorized else { return }
                for snapshot in snapshots {
                    center.add(request(for: snapshot, leadMinutes: 0))
                    if leadMinutes > 0 {
                        center.add(request(for: snapshot, leadMinutes: leadMinutes))
                    }
                }
            }
        }
    }

    /// Re-ping in 10 minutes without touching the schedule.
    static func snooze(from original: UNNotificationRequest) {
        guard let content = original.content.mutableCopy() as? UNMutableNotificationContent else { return }
        content.body = "Snoozed. Ready for a small start?"
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 10 * 60, repeats: false)
        let request = UNNotificationRequest(
            identifier: "\(idPrefix)snooze-\(UUID().uuidString)",
            content: content,
            trigger: trigger
        )
        UNUserNotificationCenter.current().add(request)
    }

    private static func request(for snapshot: BlockSnapshot, leadMinutes: Int) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = snapshot.title
        let length = snapshot.minutes < 60
            ? "\(snapshot.minutes)m"
            : "\(snapshot.minutes / 60)h\(snapshot.minutes % 60 > 0 ? " \(snapshot.minutes % 60)m" : "")"
        if leadMinutes > 0 {
            content.body = "\(length) block starts in \(leadMinutes) min. Wrap up what you're doing."
        } else if let step = snapshot.firstStep, !step.isEmpty {
            // The captured opening move beats a platitude: name the exact
            // physical action so the block is startable from the banner.
            content.body = "\(length) block starting now. First step: \(step)"
        } else {
            content.body = "\(length) block starting now. One small start counts."
        }
        content.sound = .default
        content.categoryIdentifier = categoryId
        content.userInfo = ["taskId": snapshot.taskId.uuidString]

        let fireDate = snapshot.start.addingTimeInterval(TimeInterval(-leadMinutes * 60))
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: fireDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let suffix = leadMinutes > 0 ? "-lead" : ""
        return UNNotificationRequest(
            identifier: "\(idPrefix)\(snapshot.id.uuidString)\(suffix)",
            content: content,
            trigger: trigger
        )
    }
}

// MARK: - Schedule-change hook

/// Everything that should happen after the plan changes: refresh widgets and
/// rebuild block nudges. `interactive` gates the one-time permission prompt to
/// user-initiated actions so it never appears out of nowhere at launch.
@MainActor
func scheduleDidChange(context: ModelContext, interactive: Bool = true) {
    SharedStore.reloadWidgets()
    if interactive {
        Task { @MainActor in
            _ = await NotificationService.requestAuthorization()
            BlockNotificationService.resync(context: context)
        }
    } else {
        BlockNotificationService.resync(context: context)
    }
}

// MARK: - App delegate (notification actions + foreground banners)

final class LoomAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    /// Set by a notification tap before the SwiftUI tree may exist; consumed
    /// by MainTabView to open the work session.
    static var pendingSessionTaskId: UUID?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        BlockNotificationService.registerCategory()
        return true
    }

    // Show banners even while the app is open.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let content = response.notification.request.content

        if response.actionIdentifier == BlockNotificationService.snoozeActionId {
            BlockNotificationService.snooze(from: response.notification.request)
        } else if content.categoryIdentifier == BlockNotificationService.categoryId,
                  let idString = content.userInfo["taskId"] as? String,
                  let taskId = UUID(uuidString: idString) {
            // Default tap and "Start Session" both open the timer.
            Self.pendingSessionTaskId = taskId
            NotificationCenter.default.post(name: .loomOpenWorkSession, object: nil)
        }
        completionHandler()
    }
}

extension Notification.Name {
    static let loomOpenWorkSession = Notification.Name("loomOpenWorkSession")
}
