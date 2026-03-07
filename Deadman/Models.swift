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

enum RecurrenceRule: String, Codable, CaseIterable, Identifiable {
    case none = "None"
    case daily = "Daily"
    case weekdays = "Weekdays"
    case weekly = "Weekly"
    case biweekly = "Biweekly"

    var id: String { rawValue }
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
    var completedAt: Date?
    var selfReportedProgress: Double = 0.0
    var userModified: Bool
    var source: TaskSource
    var canvasAssignmentId: String?

    @Relationship(deleteRule: .cascade, inverse: \ScheduledBlock.task)
    var scheduledBlocks: [ScheduledBlock]

    @Relationship(deleteRule: .cascade, inverse: \WorkSession.task)
    var workSessions: [WorkSession]

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
        self.completedAt = nil
        self.selfReportedProgress = 0.0
        self.userModified = false
        self.source = source
        self.canvasAssignmentId = nil
        self.scheduledBlocks = []
        self.workSessions = []
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

    /// Total actual time spent working (from work sessions), in minutes
    var totalTimeSpentMinutes: Int {
        workSessions.reduce(0) { $0 + $1.durationMinutes }
    }

    /// Whether the user is over their original time budget
    var isOverBudget: Bool {
        totalTimeSpentMinutes > effortMinutes
    }

    /// Ratio of time spent to estimated effort (can exceed 1.0)
    var timeSpentRatio: Double {
        guard effortMinutes > 0 else { return 0 }
        return Double(totalTimeSpentMinutes) / Double(effortMinutes)
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

// MARK: - WorkSession

@Model
final class WorkSession {
    var id: UUID
    var task: DeadmanTask?
    var startedAt: Date
    var endedAt: Date?
    var progressAfter: Double

    init(task: DeadmanTask) {
        self.id = UUID()
        self.task = task
        self.startedAt = Date()
        self.endedAt = nil
        self.progressAfter = 0.0
    }

    var durationMinutes: Int {
        let end = endedAt ?? Date()
        return max(0, Int(end.timeIntervalSince(startedAt) / 60))
    }

    var isActive: Bool {
        endedAt == nil
    }
}

// MARK: - BlockedTime (manual calendar events)

@Model
final class BlockedTime {
    var id: UUID
    var title: String
    var startTime: Date
    var durationMinutes: Int
    var recurrence: RecurrenceRule
    var recurrenceEndDate: Date?
    var appleCalendarEventId: String?

    init(
        title: String,
        startTime: Date,
        durationMinutes: Int,
        recurrence: RecurrenceRule = .none
    ) {
        self.id = UUID()
        self.title = title
        self.startTime = startTime
        self.durationMinutes = durationMinutes
        self.recurrence = recurrence
        self.recurrenceEndDate = nil
        self.appleCalendarEventId = nil
    }

    var endTime: Date {
        startTime.addingTimeInterval(TimeInterval(durationMinutes * 60))
    }

    /// Generate all occurrences of this blocked time within a date range
    func occurrences(from rangeStart: Date, to rangeEnd: Date) -> [(start: Date, end: Date)] {
        let calendar = Calendar.current

        if recurrence == .none {
            // Single event
            if startTime < rangeEnd && endTime > rangeStart {
                return [(startTime, endTime)]
            }
            return []
        }

        var results: [(start: Date, end: Date)] = []
        let effectiveEnd = recurrenceEndDate.map { min($0, rangeEnd) } ?? rangeEnd
        var current = startTime

        while current < effectiveEnd {
            let occEnd = current.addingTimeInterval(TimeInterval(durationMinutes * 60))
            if current < rangeEnd && occEnd > rangeStart {
                results.append((current, occEnd))
            }

            switch recurrence {
            case .none:
                return results
            case .daily:
                current = calendar.date(byAdding: .day, value: 1, to: current)!
            case .weekdays:
                repeat {
                    current = calendar.date(byAdding: .day, value: 1, to: current)!
                } while calendar.isDateInWeekend(current)
            case .weekly:
                current = calendar.date(byAdding: .weekOfYear, value: 1, to: current)!
            case .biweekly:
                current = calendar.date(byAdding: .weekOfYear, value: 2, to: current)!
            }
        }

        return results
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
    var importAppleCalendar: Bool = false

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
        self.importAppleCalendar = false
    }

    var wakeTime: DateComponents {
        DateComponents(hour: wakeHour, minute: wakeMinute)
    }

    var sleepTime: DateComponents {
        DateComponents(hour: sleepHour, minute: sleepMinute)
    }
}
