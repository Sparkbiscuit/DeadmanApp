import Foundation
import SwiftData
import WidgetKit

/// The SwiftData store lives in the App Group container so the widget
/// extension can read the schedule. Both targets build their containers
/// through here.
enum SharedStore {

    static let appGroupId = "group.com.christoforakis.Loom"

    static let schema = Schema([
        LoomTask.self,
        ScheduledBlock.self,
        WorkSession.self,
        BlockedTime.self,
        BusyEvent.self,
        Reminder.self,
        UserSettings.self
    ])

    static var storeURL: URL {
        if let base = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupId
        ) {
            return base.appendingPathComponent("Loom.store")
        }
        // No group entitlement (previews, misconfigured signing): stay local
        // rather than crash.
        return URL.applicationSupportDirectory.appendingPathComponent("Loom.store")
    }

    static func makeContainer() throws -> ModelContainer {
        migrateLegacyStoreIfNeeded()
        let configuration = ModelConfiguration(url: storeURL)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    /// Pre-1.2 builds kept the store at SwiftData's default location inside
    /// the app sandbox. Copy it into the group container once, so updating
    /// doesn't lose data. (Runs as a no-op inside the widget, whose sandbox
    /// never had a legacy store.)
    static func migrateLegacyStoreIfNeeded() {
        let fileManager = FileManager.default
        let destination = storeURL
        guard !fileManager.fileExists(atPath: destination.path) else { return }

        let legacyBase = URL.applicationSupportDirectory.appendingPathComponent("default.store")
        guard fileManager.fileExists(atPath: legacyBase.path) else { return }

        try? fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // SQLite sidecars must travel with the main file.
        for suffix in ["", "-shm", "-wal"] {
            let from = URL(fileURLWithPath: legacyBase.path + suffix)
            let to = URL(fileURLWithPath: destination.path + suffix)
            if fileManager.fileExists(atPath: from.path) {
                try? fileManager.copyItem(at: from, to: to)
            }
        }
    }

    /// Nudge home/lock screen widgets after anything that changes the schedule.
    static func reloadWidgets() {
        WidgetCenter.shared.reloadAllTimelines()
    }
}
