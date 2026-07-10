import Foundation
import SwiftData

// MARK: - Pace (schedule pressure)

/// How much of the free time left before a task's buffered deadline its
/// remaining effort would consume. The red "Not blocked" state fires when it's
/// already too late; pace is the early warning, days before that.
enum PaceLevel {
    case comfortable   // < 50% of remaining free time needed
    case tightening    // 50–80%
    case critical      // > 80%

    init(pressure: Double) {
        if pressure < 0.5 {
            self = .comfortable
        } else if pressure <= 0.8 {
            self = .tightening
        } else {
            self = .critical
        }
    }
}

/// Per-task pressure, cached so task rows can read it on every render without
/// re-running the free-slot machinery. Recomputed lazily when stale (2 min)
/// and invalidated on every schedule change.
@MainActor
enum PaceCache {

    struct Entry {
        let pressure: Double
        let availableMinutes: Int
        let remainingMinutes: Int

        var level: PaceLevel { PaceLevel(pressure: pressure) }
    }

    private static var entries: [UUID: Entry] = [:]
    private static var computedAt = Date.distantPast
    private static let maxAge: TimeInterval = 120

    static func entry(for taskId: UUID, context: ModelContext) -> Entry? {
        refreshIfStale(context: context)
        return entries[taskId]
    }

    /// The single most-pressured active task, for the one-line summary.
    static func worst(context: ModelContext) -> (taskId: UUID, entry: Entry)? {
        refreshIfStale(context: context)
        return entries.max { $0.value.pressure < $1.value.pressure }
            .map { ($0.key, $0.value) }
    }

    static func invalidate() {
        computedAt = .distantPast
    }

    private static func refreshIfStale(context: ModelContext) {
        let now = Date()
        guard now.timeIntervalSince(computedAt) > maxAge else { return }
        computedAt = now
        entries = [:]

        let tasks = (try? context.fetch(FetchDescriptor<LoomTask>())) ?? []
        let allBlocks = (try? context.fetch(FetchDescriptor<ScheduledBlock>())) ?? []
        let blockedTimes = (try? context.fetch(FetchDescriptor<BlockedTime>())) ?? []
        let busyEvents = (try? context.fetch(FetchDescriptor<BusyEvent>())) ?? []
        let settings = UserSettings.fetchOrCreate(in: context)

        for task in tasks where !task.isComplete && task.deadline > now {
            if let pressure = SchedulerService.pressure(
                for: task,
                allBlocks: allBlocks,
                blockedTimes: blockedTimes,
                busyEvents: busyEvents,
                settings: settings,
                now: now
            ) {
                let windowEnd = task.deadline.addingTimeInterval(
                    -Double(settings.deadlineBufferMinutes) * 60
                )
                let available = SchedulerService.availableMinutes(
                    from: now,
                    to: windowEnd,
                    excludingTaskId: task.id,
                    allBlocks: allBlocks,
                    blockedTimes: blockedTimes,
                    busyEvents: busyEvents,
                    settings: settings
                )
                entries[task.id] = Entry(
                    pressure: pressure,
                    availableMinutes: available,
                    remainingMinutes: task.remainingMinutes
                )
            }
        }
    }
}

// MARK: - Start streak

/// Streaks that count *initiation*, not completion — starting is the actual
/// disorder-level challenge. A couple of free "mend" days per week keep one
/// bad day from torching the whole thread (broken-streak despair is the
/// classic ADHD streak-app failure).
struct StreakCalculator {

    /// Length in days of the current chain of "days with at least one work
    /// session start", walking back from today. Rules:
    /// - Today without a start yet neither counts nor breaks — the day isn't over.
    /// - Up to `weeklyMends` startless days per calendar week are mended: they
    ///   keep the chain alive and count toward its length, but only when they
    ///   actually bridge to an earlier start day — mends that dead-end into a
    ///   break must not inflate the count.
    static func startStreak(
        startDates: [Date],
        now: Date = Date(),
        calendar: Calendar = .current,
        weeklyMends: Int = 2
    ) -> Int {
        let startDays = Set(startDates.map { calendar.startOfDay(for: $0) })
        guard let earliest = startDays.min() else { return 0 }

        var cursor = calendar.startOfDay(for: now)
        if !startDays.contains(cursor) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor) else {
                return 0
            }
            cursor = yesterday
        }

        var streak = 0
        var pendingMends = 0
        var mendsUsedByWeek: [Int: Int] = [:]

        while cursor >= earliest {
            if startDays.contains(cursor) {
                streak += 1 + pendingMends
                pendingMends = 0
            } else {
                let comps = calendar.dateComponents(
                    [.weekOfYear, .yearForWeekOfYear], from: cursor
                )
                let weekKey = (comps.yearForWeekOfYear ?? 0) * 100 + (comps.weekOfYear ?? 0)
                guard mendsUsedByWeek[weekKey, default: 0] < weeklyMends else { break }
                mendsUsedByWeek[weekKey, default: 0] += 1
                pendingMends += 1
            }
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }

        return streak
    }
}
