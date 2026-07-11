import XCTest
import SwiftData
@testable import Loom

final class LoomTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private let calendar = Calendar.current

    override func setUpWithError() throws {
        let schema = Schema([
            LoomTask.self, TaskTemplate.self, ScheduledBlock.self, WorkSession.self,
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

    // MARK: - Start streaks

    /// Noon on the day `daysAgo` days before the anchor.
    private func startDate(daysAgo: Int) -> Date {
        calendar.date(byAdding: .day, value: -daysAgo, to: anchor)!
    }

    func testStreakCountsConsecutiveStartDays() {
        let starts = [0, 1, 2, 3].map(startDate(daysAgo:))
        XCTAssertEqual(StreakCalculator.startStreak(startDates: starts, now: anchor), 4)
    }

    func testStreakEmptyHistoryIsZero() {
        XCTAssertEqual(StreakCalculator.startStreak(startDates: [], now: anchor), 0)
    }

    func testStreakTodayWithoutStartDoesNotBreak() {
        // Started yesterday and the day before; nothing yet today.
        let starts = [1, 2].map(startDate(daysAgo:))
        XCTAssertEqual(
            StreakCalculator.startStreak(startDates: starts, now: anchor), 2,
            "an unfinished today must neither break nor count"
        )
    }

    func testStreakMendsBridgeShortGaps() {
        // Started 0, 1, 3, 4 days ago — the single missed day is mended and
        // counted, so the thread reads 5.
        let starts = [0, 1, 3, 4].map(startDate(daysAgo:))
        XCTAssertEqual(StreakCalculator.startStreak(startDates: starts, now: anchor), 5)
    }

    func testStreakBreaksWhenWeeklyMendsRunOut() {
        // A five-day gap can never be mended (at most 2 mends per week, and
        // the gap spans at most two calendar weeks), wherever the week breaks.
        let starts = [0, 6, 7].map(startDate(daysAgo:))
        XCTAssertEqual(
            StreakCalculator.startStreak(startDates: starts, now: anchor), 1,
            "a five-day gap should end the chain at today's start"
        )
    }

    // MARK: - Pace (schedule pressure)

    func testAvailableMinutesSubtractsOtherWork() {
        let settings = makeSettings() // wake 8, sleep 23
        let other = makeTask(effort: 120, deadlineHoursFromAnchor: 48)
        let block = ScheduledBlock(task: other, startTime: anchor, durationMinutes: 120)
        context.insert(block)

        // 9:00 → 14:00 = 300 minutes, minus the 120-minute block.
        let available = SchedulerService.availableMinutes(
            from: anchor,
            to: anchor.addingTimeInterval(5 * 3600),
            allBlocks: [block],
            settings: settings
        )
        XCTAssertEqual(available, 180)
    }

    func testAvailableMinutesIgnoresOwnBlocks() {
        let settings = makeSettings()
        let task = makeTask(effort: 120, deadlineHoursFromAnchor: 48)
        let ownBlock = ScheduledBlock(task: task, startTime: anchor, durationMinutes: 120)
        context.insert(ownBlock)

        let available = SchedulerService.availableMinutes(
            from: anchor,
            to: anchor.addingTimeInterval(5 * 3600),
            excludingTaskId: task.id,
            allBlocks: [ownBlock],
            settings: settings
        )
        XCTAssertEqual(available, 300, "a task's own booked time still belongs to it")
    }

    func testPressureReflectsRemainingVersusFreeTime() throws {
        let settings = makeSettings() // buffer 120
        // 60m of work; window 9:00 → deadline(anchor+7h)−2h buffer = 14:00 → 300 free.
        let task = makeTask(effort: 60, deadlineHoursFromAnchor: 7)
        let pressure = try XCTUnwrap(SchedulerService.pressure(
            for: task, allBlocks: [], settings: settings, now: anchor
        ))
        XCTAssertEqual(pressure, 0.2, accuracy: 0.01)
    }

    func testPressureInfiniteWhenNoWindowRemains() throws {
        let settings = makeSettings() // buffer 120
        // Deadline in 1h, buffer 2h: the usable window is already gone.
        let task = makeTask(effort: 60, deadlineHoursFromAnchor: 1)
        let pressure = try XCTUnwrap(SchedulerService.pressure(
            for: task, allBlocks: [], settings: settings, now: anchor
        ))
        XCTAssertTrue(pressure.isInfinite)
    }

    func testPressureNilWithoutRemainingEffort() {
        let settings = makeSettings()
        let task = makeTask(effort: 60, deadlineHoursFromAnchor: 24)
        task.manualProgressPercent = 100
        XCTAssertNil(SchedulerService.pressure(
            for: task, allBlocks: [], settings: settings, now: anchor
        ))
    }

    // MARK: - Daily digests

    private func digestBlock(
        title: String = "Lab report",
        startHour: Double,
        minutes: Int = 60,
        isComplete: Bool = false
    ) -> BlockNotificationService.DigestBlock {
        let start = anchor.addingTimeInterval((startHour - 9) * 3600)
        return BlockNotificationService.DigestBlock(
            title: title,
            start: start,
            end: start.addingTimeInterval(Double(minutes) * 60),
            isComplete: isComplete
        )
    }

    func testMorningDigestNamesFirstBlockAndDayShape() throws {
        let body = try XCTUnwrap(BlockNotificationService.morningDigestBody(dayBlocks: [
            digestBlock(title: "Lab report", startHour: 9),
            digestBlock(title: "Essay", startHour: 13, minutes: 90),
            digestBlock(title: "Reading", startHour: 11)
        ]))
        XCTAssertTrue(body.contains("Lab report"), "leads with the first block: \(body)")
        XCTAssertTrue(body.contains("3 blocks"), "names the day's shape: \(body)")
        XCTAssertTrue(body.contains("2:30"), "ends with when the day is done: \(body)")
    }

    func testMorningDigestNilOnEmptyDay() {
        XCTAssertNil(BlockNotificationService.morningDigestBody(dayBlocks: []))
    }

    func testEveningDigestCountsAndPreviewsTomorrow() throws {
        let body = try XCTUnwrap(BlockNotificationService.eveningDigestBody(
            todayBlocks: [
                digestBlock(startHour: 9, isComplete: true),
                digestBlock(startHour: 11, isComplete: true),
                digestBlock(startHour: 14)
            ],
            tomorrowFirst: digestBlock(title: "Problem set", startHour: 10)
        ))
        XCTAssertTrue(body.contains("2 of 3"), "honest done count: \(body)")
        XCTAssertTrue(body.contains("Problem set"), "pre-loads tomorrow's opener: \(body)")
    }

    func testEveningDigestNilWhenNothingToSay() {
        XCTAssertNil(BlockNotificationService.eveningDigestBody(
            todayBlocks: [], tomorrowFirst: nil
        ))
    }

    // MARK: - Recurring tasks

    func testMaterializeStampsOccurrencesTwoWeeksAhead() throws {
        let settings = makeSettings()
        let template = TaskTemplate(
            title: "Weekly problem set",
            context: .school,
            effortMinutes: 60,
            nextDeadline: anchor.addingTimeInterval(3 * 86_400),
            repeatUntil: anchor.addingTimeInterval(60 * 86_400)
        )
        context.insert(template)
        try context.save()

        let created = SchedulerService.materializeRecurringTasks(
            templates: [template],
            allBlocks: [],
            settings: settings,
            now: anchor,
            context: context
        )
        try context.save()

        // Deadlines at day 3 and day 10 fall inside the 14-day horizon; day 17 doesn't.
        XCTAssertEqual(created, 2)
        let tasks = try context.fetch(FetchDescriptor<LoomTask>())
            .filter { $0.source == .recurring }
        XCTAssertEqual(tasks.count, 2)
        for task in tasks {
            XCTAssertEqual(task.templateId, template.id)
            XCTAssertFalse(task.scheduledBlocks.isEmpty, "occurrences arrive already scheduled")
        }
        XCTAssertEqual(
            template.nextDeadline,
            anchor.addingTimeInterval(17 * 86_400),
            "the template must remember where it left off"
        )

        // A second pass right away must not duplicate anything.
        let secondPass = SchedulerService.materializeRecurringTasks(
            templates: [template],
            allBlocks: try context.fetch(FetchDescriptor<ScheduledBlock>()),
            settings: settings,
            now: anchor,
            context: context
        )
        XCTAssertEqual(secondPass, 0)
    }

    func testMaterializeSkipsMissedOccurrencesWithoutGuilt() throws {
        let settings = makeSettings()
        // The app wasn't opened for a while: one occurrence is already past.
        let template = TaskTemplate(
            title: "Weekly reading",
            context: .school,
            effortMinutes: 30,
            nextDeadline: anchor.addingTimeInterval(-3 * 86_400),
            repeatUntil: anchor.addingTimeInterval(60 * 86_400)
        )
        context.insert(template)
        try context.save()

        let created = SchedulerService.materializeRecurringTasks(
            templates: [template],
            allBlocks: [],
            settings: settings,
            now: anchor,
            context: context
        )
        try context.save()

        // Day −3 is skipped; days +4 and +11 materialize.
        XCTAssertEqual(created, 2)
        let tasks = try context.fetch(FetchDescriptor<LoomTask>())
        XCTAssertTrue(
            tasks.allSatisfy { $0.deadline > anchor },
            "a recurrence must never spawn an already-overdue task"
        )
    }

    func testMaterializeRetiresExhaustedTemplates() throws {
        let settings = makeSettings()
        let template = TaskTemplate(
            title: "Short-lived chore",
            context: .personal,
            effortMinutes: 30,
            nextDeadline: anchor.addingTimeInterval(2 * 86_400),
            repeatUntil: anchor.addingTimeInterval(5 * 86_400)
        )
        context.insert(template)
        try context.save()

        let created = SchedulerService.materializeRecurringTasks(
            templates: [template],
            allBlocks: [],
            settings: settings,
            now: anchor,
            context: context
        )
        try context.save()

        XCTAssertEqual(created, 1, "only the day-2 occurrence fits before repeatUntil")
        let remaining = try context.fetch(FetchDescriptor<TaskTemplate>())
        XCTAssertTrue(remaining.isEmpty, "an exhausted template deletes itself")
    }

    // MARK: - Weave

    func testWeaveAggregatesSessionsAndCheckedBlocksByDay() throws {
        let school = makeTask(effort: 300, deadlineHoursFromAnchor: 48)
        let personal = LoomTask(
            title: "Chores", context: .personal,
            deadline: anchor.addingTimeInterval(48 * 3600), effortMinutes: 120
        )
        context.insert(personal)

        // Today: two school sessions and a checked personal block.
        let s1 = WorkSession(task: school, startedAt: anchor, durationSeconds: 60 * 60)
        let s2 = WorkSession(task: school, startedAt: anchor.addingTimeInterval(3 * 3600), durationSeconds: 30 * 60)
        let checked = ScheduledBlock(task: personal, startTime: anchor.addingTimeInterval(3600), durationMinutes: 45)
        checked.isComplete = true
        // Yesterday: one personal session. An unchecked block must not count.
        let s3 = WorkSession(task: personal, startedAt: anchor.addingTimeInterval(-24 * 3600), durationSeconds: 20 * 60)
        let unchecked = ScheduledBlock(task: school, startTime: anchor.addingTimeInterval(-24 * 3600), durationMinutes: 90)
        context.insert(s1)
        context.insert(s2)
        context.insert(checked)
        context.insert(s3)
        context.insert(unchecked)
        try context.save()

        let days = WeaveBuilder.days(
            sessions: [s1, s2, s3],
            blocks: [checked, unchecked],
            daysBack: 7,
            now: anchor
        )

        XCTAssertEqual(days.count, 7)
        let today = try XCTUnwrap(days.last)
        XCTAssertEqual(today.minutesByContext[.school], 90)
        XCTAssertEqual(today.minutesByContext[.personal], 45)
        XCTAssertEqual(today.sessionCount, 2, "checked blocks add minutes, not starts")

        let yesterday = days[5]
        XCTAssertEqual(yesterday.minutesByContext[.personal], 20)
        XCTAssertNil(yesterday.minutesByContext[.school], "unchecked blocks contribute nothing")
        XCTAssertEqual(yesterday.sessionCount, 1)

        XCTAssertEqual(days[0].totalMinutes, 0, "untouched days stay empty")
    }

    func testWeaveEstimateHeatIsMedianAcrossContexts() {
        makeCompletedTask(taskContext: .school, effort: 60, spent: 90)    // 1.5×
        makeCompletedTask(taskContext: .work, effort: 60, spent: 60)      // 1.0×
        makeCompletedTask(taskContext: .personal, effort: 60, spent: 120) // 2.0×
        let tasks = (try? context.fetch(FetchDescriptor<LoomTask>())) ?? []

        let heat = WeaveBuilder.estimateHeat(tasks: tasks)
        XCTAssertEqual(heat ?? 0, 1.5, accuracy: 0.01)
    }

    func testWeaveEstimateHeatNeedsThreeSamples() {
        makeCompletedTask(effort: 60, spent: 120)
        let tasks = (try? context.fetch(FetchDescriptor<LoomTask>())) ?? []
        XCTAssertNil(WeaveBuilder.estimateHeat(tasks: tasks))
    }

    // MARK: - Block push ("can't right now")

    func testRescheduleHonorsEarliestStart() throws {
        let settings = makeSettings()
        let task = makeTask(effort: 60, deadlineHoursFromAnchor: 72)
        let soon = ScheduledBlock(task: task, startTime: anchor.addingTimeInterval(600), durationMinutes: 60)
        context.insert(soon)
        try context.save()

        // "Push to tomorrow": nothing may land before the requested start.
        let tomorrowWake = calendar.date(
            bySettingHour: 8, minute: 0, second: 0,
            of: calendar.date(byAdding: .day, value: 1, to: anchor)!
        )!
        let result = SchedulerService.reschedule(
            task: task,
            allBlocks: [soon],
            settings: settings,
            from: tomorrowWake,
            context: context
        )
        try context.save()

        guard case .success = result else {
            return XCTFail("expected the pushed task to fit, got \(result)")
        }
        let all = try context.fetch(FetchDescriptor<ScheduledBlock>())
        XCTAssertFalse(all.isEmpty)
        for block in all {
            XCTAssertGreaterThanOrEqual(
                block.startTime, tomorrowWake,
                "a pushed plan must not sneak work back before the chosen start"
            )
        }
    }

    // MARK: - Data export

    func testDataExportRoundTrips() throws {
        let task = makeTask(effort: 90, deadlineHoursFromAnchor: 48)
        task.firstStep = "Open the doc"
        let block = ScheduledBlock(task: task, startTime: anchor, durationMinutes: 45)
        context.insert(block)
        let session = WorkSession(task: task, startedAt: anchor, durationSeconds: 1200)
        context.insert(session)
        let reminder = Reminder(title: "Take meds", dueDate: anchor.addingTimeInterval(3600))
        context.insert(reminder)
        let blocked = BlockedTime(label: "Class", weekdays: [2, 4], startHour: 10, startMinute: 30, durationMinutes: 90)
        context.insert(blocked)
        let template = TaskTemplate(
            title: "Weekly set", context: .school, effortMinutes: 60,
            nextDeadline: anchor.addingTimeInterval(7 * 86_400),
            repeatUntil: anchor.addingTimeInterval(30 * 86_400)
        )
        context.insert(template)
        try context.save()

        let data = try DataExporter.exportJSON(context: context)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let export = try decoder.decode(DataExporter.Export.self, from: data)

        XCTAssertEqual(export.version, 1)
        XCTAssertEqual(export.tasks.count, 1)
        XCTAssertEqual(export.blocks.count, 1)
        XCTAssertEqual(export.workSessions.count, 1)
        XCTAssertEqual(export.reminders.count, 1)
        XCTAssertEqual(export.blockedTimes.count, 1)
        XCTAssertEqual(export.templates.count, 1)

        let exportedTask = try XCTUnwrap(export.tasks.first)
        XCTAssertEqual(exportedTask.id, task.id)
        XCTAssertEqual(exportedTask.firstStep, "Open the doc")
        XCTAssertEqual(exportedTask.context, "School")
        XCTAssertEqual(export.blocks.first?.taskId, task.id, "relations survive as id references")
        XCTAssertEqual(export.blockedTimes.first?.weekdays, [2, 4])
    }
}
