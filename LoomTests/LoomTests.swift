import XCTest
import SwiftData
@testable import Loom

final class LoomTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private let calendar = Calendar.current

    override func setUpWithError() throws {
        let schema = Schema([
            LoomTask.self, ScheduledBlock.self, WorkSession.self,
            BlockedTime.self, BusyEvent.self, Reminder.self, UserSettings.self
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [config])
        context = ModelContext(container)
    }

    override func tearDownWithError() throws {
        container = nil
        context = nil
    }

    // MARK: - Helpers

    /// 9:00 AM tomorrow — a deterministic "now" safely inside the wake window.
    private var anchor: Date {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))!
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)!
    }

    private func makeSettings() -> UserSettings {
        let settings = UserSettings()
        context.insert(settings)
        return settings
    }

    private func makeTask(effort: Int, deadlineHoursFromAnchor: Double) -> LoomTask {
        let task = LoomTask(
            title: "Test task",
            context: .school,
            deadline: anchor.addingTimeInterval(deadlineHoursFromAnchor * 3600),
            effortMinutes: effort
        )
        context.insert(task)
        return task
    }

    private func scheduledBlocks(from result: ScheduleResult) -> [ScheduledBlock] {
        switch result {
        case .success(let blocks): return blocks
        case .partialFit(let blocks, _): return blocks
        case .noSlots: return []
        }
    }

    // MARK: - splitEffort

    func testSplitEffortRespectsBounds() {
        let cases: [(total: Int, minBlock: Int, maxBlock: Int)] = [
            (60, 30, 90), (200, 30, 90), (100, 30, 90), (95, 30, 90),
            (720, 15, 180), (45, 45, 60), (300, 30, 90)
        ]
        for c in cases {
            let chunks = SchedulerService.splitEffort(
                minutes: c.total, minBlock: c.minBlock, maxBlock: c.maxBlock
            )
            XCTAssertEqual(chunks.reduce(0, +), c.total, "chunks must sum to total for \(c)")
            for chunk in chunks {
                XCTAssertLessThanOrEqual(chunk, c.maxBlock, "chunk over max for \(c)")
                XCTAssertGreaterThanOrEqual(chunk, c.minBlock, "chunk under min for \(c)")
            }
        }
    }

    func testSplitEffortAvoidsSubMinimumTail() {
        // 100m with 30–90 must not produce [90, 10].
        let chunks = SchedulerService.splitEffort(minutes: 100, minBlock: 30, maxBlock: 90)
        XCTAssertEqual(chunks.reduce(0, +), 100)
        XCTAssertTrue(chunks.allSatisfy { $0 >= 30 }, "got \(chunks)")
    }

    func testSplitEffortSmallerThanMinimumIsSingleChunk() {
        XCTAssertEqual(SchedulerService.splitEffort(minutes: 20, minBlock: 30, maxBlock: 90), [20])
    }

    // MARK: - schedule()

    func testScheduleSuccessRespectsWindowAndBuffer() {
        let settings = makeSettings() // wake 8, sleep 23, buffer 120
        let task = makeTask(effort: 120, deadlineHoursFromAnchor: 48)

        let result = SchedulerService.schedule(
            task: task, allBlocks: [], settings: settings, from: anchor
        )

        guard case .success(let blocks) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(blocks.reduce(0) { $0 + $1.durationMinutes }, 120)

        let windowEnd = task.deadline.addingTimeInterval(-Double(settings.deadlineBufferMinutes) * 60)
        for block in blocks {
            XCTAssertGreaterThanOrEqual(block.startTime, anchor)
            XCTAssertLessThanOrEqual(block.endTime, windowEnd, "block must respect deadline buffer")
            let hour = calendar.component(.hour, from: block.startTime)
            XCTAssertGreaterThanOrEqual(hour, settings.wakeHour)
        }
    }

    func testScheduleAvoidsExistingBlocks() {
        let settings = makeSettings()
        let existingTask = makeTask(effort: 60, deadlineHoursFromAnchor: 24)
        let occupying = ScheduledBlock(task: existingTask, startTime: anchor, durationMinutes: 120)
        context.insert(occupying)

        let task = makeTask(effort: 60, deadlineHoursFromAnchor: 24)
        let result = SchedulerService.schedule(
            task: task, allBlocks: [occupying], settings: settings, from: anchor
        )

        let blocks = scheduledBlocks(from: result)
        XCTAssertFalse(blocks.isEmpty)
        for block in blocks {
            let overlaps = block.startTime < occupying.endTime && block.endTime > occupying.startTime
            XCTAssertFalse(overlaps, "new block overlaps an existing one")
        }
    }

    func testOvernightSleepTimeStillSchedules() {
        // Sleep at 00:30 used to produce an empty window every day (sleep < wake).
        let settings = makeSettings()
        settings.sleepHour = 0
        settings.sleepMinute = 30

        let task = makeTask(effort: 60, deadlineHoursFromAnchor: 36)
        let result = SchedulerService.schedule(
            task: task, allBlocks: [], settings: settings, from: anchor
        )

        guard case .success = result else {
            return XCTFail("overnight sleep time should still yield slots, got \(result)")
        }
    }

    func testScheduleAvoidsBlockedTimes() {
        let settings = makeSettings()
        // Blocked every day 9:00–17:00; wake 8, sleep 23.
        let blocked = BlockedTime(
            label: "Class", weekdays: Array(1...7),
            startHour: 9, startMinute: 0, durationMinutes: 8 * 60
        )
        context.insert(blocked)

        let task = makeTask(effort: 60, deadlineHoursFromAnchor: 24)
        let result = SchedulerService.schedule(
            task: task, allBlocks: [], blockedTimes: [blocked], settings: settings, from: anchor
        )

        let blocks = scheduledBlocks(from: result)
        XCTAssertFalse(blocks.isEmpty)
        for block in blocks {
            for occurrence in blocked.occurrences(from: anchor, to: task.deadline) {
                let overlaps = block.startTime < occurrence.end && block.endTime > occurrence.start
                XCTAssertFalse(overlaps, "block booked over a blocked time")
            }
        }
    }

    func testPastDeadlineReturnsNoSlots() {
        let settings = makeSettings()
        let task = makeTask(effort: 60, deadlineHoursFromAnchor: -1)
        let result = SchedulerService.schedule(
            task: task, allBlocks: [], settings: settings, from: anchor
        )
        guard case .noSlots = result else {
            return XCTFail("expected noSlots, got \(result)")
        }
    }

    func testTightWindowReturnsPartialFit() {
        let settings = makeSettings() // buffer 120
        // Deadline 3.5h out → usable window is 9:00–10:30 (90 minutes).
        let task = makeTask(effort: 120, deadlineHoursFromAnchor: 3.5)
        let result = SchedulerService.schedule(
            task: task, allBlocks: [], settings: settings, from: anchor
        )
        guard case .partialFit(let blocks, let unscheduled) = result else {
            return XCTFail("expected partialFit, got \(result)")
        }
        XCTAssertEqual(blocks.reduce(0) { $0 + $1.durationMinutes }, 90)
        XCTAssertEqual(unscheduled, 30)
    }

    func testDailyFocusCapSpreadsWorkAcrossDays() {
        let settings = makeSettings()
        settings.dailyFocusMinutes = 60

        let task = makeTask(effort: 120, deadlineHoursFromAnchor: 96)
        let result = SchedulerService.schedule(
            task: task, allBlocks: [], settings: settings, from: anchor
        )

        let blocks = scheduledBlocks(from: result)
        XCTAssertEqual(blocks.reduce(0) { $0 + $1.durationMinutes }, 120)

        var perDay: [Date: Int] = [:]
        for block in blocks {
            perDay[calendar.startOfDay(for: block.startTime), default: 0] += block.durationMinutes
        }
        for (_, minutes) in perDay {
            XCTAssertLessThanOrEqual(minutes, 60, "daily focus cap exceeded")
        }
        XCTAssertGreaterThanOrEqual(perDay.count, 2, "cap should force a second day")
    }

    // MARK: - Catch-up

    func testCatchUpReplansMissedBlocks() throws {
        let settings = makeSettings()
        let task = makeTask(effort: 60, deadlineHoursFromAnchor: 48)

        // A block that came and went, unfinished, before the anchor.
        let missed = ScheduledBlock(
            task: task,
            startTime: anchor.addingTimeInterval(-3 * 3600),
            durationMinutes: 60
        )
        context.insert(missed)
        try context.save()

        let summary = SchedulerService.catchUpMissedBlocks(
            tasks: [task],
            allBlocks: [missed],
            blockedTimes: [],
            settings: settings,
            now: anchor,
            context: context
        )
        try context.save()

        XCTAssertEqual(summary.replannedTasks, 1)
        XCTAssertEqual(summary.unschedulableTasks, 0)
        let remaining = try context.fetch(FetchDescriptor<ScheduledBlock>())
        XCTAssertFalse(remaining.isEmpty, "replacement blocks should exist")
        for block in remaining {
            XCTAssertGreaterThanOrEqual(block.startTime, anchor, "missed block should be replanned into the future")
        }
    }

    func testCatchUpTopsUpUnderScheduledTasks() throws {
        let settings = makeSettings()
        // 120m task with only 60m of future coverage: nothing was missed, but
        // the plan is short, so catch-up rebalances and books the difference.
        let task = makeTask(effort: 120, deadlineHoursFromAnchor: 48)

        let done = ScheduledBlock(task: task, startTime: anchor.addingTimeInterval(-5 * 3600), durationMinutes: 60)
        done.isComplete = true
        let future = ScheduledBlock(task: task, startTime: anchor.addingTimeInterval(3600), durationMinutes: 60)
        context.insert(done)
        context.insert(future)
        try context.save()

        let summary = SchedulerService.catchUpMissedBlocks(
            tasks: [task],
            allBlocks: [done, future],
            blockedTimes: [],
            settings: settings,
            now: anchor,
            context: context
        )
        try context.save()

        XCTAssertEqual(summary.replannedTasks, 0, "no blocks were missed")
        XCTAssertEqual(summary.unschedulableTasks, 0)
        let all = try context.fetch(FetchDescriptor<ScheduledBlock>())
        let futureMinutes = all.filter { !$0.isComplete }.reduce(0) { $0 + $1.durationMinutes }
        XCTAssertEqual(futureMinutes, 120, "coverage should be topped up to the full remaining effort")
        XCTAssertTrue(all.contains { $0.isComplete }, "completed blocks stay untouched")
    }

    func testCatchUpDoesNothingWhenPlanIsHealthy() throws {
        let settings = makeSettings()
        // 60m task fully covered by one future block: catch-up must not touch it.
        let task = makeTask(effort: 60, deadlineHoursFromAnchor: 48)
        let future = ScheduledBlock(task: task, startTime: anchor.addingTimeInterval(3600), durationMinutes: 60)
        let futureId = future.id
        context.insert(future)
        try context.save()

        let summary = SchedulerService.catchUpMissedBlocks(
            tasks: [task],
            allBlocks: [future],
            blockedTimes: [],
            settings: settings,
            now: anchor,
            context: context
        )
        try context.save()

        XCTAssertEqual(summary, CatchUpSummary())
        let all = try context.fetch(FetchDescriptor<ScheduledBlock>())
        XCTAssertEqual(all.map(\.id), [futureId], "a healthy plan must not be rearranged")
    }

    // MARK: - Reschedule

    func testRescheduleReplacesUnlockedBlocks() throws {
        let settings = makeSettings()
        let task = makeTask(effort: 60, deadlineHoursFromAnchor: 48)
        let old = ScheduledBlock(task: task, startTime: anchor.addingTimeInterval(3600), durationMinutes: 60)
        let oldId = old.id
        context.insert(old)
        try context.save()

        let result = SchedulerService.reschedule(
            task: task, allBlocks: [old], settings: settings, context: context
        )
        try context.save()

        guard case .success = result else {
            return XCTFail("expected success, got \(result)")
        }
        let all = try context.fetch(FetchDescriptor<ScheduledBlock>())
        XCTAssertFalse(all.isEmpty, "reschedule must insert replacement blocks")
        XCTAssertFalse(all.contains { $0.id == oldId }, "old block should be gone")
    }

    // MARK: - Progress model

    func testBlockCompletionLogsTimeNotProgress() {
        let task = makeTask(effort: 100, deadlineHoursFromAnchor: 48)
        let block = ScheduledBlock(task: task, startTime: anchor, durationMinutes: 40)
        block.isComplete = true
        context.insert(block)

        // Checking a block means "I worked this time" — nothing more.
        XCTAssertEqual(task.timeSpentMinutes, 40)
        XCTAssertEqual(task.progressPercent, 0)
        XCTAssertEqual(task.remainingMinutes, 100)

        // Progress moves only when the user says so.
        task.manualProgressPercent = 70
        XCTAssertEqual(task.progressPercent, 70)
        XCTAssertEqual(task.remainingMinutes, 30)
    }

    // MARK: - Start rounding & buffer

    func testRoundUpToFiveMinutes() {
        let messy = anchor.addingTimeInterval(7 * 60 + 33) // 9:07:33
        XCTAssertEqual(
            SchedulerService.roundUpToFiveMinutes(messy),
            anchor.addingTimeInterval(10 * 60)
        )
        // Exact boundaries stay put.
        XCTAssertEqual(SchedulerService.roundUpToFiveMinutes(anchor), anchor)
    }

    func testScheduleStartsOnFiveMinuteBoundary() {
        let settings = makeSettings()
        let task = makeTask(effort: 60, deadlineHoursFromAnchor: 48)
        let messyStart = anchor.addingTimeInterval(2 * 60 + 41) // 9:02:41

        let result = SchedulerService.schedule(
            task: task, allBlocks: [], settings: settings, from: messyStart
        )
        let blocks = scheduledBlocks(from: result)
        XCTAssertFalse(blocks.isEmpty)
        for block in blocks {
            XCTAssertGreaterThanOrEqual(block.startTime, messyStart)
            let seconds = Int(block.startTime.timeIntervalSinceReferenceDate)
            XCTAssertEqual(seconds % 300, 0, "block should start on a 5-minute boundary")
        }
    }

    // MARK: - Blocked-time conflict replanning

    func testReplanBlockedTimeConflictsMovesOverlappingBlocks() throws {
        let settings = makeSettings()
        let task = makeTask(effort: 60, deadlineHoursFromAnchor: 48)
        // Booked 10:00–11:00, then a class lands on 10:00–12:00 every day.
        let block = ScheduledBlock(task: task, startTime: anchor.addingTimeInterval(3600), durationMinutes: 60)
        context.insert(block)
        let blocked = BlockedTime(
            label: "Class", weekdays: Array(1...7),
            startHour: 10, startMinute: 0, durationMinutes: 120
        )
        context.insert(blocked)
        try context.save()

        let replanned = SchedulerService.replanConflicts(
            tasks: [task],
            allBlocks: [block],
            blockedTimes: [blocked],
            settings: settings,
            now: anchor,
            context: context
        )
        try context.save()

        XCTAssertEqual(replanned, 1)
        let all = try context.fetch(FetchDescriptor<ScheduledBlock>())
        XCTAssertFalse(all.isEmpty, "the conflicting block should be replaced, not just deleted")
        for b in all {
            XCTAssertTrue(
                blocked.occurrences(from: b.startTime, to: b.endTime).isEmpty,
                "replanned block still overlaps the blocked time"
            )
        }
    }

    func testReplanBlockedTimeConflictsIgnoresNonConflictingTasks() throws {
        let settings = makeSettings()
        let task = makeTask(effort: 60, deadlineHoursFromAnchor: 48)
        // Booked 13:00–14:00; the class is 10:00–11:00 — no overlap.
        let block = ScheduledBlock(task: task, startTime: anchor.addingTimeInterval(4 * 3600), durationMinutes: 60)
        context.insert(block)
        let blocked = BlockedTime(
            label: "Class", weekdays: Array(1...7),
            startHour: 10, startMinute: 0, durationMinutes: 60
        )
        context.insert(blocked)
        try context.save()

        let replanned = SchedulerService.replanConflicts(
            tasks: [task],
            allBlocks: [block],
            blockedTimes: [blocked],
            settings: settings,
            now: anchor,
            context: context
        )

        XCTAssertEqual(replanned, 0, "untouched schedules must stay untouched")
        let all = try context.fetch(FetchDescriptor<ScheduledBlock>())
        XCTAssertEqual(all.count, 1)
    }

    // MARK: - Busy events (imported calendar)

    func testScheduleAvoidsBusyEvents() {
        let settings = makeSettings()
        // Imported event 9:00–15:00 on the anchor day.
        let busy = BusyEvent(
            source: .appleCalendar,
            sourceId: "evt-1",
            title: "Conference",
            startTime: anchor,
            endTime: anchor.addingTimeInterval(6 * 3600)
        )
        context.insert(busy)

        let task = makeTask(effort: 60, deadlineHoursFromAnchor: 24)
        let result = SchedulerService.schedule(
            task: task, allBlocks: [], busyEvents: [busy], settings: settings, from: anchor
        )

        let blocks = scheduledBlocks(from: result)
        XCTAssertFalse(blocks.isEmpty)
        for block in blocks {
            let overlaps = block.startTime < busy.endTime && block.endTime > busy.startTime
            XCTAssertFalse(overlaps, "block booked over an imported calendar event")
        }
    }

    func testReplanConflictsMovesBlocksOffBusyEvents() throws {
        let settings = makeSettings()
        let task = makeTask(effort: 60, deadlineHoursFromAnchor: 48)
        // Booked 10:00–11:00, then an imported event lands right on top.
        let block = ScheduledBlock(task: task, startTime: anchor.addingTimeInterval(3600), durationMinutes: 60)
        context.insert(block)
        let busy = BusyEvent(
            source: .appleCalendar,
            sourceId: "evt-2",
            title: "Dentist",
            startTime: anchor.addingTimeInterval(3600),
            endTime: anchor.addingTimeInterval(2 * 3600)
        )
        context.insert(busy)
        try context.save()

        let replanned = SchedulerService.replanConflicts(
            tasks: [task],
            allBlocks: [block],
            blockedTimes: [],
            busyEvents: [busy],
            settings: settings,
            now: anchor,
            context: context
        )
        try context.save()

        XCTAssertEqual(replanned, 1)
        let all = try context.fetch(FetchDescriptor<ScheduledBlock>())
        XCTAssertFalse(all.isEmpty)
        for b in all {
            let overlaps = b.startTime < busy.endTime && b.endTime > busy.startTime
            XCTAssertFalse(overlaps, "replanned block still overlaps the imported event")
        }
    }

    // MARK: - Catch-up: no overbooking, clear surfacing

    func testCatchUpDoesNotOverbookTasksWithFutureBlocks() throws {
        let settings = makeSettings()
        // 120m task: 60m missed + 60m still scheduled in the future. Catch-up
        // must replan through the reschedule path so total coverage stays 120m.
        let task = makeTask(effort: 120, deadlineHoursFromAnchor: 72)
        let missed = ScheduledBlock(task: task, startTime: anchor.addingTimeInterval(-3 * 3600), durationMinutes: 60)
        let future = ScheduledBlock(task: task, startTime: anchor.addingTimeInterval(6 * 3600), durationMinutes: 60)
        context.insert(missed)
        context.insert(future)
        try context.save()

        let summary = SchedulerService.catchUpMissedBlocks(
            tasks: [task],
            allBlocks: [missed, future],
            blockedTimes: [],
            settings: settings,
            now: anchor,
            context: context
        )
        try context.save()

        XCTAssertEqual(summary.replannedTasks, 1)
        let all = try context.fetch(FetchDescriptor<ScheduledBlock>())
        let totalMinutes = all.filter { !$0.isComplete }.reduce(0) { $0 + $1.durationMinutes }
        XCTAssertEqual(totalMinutes, 120, "catch-up must not double-book remaining effort")
        for block in all {
            XCTAssertGreaterThanOrEqual(block.endTime, anchor, "no dangling past block may survive")
        }
    }

    func testCatchUpSurfacesUnschedulableTasks() throws {
        let settings = makeSettings() // deadline buffer 120
        // Missed block, and the deadline is now too close for any replacement.
        let task = makeTask(effort: 60, deadlineHoursFromAnchor: 1)
        let missed = ScheduledBlock(task: task, startTime: anchor.addingTimeInterval(-2 * 3600), durationMinutes: 60)
        context.insert(missed)
        try context.save()

        let summary = SchedulerService.catchUpMissedBlocks(
            tasks: [task],
            allBlocks: [missed],
            blockedTimes: [],
            settings: settings,
            now: anchor,
            context: context
        )
        try context.save()

        XCTAssertEqual(summary.replannedTasks, 1)
        XCTAssertEqual(summary.unschedulableTasks, 1, "impossible fits must be surfaced, not silent")
        let all = try context.fetch(FetchDescriptor<ScheduledBlock>())
        XCTAssertTrue(all.isEmpty, "the dangling missed block must be removed either way")
    }

    // MARK: - Rebalance (earliest deadline first)

    func testRebalanceBumpsFartherDeadlineForUrgentTask() throws {
        let settings = makeSettings() // buffer 120, start buffer 15
        // A relaxed task holds the only slot an urgent task could use:
        // its block sits 9:00-11:00, and the urgent task is due in 3 hours
        // (usable window ends 10:00).
        let relaxed = makeTask(effort: 120, deadlineHoursFromAnchor: 30)
        let occupying = ScheduledBlock(task: relaxed, startTime: anchor, durationMinutes: 120)
        context.insert(occupying)

        let urgent = makeTask(effort: 30, deadlineHoursFromAnchor: 3)
        try context.save()

        // Gap-fill alone fails: the near window is taken.
        let gapFill = SchedulerService.schedule(
            task: urgent, allBlocks: [occupying], settings: settings,
            from: anchor.addingTimeInterval(15 * 60)
        )
        guard case .noSlots = gapFill else {
            return XCTFail("expected the urgent task not to fit as-is, got \(gapFill)")
        }

        // Rebalance moves the relaxed work aside.
        let summary = SchedulerService.rebalance(
            tasks: [relaxed, urgent],
            allBlocks: [occupying],
            blockedTimes: [],
            settings: settings,
            now: anchor,
            context: context
        )
        try context.save()

        XCTAssertEqual(summary.unschedulableTasks, 0, "both tasks should fit after rebalancing")

        let all = try context.fetch(FetchDescriptor<ScheduledBlock>())
        let urgentWindowEnd = urgent.deadline.addingTimeInterval(-Double(settings.deadlineBufferMinutes) * 60)
        let urgentBlocks = all.filter { $0.task?.id == urgent.id }
        let relaxedBlocks = all.filter { $0.task?.id == relaxed.id }

        XCTAssertEqual(urgentBlocks.reduce(0) { $0 + $1.durationMinutes }, 30)
        for block in urgentBlocks {
            XCTAssertLessThanOrEqual(block.endTime, urgentWindowEnd, "urgent task must finish before its buffered deadline")
        }
        XCTAssertEqual(relaxedBlocks.reduce(0) { $0 + $1.durationMinutes }, 120, "bumped work is rescheduled, not dropped")

        // No overlaps anywhere.
        let sorted = all.sorted { $0.startTime < $1.startTime }
        for (a, b) in zip(sorted, sorted.dropFirst()) {
            XCTAssertLessThanOrEqual(a.endTime, b.startTime, "rebalanced blocks must not overlap")
        }
    }

    // MARK: - Estimate advisor

    /// A completed task with a real planned-vs-actual record: `spent` minutes
    /// of tracked sessions against an `effort`-minute estimate.
    @discardableResult
    private func makeCompletedTask(
        taskContext: TaskContext = .school,
        effort: Int,
        spent: Int,
        completedDaysAgo: Int = 1
    ) -> LoomTask {
        let completedAt = anchor.addingTimeInterval(-Double(completedDaysAgo) * 86_400)
        let task = LoomTask(
            title: "Done task",
            context: taskContext,
            deadline: completedAt,
            effortMinutes: effort
        )
        task.isComplete = true
        task.completedAt = completedAt
        context.insert(task)
        let session = WorkSession(
            task: task,
            startedAt: completedAt.addingTimeInterval(-Double(spent) * 60),
            durationSeconds: spent * 60
        )
        context.insert(session)
        return task
    }

    func testEstimateAdvisorNeedsThreeSamples() throws {
        makeCompletedTask(effort: 60, spent: 120)
        makeCompletedTask(effort: 60, spent: 120)
        try context.save()

        XCTAssertNil(
            EstimateAdvisor.advice(for: .school, effortMinutes: 60, in: context),
            "two samples are an anecdote, not a pattern"
        )
    }

    func testEstimateAdvisorSuggestsMedianOverrun() throws {
        makeCompletedTask(effort: 60, spent: 90)   // 1.5×
        makeCompletedTask(effort: 60, spent: 96)   // 1.6×
        makeCompletedTask(effort: 60, spent: 102)  // 1.7×
        try context.save()

        let advice = try XCTUnwrap(EstimateAdvisor.advice(for: .school, effortMinutes: 60, in: context))
        XCTAssertEqual(advice.sampleCount, 3)
        XCTAssertEqual(advice.ratio, 1.6, accuracy: 0.01)
        // 60 × 1.6 = 96, rounded to the nearest 15.
        XCTAssertEqual(advice.suggestedMinutes, 90)
    }

    func testEstimateAdvisorCapsSuggestionAtDouble() throws {
        makeCompletedTask(effort: 60, spent: 180)  // 3×
        makeCompletedTask(effort: 60, spent: 180)
        makeCompletedTask(effort: 60, spent: 180)
        try context.save()

        let advice = try XCTUnwrap(EstimateAdvisor.advice(for: .school, effortMinutes: 60, in: context))
        XCTAssertEqual(advice.ratio, 3.0, accuracy: 0.01, "the shown ratio stays honest")
        XCTAssertEqual(advice.suggestedMinutes, 120, "the suggestion is capped at 2× the guess")
    }

    func testEstimateAdvisorSilentWhenEstimatesAreHonest() throws {
        makeCompletedTask(effort: 60, spent: 55)
        makeCompletedTask(effort: 60, spent: 60)
        makeCompletedTask(effort: 60, spent: 66)
        try context.save()

        XCTAssertNil(
            EstimateAdvisor.advice(for: .school, effortMinutes: 60, in: context),
            "roughly accurate history should not interrupt capture"
        )
    }

    func testEstimateAdvisorIgnoresOtherContextsAndUntrackedTasks() throws {
        // Chronic over-runs, but all in Work…
        makeCompletedTask(taskContext: .work, effort: 60, spent: 150)
        makeCompletedTask(taskContext: .work, effort: 60, spent: 150)
        makeCompletedTask(taskContext: .work, effort: 60, spent: 150)
        // …and School completions with no tracked time say nothing.
        let untracked = makeTask(effort: 60, deadlineHoursFromAnchor: -24)
        untracked.isComplete = true
        untracked.completedAt = anchor
        try context.save()

        XCTAssertNil(
            EstimateAdvisor.advice(for: .school, effortMinutes: 60, in: context),
            "advice must come from the same context and only from tracked work"
        )
        XCTAssertNotNil(
            EstimateAdvisor.advice(for: .work, effortMinutes: 60, in: context),
            "the Work record itself should still advise Work captures"
        )
    }

    func testEstimateAdvisorUsesFiveMostRecentSamples() throws {
        // Old habit: wild over-runs, further in the past.
        for daysAgo in 10...14 {
            makeCompletedTask(effort: 60, spent: 180, completedDaysAgo: daysAgo)
        }
        // Recent record: dead-on estimates.
        for daysAgo in 1...5 {
            makeCompletedTask(effort: 60, spent: 60, completedDaysAgo: daysAgo)
        }
        try context.save()

        XCTAssertNil(
            EstimateAdvisor.advice(for: .school, effortMinutes: 60, in: context),
            "recent accuracy should outweigh an older over-run habit"
        )
    }
}
