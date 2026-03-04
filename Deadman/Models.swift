import Foundation
import SwiftData

// MARK: - Enums

enum TaskContext: String, Codable, CaseIterable, Identifiable {
    case school = "School"
    case work = "Work"
    case personal = "Personal"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .school: return "book.fill"
        case .work: return "briefcase.fill"
        case .personal: return "person.fill"
        }
    }
}

enum TaskSource: String, Codable {
    case manual
    case canvas
    case bulkEntry
}

// MARK: - Task

@Model
final class DeadmanTask {
    var id: UUID
    var title: String
    var context: TaskContext
    var deadline: Date
    var effortMinutes: Int
    var isComplete: Bool
    var userModified: Bool
    var source: TaskSource
    var canvasAssignmentId: String?

    @Relationship(deleteRule: .cascade, inverse: \ScheduledBlock.task)
    var scheduledBlocks: [ScheduledBlock]

    init(
        title: String,
        context: TaskContext,
        deadline: Date,
        effortMinutes: Int,
        source: TaskSource = .manual
    ) {
        self.id = UUID()
        self.title = title
        self.context = context
        self.deadline = deadline
        self.effortMinutes = effortMinutes
        self.isComplete = false
        self.userModified = false
        self.source = source
        self.canvasAssignmentId = nil
        self.scheduledBlocks = []
    }

    var completedMinutes: Int {
        scheduledBlocks
            .filter { $0.isComplete }
            .reduce(0) { $0 + $1.durationMinutes }
    }

    var remainingMinutes: Int {
        max(0, effortMinutes - completedMinutes)
    }

    var nextBlock: ScheduledBlock? {
        scheduledBlocks
            .filter { !$0.isComplete }
            .sorted { $0.startTime < $1.startTime }
            .first
    }

    var isFullyScheduled: Bool {
        let scheduledTotal = scheduledBlocks
            .filter { !$0.isComplete }
            .reduce(0) { $0 + $1.durationMinutes }
        return scheduledTotal >= remainingMinutes
    }
}

// MARK: - ScheduledBlock

@Model
final class ScheduledBlock {
    var id: UUID
    var task: DeadmanTask?
    var startTime: Date
    var durationMinutes: Int
    var isComplete: Bool
    var isLocked: Bool
    var appleCalendarEventId: String?

    init(
        task: DeadmanTask,
        startTime: Date,
        durationMinutes: Int
    ) {
        self.id = UUID()
        self.task = task
        self.startTime = startTime
        self.durationMinutes = durationMinutes
        self.isComplete = false
        self.isLocked = false
        self.appleCalendarEventId = nil
    }

    var endTime: Date {
        startTime.addingTimeInterval(TimeInterval(durationMinutes * 60))
    }
}

// MARK: - UserSettings

@Model
final class UserSettings {
    var id: UUID
    var wakeHour: Int
    var wakeMinute: Int
    var sleepHour: Int
    var sleepMinute: Int
    var minBlockMinutes: Int
    var maxBlockMinutes: Int
    var deadlineBufferMinutes: Int
    var canvasBaseURL: String?
    var exportToAppleCalendar: Bool

    init() {
        self.id = UUID()
        self.wakeHour = 8
        self.wakeMinute = 0
        self.sleepHour = 23
        self.sleepMinute = 0
        self.minBlockMinutes = 30
        self.maxBlockMinutes = 90
        self.deadlineBufferMinutes = 120
        self.canvasBaseURL = nil
        self.exportToAppleCalendar = false
    }

    var wakeTime: DateComponents {
        DateComponents(hour: wakeHour, minute: wakeMinute)
    }

    var sleepTime: DateComponents {
        DateComponents(hour: sleepHour, minute: sleepMinute)
    }
}
