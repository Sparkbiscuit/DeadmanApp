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

// StreakCalculator lives in Models.swift so the widget target (which doesn't
// compile this file) can show the streak too.
