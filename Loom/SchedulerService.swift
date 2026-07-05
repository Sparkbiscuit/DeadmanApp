import Foundation
import SwiftData

// MARK: - Scheduling Result

enum ScheduleResult {
    case success(blocks: [ScheduledBlock])
    case partialFit(scheduled: [ScheduledBlock], unscheduledMinutes: Int)
    case noSlots
}

/// Outcome of a catch-up pass over missed blocks.
struct CatchUpSummary: Equatable {
    /// Tasks whose missed work was fed back through the scheduler.
    var replannedTasks = 0
    /// Of those, tasks whose remaining effort could not fully fit before the
    /// deadline — surfaced to the user instead of leaving dangling blocks.
    var unschedulableTasks = 0
}

// MARK: - Scheduler Service

struct SchedulerService {

    // MARK: - Public API

    /// Schedule a task by finding free slots between now and its deadline.
    /// Returns the result indicating full success, partial fit, or no slots.
    /// The returned blocks are NOT inserted into any context — callers commit them.
    static func schedule(
        task: LoomTask,
        allBlocks: [ScheduledBlock],
        blockedTimes: [BlockedTime] = [],
        busyEvents: [BusyEvent] = [],
        settings: UserSettings,
        from startDate: Date = Date(),
        allowOvernight: Bool = false
    ) -> ScheduleResult {
        let remaining = task.remainingMinutes
        guard remaining > 0 else { return .success(blocks: []) }

        let bufferSeconds = TimeInterval(settings.deadlineBufferMinutes * 60)
        let windowEnd = task.deadline.addingTimeInterval(-bufferSeconds)

        // Blocks start on tidy 5-minute boundaries, never at "9:47:33".
        let startDate = roundUpToFiveMinutes(startDate)

        guard startDate < windowEnd else { return .noSlots }

        // Gather existing occupied intervals (exclude completed blocks)
        var occupied = allBlocks
            .filter { !$0.isComplete }
            .map { Interval(start: $0.startTime, end: $0.endTime) }

        // Recurring blocked times are occupied too
        for blocked in blockedTimes {
            occupied.append(contentsOf: blocked
                .occurrences(from: startDate, to: windowEnd)
                .map { Interval(start: $0.start, end: $0.end) })
        }

        // …as are imported calendar events
        for event in busyEvents where event.endTime > startDate && event.startTime < windowEnd {
            occupied.append(Interval(start: event.startTime, end: event.endTime))
        }
        occupied.sort { $0.start < $1.start }

        // Find free slots
        let freeSlots = findFreeSlots(
            from: startDate,
            to: windowEnd,
            occupied: occupied,
            settings: settings,
            allowOvernight: allowOvernight
        )

        // Daily focus cap: minutes already booked per day count against the limit,
        // and no single chunk may exceed the cap or it could never be placed.
        let calendar = Calendar.current
        let focusCap = settings.dailyFocusMinutes
        let effectiveMax = focusCap > 0
            ? min(settings.maxBlockMinutes, focusCap)
            : settings.maxBlockMinutes

        // Split remaining effort into chunks
        let chunks = splitEffort(
            minutes: remaining,
            minBlock: min(settings.minBlockMinutes, effectiveMax),
            maxBlock: effectiveMax
        )

        var minutesPerDay: [Date: Int] = [:]
        if focusCap > 0 {
            for block in allBlocks where !block.isComplete {
                let day = calendar.startOfDay(for: block.startTime)
                minutesPerDay[day, default: 0] += block.durationMinutes
            }
        }

        // Assign chunks to earliest available slots
        var newBlocks: [ScheduledBlock] = []
        var slotIndex = 0
        var slotOffset: TimeInterval = 0

        for chunk in chunks {
            var placed = false
            while slotIndex < freeSlots.count {
                let slot = freeSlots[slotIndex]
                let slotStart = slot.start.addingTimeInterval(slotOffset)
                let available = slot.end.timeIntervalSince(slotStart) / 60.0
                let day = calendar.startOfDay(for: slotStart)
                let overFocusCap = focusCap > 0
                    && minutesPerDay[day, default: 0] + chunk > focusCap

                if available >= Double(chunk) && !overFocusCap {
                    let block = ScheduledBlock(
                        task: task,
                        startTime: slotStart,
                        durationMinutes: chunk
                    )
                    newBlocks.append(block)
                    minutesPerDay[day, default: 0] += chunk
                    slotOffset += TimeInterval(chunk * 60)
                    placed = true
                    break
                } else {
                    slotIndex += 1
                    slotOffset = 0
                }
            }
            if !placed { break }
        }

        let scheduledMinutes = newBlocks.reduce(0) { $0 + $1.durationMinutes }

        if scheduledMinutes == 0 {
            return .noSlots
        } else if scheduledMinutes < remaining {
            return .partialFit(
                scheduled: newBlocks,
                unscheduledMinutes: remaining - scheduledMinutes
            )
        } else {
            return .success(blocks: newBlocks)
        }
    }

    /// Reschedule remaining effort for a task — the single invalidation path,
    /// used for manual reschedules, blocked-time/busy-event conflicts, and
    /// missed-block catch-up alike. Removes the task's unlocked, incomplete
    /// blocks and inserts the replacements.
    @discardableResult
    static func reschedule(
        task: LoomTask,
        allBlocks: [ScheduledBlock],
        blockedTimes: [BlockedTime] = [],
        busyEvents: [BusyEvent] = [],
        settings: UserSettings,
        from startDate: Date? = nil,
        context: ModelContext
    ) -> ScheduleResult {
        // Remove unlocked, incomplete blocks for this task
        let blocksToRemove = task.scheduledBlocks.filter { !$0.isLocked && !$0.isComplete }
        let removedIds = Set(blocksToRemove.map(\.id))
        for block in blocksToRemove {
            context.delete(block)
        }

        // Get all blocks except the ones we just removed
        let remainingBlocks = allBlocks.filter { !removedIds.contains($0.id) }

        let result = schedule(
            task: task,
            allBlocks: remainingBlocks,
            blockedTimes: blockedTimes,
            busyEvents: busyEvents,
            settings: settings,
            from: startDate
                ?? Date().addingTimeInterval(TimeInterval(settings.startBufferMinutes * 60))
        )
        insert(result: result, into: context)
        return result
    }

    /// Commit a schedule result's blocks to the store.
    static func insert(result: ScheduleResult, into context: ModelContext) {
        switch result {
        case .success(let blocks), .partialFit(let blocks, _):
            for block in blocks { context.insert(block) }
        case .noSlots:
            break
        }
    }

    /// Catch-up pass: a block whose window passed unfinished means the plan is
    /// stale, so the task's remaining effort goes back through `reschedule` —
    /// the same path a task edit uses — rather than sitting in limbo. Run on
    /// launch / return to foreground.
    @discardableResult
    static func catchUpMissedBlocks(
        tasks: [LoomTask],
        allBlocks: [ScheduledBlock],
        blockedTimes: [BlockedTime],
        busyEvents: [BusyEvent] = [],
        settings: UserSettings,
        now: Date = Date(),
        context: ModelContext
    ) -> CatchUpSummary {
        var summary = CatchUpSummary()
        var currentBlocks = allBlocks
        let replanStart = now.addingTimeInterval(TimeInterval(settings.startBufferMinutes * 60))

        for task in tasks where !task.isComplete && task.deadline > now {
            let missed = task.scheduledBlocks.contains {
                !$0.isComplete && !$0.isLocked && $0.endTime <= now
            }
            guard missed else { continue }

            // reschedule wipes ALL of the task's unlocked incomplete blocks
            // (missed and future) and replans exactly the remaining effort, so
            // the task never ends up double-booked.
            let removedIds = Set(
                task.scheduledBlocks
                    .filter { !$0.isComplete && !$0.isLocked }
                    .map(\.id)
            )
            let result = reschedule(
                task: task,
                allBlocks: currentBlocks,
                blockedTimes: blockedTimes,
                busyEvents: busyEvents,
                settings: settings,
                from: replanStart,
                context: context
            )
            currentBlocks.removeAll { removedIds.contains($0.id) }

            summary.replannedTasks += 1
            switch result {
            case .success(let blocks):
                currentBlocks.append(contentsOf: blocks)
            case .partialFit(let blocks, _):
                currentBlocks.append(contentsOf: blocks)
                summary.unschedulableTasks += 1
            case .noSlots:
                summary.unschedulableTasks += 1
            }
        }
        return summary
    }

    /// Replan tasks whose upcoming blocks collide with a blocked time or an
    /// imported calendar event — run after either changes, so existing
    /// schedules move out of the way. Returns the number of tasks replanned.
    @discardableResult
    static func replanConflicts(
        tasks: [LoomTask],
        allBlocks: [ScheduledBlock],
        blockedTimes: [BlockedTime],
        busyEvents: [BusyEvent] = [],
        settings: UserSettings,
        now: Date = Date(),
        context: ModelContext
    ) -> Int {
        guard !blockedTimes.isEmpty || !busyEvents.isEmpty else { return 0 }

        var replanned = 0
        var currentBlocks = allBlocks

        for task in tasks where !task.isComplete && task.deadline > now {
            let upcoming = task.scheduledBlocks.filter {
                !$0.isComplete && !$0.isLocked && $0.endTime > now
            }
            guard !upcoming.isEmpty else { continue }

            let conflicted = upcoming.contains { block in
                let hitsBlockedTime = blockedTimes.contains { blocked in
                    // occurrences(from:to:) already returns only overlapping windows
                    !blocked.occurrences(from: block.startTime, to: block.endTime).isEmpty
                }
                let hitsBusyEvent = busyEvents.contains {
                    $0.startTime < block.endTime && $0.endTime > block.startTime
                }
                return hitsBlockedTime || hitsBusyEvent
            }
            guard conflicted else { continue }

            let removedIds = Set(upcoming.map(\.id))
            let result = reschedule(
                task: task,
                allBlocks: currentBlocks,
                blockedTimes: blockedTimes,
                busyEvents: busyEvents,
                settings: settings,
                context: context
            )
            currentBlocks.removeAll { removedIds.contains($0.id) }
            switch result {
            case .success(let blocks), .partialFit(let blocks, _):
                currentBlocks.append(contentsOf: blocks)
            case .noSlots:
                break
            }
            replanned += 1
        }
        return replanned
    }

    /// Round a date up to the next 5-minute boundary.
    static func roundUpToFiveMinutes(_ date: Date) -> Date {
        let interval: TimeInterval = 5 * 60
        let rounded = (date.timeIntervalSinceReferenceDate / interval).rounded(.up) * interval
        return Date(timeIntervalSinceReferenceDate: rounded)
    }

    // MARK: - Internals

    private struct Interval {
        let start: Date
        let end: Date

        var durationMinutes: Double {
            end.timeIntervalSince(start) / 60.0
        }
    }

    /// Find free time slots between `from` and `to`, respecting wake/sleep and occupied intervals.
    private static func findFreeSlots(
        from: Date,
        to: Date,
        occupied: [Interval],
        settings: UserSettings,
        allowOvernight: Bool
    ) -> [Interval] {
        let calendar = Calendar.current
        var slots: [Interval] = []

        // Generate day-by-day awake windows
        var currentDay = calendar.startOfDay(for: from)
        let lastDay = calendar.startOfDay(for: to)

        while currentDay <= lastDay {
            guard let wakeStart = calendar.date(
                bySettingHour: settings.wakeHour,
                minute: settings.wakeMinute,
                second: 0,
                of: currentDay
            ), var sleepEnd = calendar.date(
                bySettingHour: settings.sleepHour,
                minute: settings.sleepMinute,
                second: 0,
                of: currentDay
            ), let nextDay = calendar.date(byAdding: .day, value: 1, to: currentDay) else {
                break
            }

            // A sleep time at or before wake time means "past midnight"
            // (e.g. wake 8:00, sleep 0:30) — the window runs into the next day.
            if sleepEnd <= wakeStart {
                sleepEnd = calendar.date(byAdding: .day, value: 1, to: sleepEnd) ?? sleepEnd
            }

            if allowOvernight {
                let dayStart = max(currentDay, from)
                let dayEnd = min(nextDay, to)
                if dayStart < dayEnd {
                    slots.append(Interval(start: dayStart, end: dayEnd))
                }
            } else {
                let windowStart = max(wakeStart, from)
                let windowEnd = min(sleepEnd, to)
                if windowStart < windowEnd {
                    slots.append(Interval(start: windowStart, end: windowEnd))
                }
            }

            currentDay = nextDay
        }

        // Subtract occupied intervals from free slots
        var freeSlots: [Interval] = []
        for slot in slots {
            var remaining = [slot]
            for occ in occupied {
                var newRemaining: [Interval] = []
                for r in remaining {
                    // No overlap
                    if occ.end <= r.start || occ.start >= r.end {
                        newRemaining.append(r)
                    } else {
                        // Before occupied
                        if occ.start > r.start {
                            newRemaining.append(Interval(start: r.start, end: occ.start))
                        }
                        // After occupied
                        if occ.end < r.end {
                            newRemaining.append(Interval(start: occ.end, end: r.end))
                        }
                    }
                }
                remaining = newRemaining
            }
            freeSlots.append(contentsOf: remaining)
        }

        // Filter out slots too small for minimum block
        return freeSlots.filter { $0.durationMinutes >= Double(settings.minBlockMinutes) }
    }

    /// Split total effort into chunks respecting min/max block sizes.
    /// Rebalances the tail so no chunk lands below the minimum when avoidable
    /// (e.g. 100m with 30–90 becomes [70, 30], not [90, 10]).
    static func splitEffort(minutes: Int, minBlock: Int, maxBlock: Int) -> [Int] {
        guard minutes > 0 else { return [] }
        guard minutes > maxBlock else { return [minutes] }

        var chunks: [Int] = []
        var remaining = minutes

        while remaining > 0 {
            if remaining <= maxBlock {
                chunks.append(remaining)
                remaining = 0
            } else if remaining - maxBlock < minBlock {
                // A full max chunk would strand a sub-minimum tail; split evenly.
                let first = remaining - minBlock
                chunks.append(min(first, maxBlock))
                remaining -= min(first, maxBlock)
            } else {
                chunks.append(maxBlock)
                remaining -= maxBlock
            }
        }

        return chunks
    }
}
