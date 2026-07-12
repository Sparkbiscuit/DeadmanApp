import Foundation
import ActivityKit
import SwiftUI

// MARK: - Live Activity attributes (shared with the LoomWidgets extension)

struct WorkSessionAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// The moment the timer started; the system renders the count-up itself.
        var startedAt: Date
    }

    var taskTitle: String
    /// TaskContext.rawValue — kept as a string so the widget target doesn't
    /// need the SwiftData models.
    var contextName: String
    var effortMinutes: Int
    /// End of the scheduled block the session started inside, when there is
    /// one — the Live Activity counts down to it ("held flame" style).
    var blockEndsAt: Date? = nil
    /// When the progress ring reads full: session start plus the scheduled
    /// block's duration (or the remaining budget when the session floats
    /// outside any block). The ring starts empty at `startedAt` and fills as
    /// worked time accumulates — never from an arbitrary mid-point.
    var ringEndsAt: Date? = nil
}

extension WorkSessionAttributes {
    /// Context accent color, resolved without the app's model layer.
    var contextColor: Color {
        switch contextName {
        case "School": return Color(red: 0x5A / 255, green: 0x78 / 255, blue: 0xE0 / 255)
        case "Work": return Color(red: 0xE0 / 255, green: 0xA0 / 255, blue: 0x20 / 255)
        case "Personal": return Color(red: 0x3F / 255, green: 0xA3 / 255, blue: 0x72 / 255)
        default: return Color(red: 0xC1 / 255, green: 0x57 / 255, blue: 0x1F / 255)
        }
    }
}

// MARK: - App-side controller

/// Starts and ends the Lock Screen / Dynamic Island activity that mirrors a
/// running work session. Only the app process may call this — extensions
/// cannot request activities.
@MainActor
enum WorkSessionActivityController {

    static func start(
        taskTitle: String,
        contextName: String,
        effortMinutes: Int,
        startedAt: Date,
        blockEndsAt: Date? = nil,
        ringEndsAt: Date? = nil
    ) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let attributes = WorkSessionAttributes(
            taskTitle: taskTitle,
            contextName: contextName,
            effortMinutes: effortMinutes,
            blockEndsAt: blockEndsAt,
            ringEndsAt: ringEndsAt
        )
        let content = ActivityContent(
            state: WorkSessionAttributes.ContentState(startedAt: startedAt),
            staleDate: nil
        )
        // End-then-request inside one Task so a rapid restart can't leave two
        // activities alive.
        Task {
            for activity in Activity<WorkSessionAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            _ = try? Activity.request(attributes: attributes, content: content)
        }
    }

    static func end() {
        endAll()
    }

    /// Ends every Loom activity — also used at launch to clear leftovers from
    /// a session that died with the app.
    static func endAll() {
        let activities = Activity<WorkSessionAttributes>.activities
        guard !activities.isEmpty else { return }
        Task {
            for activity in activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}
