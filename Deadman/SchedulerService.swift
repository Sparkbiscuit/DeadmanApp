import Foundation
import SwiftData

// MARK: - Scheduling Result

enum ScheduleResult {
    case success(blocks: [ScheduledBlock])
    case partialFit(scheduled: [ScheduledBlock], unscheduledMinutes: Int)
    case noSlots
}

// MARK: - Scheduler Service

struct SchedulerService {

    // MARK: - Public API

    /// Schedule a task by finding free slots between now and its deadline.
    /// Returns the result indicating full success, partial fit, or no slots.
    static func schedule(
        task: DeadmanTask,
        allBlocks: [ScheduledBlock],
        settings: UserSettings,
        from startDate: Date = Date(),
        allowOvernight: Bool = false
    ) -> ScheduleResult {
        let remaining = task.remainingMinutes
        guard remaining > 0 else { return .success(blocks: []) }

        let bufferSeconds = TimeInterval(settings.deadlineBufferMinutes * 60)
        let windowEnd = task.deadline.addingTimeInterval(-bufferSeconds)

        guard startDate < windowEnd else { return .noSlots }

        // Gather existing occupied intervals (exclude completed blocks)
        let occupied = allBlocks
            .filter { !$0.isComplete }
            .map { Interval(start: $0.startTime, end: $0.endTime) }
            .sorted { $0.start < $1.start }

        // Find free slots
        let freeSlots = findFreeSlots(
            from: startDate,
            to: windowEnd,
            occupied: occupied,
            settings: settings,
            allowOvernight: allowOvernight
        )

        // Split remaining effort into chunks
        let chunks = splitEffort(
            minutes: remaining,
            minBlock: settings.minBlockMinutes,
            maxBlock: settings.maxBlockMinutes
        )

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

                if available >= Double(chunk) {
                    let block = ScheduledBlock(
                        task: task,
                        startTime: slotStart,
                        durationMinutes: chunk
                    )
                    newBlocks.append(block)
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

    /// Reschedule remaining effort for a task from the current time.
    static func reschedule(
        task: DeadmanTask,
        allBlocks: [ScheduledBlock],
        settings: UserSettings,
        context: ModelContext
    ) -> ScheduleResult {
        // Remove unlocked, incomplete blocks for this task
        let blocksToRemove = task.scheduledBlocks.filter { !$0.isLocked && !$0.isComplete }
        for block in blocksToRemove {
            context.delete(block)
        }

        // Get all blocks except the ones we just removed
        let remainingBlocks = allBlocks.filter { block in
            !blocksToRemove.contains { $0.id == block.id }
        }

        return schedule(task: task, allBlocks: remainingBlocks, settings: settings)
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
            let wakeStart = calendar.date(
                bySettingHour: settings.wakeHour,
                minute: settings.wakeMinute,
                second: 0,
                of: currentDay
            )!
            let sleepEnd = calendar.date(
                bySettingHour: settings.sleepHour,
                minute: settings.sleepMinute,
                second: 0,
                of: currentDay
            )!

            if allowOvernight {
                // Use full day
                let dayStart = max(currentDay, from)
                let dayEnd = min(calendar.date(byAdding: .day, value: 1, to: currentDay)!, to)
                if dayStart < dayEnd {
                    slots.append(Interval(start: dayStart, end: dayEnd))
                }
            } else {
                // Respect wake/sleep window
                let windowStart = max(wakeStart, from)
                let windowEnd = min(sleepEnd, to)
                if windowStart < windowEnd {
                    slots.append(Interval(start: windowStart, end: windowEnd))
                }
            }

            currentDay = calendar.date(byAdding: .day, value: 1, to: currentDay)!
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
    private static func splitEffort(minutes: Int, minBlock: Int, maxBlock: Int) -> [Int] {
        guard minutes > 0 else { return [] }

        var chunks: [Int] = []
        var remaining = minutes

        while remaining > 0 {
            if remaining <= maxBlock {
                // Last chunk: use it all if >= minBlock, otherwise use minBlock
                chunks.append(remaining >= minBlock ? remaining : min(minBlock, remaining))
                remaining = 0
            } else {
                chunks.append(maxBlock)
                remaining -= maxBlock
            }
        }

        return chunks
    }
}
