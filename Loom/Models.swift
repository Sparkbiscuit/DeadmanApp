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
    case bulkEntry
}

// MARK: - Task

@Model
final class LoomTask {
    var id: UUID
    var title: String
    var context: TaskContext
    var deadline: Date
    var effortMinutes: Int
    var isComplete: Bool
    var userModified: Bool
    var source: TaskSource
    /// Self-reported completion (0–100) from work sessions; combined with
    /// block-based progress, whichever is further along.
    var manualProgressPercent: Int = 0
    /// The tiny concrete opening move ("open the doc, paste the data table").
    /// "Write lab report" is un-startable; the first physical action isn't.
    /// Cleared automatically after the first work session — its job is done.
    var firstStep: String? = nil

    @Relationship(deleteRule: .cascade, inverse: \ScheduledBlock.task)
    var scheduledBlocks: [ScheduledBlock]

    @Relationship(deleteRule: .cascade, inverse: \WorkSession.task)
    var workSessions: [WorkSession] = []

    init(
        title: String,
        context: TaskContext,
        deadline: Date,
        effortMinutes: Int,
        source: TaskSource = .manual,
        firstStep: String? = nil
    ) {
        self.id = UUID()
        self.title = title
        self.context = context
        self.deadline = deadline
        self.effortMinutes = effortMinutes
        self.isComplete = false
        self.userModified = false
        self.source = source
        self.manualProgressPercent = 0
        self.firstStep = firstStep
        self.scheduledBlocks = []
        self.workSessions = []
    }

    /// Minutes of blocks the user checked off. Checking a block means "I worked
    /// this time" — it feeds time-spent, never task progress. Productivity varies;
    /// progress is only what the user self-reports.
    var workedBlockMinutes: Int {
        scheduledBlocks
            .filter { $0.isComplete }
            .reduce(0) { $0 + $1.durationMinutes }
    }

    /// Actual minutes worked: timed sessions plus checked-off blocks.
    var timeSpentMinutes: Int {
        workSessions.reduce(0) { $0 + ($1.durationSeconds + 30) / 60 } + workedBlockMinutes
    }

    var isOverBudget: Bool {
        timeSpentMinutes > effortMinutes
    }

    /// Effort considered done — self-reported progress only.
    var effectiveCompletedMinutes: Int {
        effortMinutes * min(100, max(0, manualProgressPercent)) / 100
    }

    /// 0.0–1.0 for progress bars.
    var progressFraction: Double {
        guard effortMinutes > 0 else { return 0 }
        return min(1.0, Double(effectiveCompletedMinutes) / Double(effortMinutes))
    }

    var progressPercent: Int {
        Int((progressFraction * 100).rounded())
    }

    var remainingMinutes: Int {
        max(0, effortMinutes - effectiveCompletedMinutes)
    }

    var nextBlock: ScheduledBlock? {
        scheduledBlocks
            .filter { !$0.isComplete && $0.endTime > Date() }
            .sorted { $0.startTime < $1.startTime }
            .first
    }

    /// Minutes of not-yet-completed work that still have a future block reserved.
    var futureScheduledMinutes: Int {
        let now = Date()
        return scheduledBlocks
            .filter { !$0.isComplete && $0.endTime > now }
            .reduce(0) { $0 + $1.durationMinutes }
    }

    var isFullyScheduled: Bool {
        futureScheduledMinutes >= remainingMinutes
    }
}

// MARK: - ScheduledBlock

@Model
final class ScheduledBlock {
    var id: UUID
    var task: LoomTask?
    var startTime: Date
    var durationMinutes: Int
    var isComplete: Bool
    var isLocked: Bool
    var appleCalendarEventId: String?

    init(
        task: LoomTask,
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
    var task: LoomTask?
    var startedAt: Date
    var durationSeconds: Int

    init(task: LoomTask, startedAt: Date, durationSeconds: Int) {
        self.id = UUID()
        self.task = task
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
    }
}

// MARK: - BlockedTime

/// A recurring window (class, standup, commute…) the scheduler must not book over.
@Model
final class BlockedTime {
    var id: UUID
    var label: String
    /// Calendar weekdays this repeats on (1 = Sunday … 7 = Saturday).
    var weekdays: [Int]
    var startHour: Int
    var startMinute: Int
    var durationMinutes: Int

    init(
        label: String,
        weekdays: [Int],
        startHour: Int,
        startMinute: Int,
        durationMinutes: Int
    ) {
        self.id = UUID()
        self.label = label
        self.weekdays = weekdays
        self.startHour = startHour
        self.startMinute = startMinute
        self.durationMinutes = durationMinutes
    }

    /// Human label for the repeat pattern ("Daily", "Weekdays", "Mon, Wed"…).
    var repeatLabel: String {
        let set = Set(weekdays)
        if set == Set(1...7) { return "Daily" }
        if set == Set(2...6) { return "Weekdays" }
        if set == Set([1, 7]) { return "Weekends" }
        let symbols = Calendar.current.shortWeekdaySymbols
        return weekdays.sorted()
            .compactMap { $0 >= 1 && $0 <= 7 ? symbols[$0 - 1] : nil }
            .joined(separator: ", ")
    }

    /// Concrete occurrences of this window between two dates.
    func occurrences(from: Date, to: Date, calendar: Calendar = .current) -> [DateInterval] {
        guard durationMinutes > 0, !weekdays.isEmpty else { return [] }
        var result: [DateInterval] = []
        var day = calendar.startOfDay(for: from)
        let lastDay = calendar.startOfDay(for: to)
        while day <= lastDay {
            if weekdays.contains(calendar.component(.weekday, from: day)),
               let start = calendar.date(bySettingHour: startHour, minute: startMinute, second: 0, of: day) {
                let end = start.addingTimeInterval(TimeInterval(durationMinutes * 60))
                if end > from && start < to {
                    result.append(DateInterval(start: start, end: end))
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return result
    }
}

// MARK: - Reminder

/// A one-off, point-in-time reminder with a local notification. Deliberately
/// not a task: no effort, no blocks, no scheduling; just a nudge at a time.
@Model
final class Reminder {
    var id: UUID
    var title: String
    var dueDate: Date
    var isComplete: Bool
    /// Identifier of the pending local notification, for cancellation.
    var notificationId: String

    init(title: String, dueDate: Date) {
        self.id = UUID()
        self.title = title
        self.dueDate = dueDate
        self.isComplete = false
        self.notificationId = UUID().uuidString
    }
}

// MARK: - BusyEvent

enum BusySource: String, Codable {
    case appleCalendar
    case googleCalendar
}

/// A concrete busy window imported from an external calendar. Occupies
/// scheduler slots and shows on the schedule, but is deliberately not a task —
/// it never appears in the task list and carries no effort or progress.
@Model
final class BusyEvent {
    var id: UUID
    var source: BusySource
    /// The external event identifier — re-imports upsert on this, never duplicate.
    var sourceId: String
    var title: String
    var startTime: Date
    var endTime: Date
    var calendarName: String?

    init(
        source: BusySource,
        sourceId: String,
        title: String,
        startTime: Date,
        endTime: Date,
        calendarName: String? = nil
    ) {
        self.id = UUID()
        self.source = source
        self.sourceId = sourceId
        self.title = title
        self.startTime = startTime
        self.endTime = endTime
        self.calendarName = calendarName
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
    /// Breathing room before the first block of newly scheduled work — nothing
    /// gets booked to start "right now" unless the user explicitly asks.
    var startBufferMinutes: Int = 15
    /// Max minutes of task blocks the scheduler may place on a single day. 0 = no limit.
    var dailyFocusMinutes: Int = 0
    var exportToAppleCalendar: Bool
    /// One-way import: Apple Calendar events become BusyEvents the scheduler avoids.
    var importFromAppleCalendar: Bool = false
    /// Calendars the user opted out of importing (EKCalendar identifiers).
    var excludedCalendarIds: [String] = []
    var loomCalendarIdentifier: String?
    var hasCompletedOnboarding: Bool = false
    /// Nudge when a scheduled block begins (the anti-time-blindness alarm).
    var blockRemindersEnabled: Bool = true
    /// Extra heads-up this many minutes before a block starts. 0 = off.
    var blockReminderLeadMinutes: Int = 0

    init() {
        self.id = UUID()
        self.wakeHour = 8
        self.wakeMinute = 0
        self.sleepHour = 23
        self.sleepMinute = 0
        self.minBlockMinutes = 30
        self.maxBlockMinutes = 90
        self.deadlineBufferMinutes = 120
        self.startBufferMinutes = 15
        self.dailyFocusMinutes = 0
        self.exportToAppleCalendar = false
        self.importFromAppleCalendar = false
        self.excludedCalendarIds = []
        self.loomCalendarIdentifier = nil
        self.hasCompletedOnboarding = false
        self.blockRemindersEnabled = true
        self.blockReminderLeadMinutes = 0
    }

    var wakeTime: DateComponents {
        DateComponents(hour: wakeHour, minute: wakeMinute)
    }

    var sleepTime: DateComponents {
        DateComponents(hour: sleepHour, minute: sleepMinute)
    }

    /// The single settings row, created on first use. Always fetch through here
    /// so the app can't end up with competing duplicates.
    static func fetchOrCreate(in context: ModelContext) -> UserSettings {
        let descriptor = FetchDescriptor<UserSettings>()
        if let existing = (try? context.fetch(descriptor))?.first {
            return existing
        }
        let fresh = UserSettings()
        context.insert(fresh)
        return fresh
    }
}
