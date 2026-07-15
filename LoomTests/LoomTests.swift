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

    func testScheduleAdaptsChunksToSeparateHourGaps() {
        let settings = makeSettings()
        settings.wakeHour = 9
        settings.sleepHour = 13

        let occupyingTask = makeTask(effort: 120, deadlineHoursFromAnchor: 24)
        let firstHold = ScheduledBlock(
            task: occupyingTask,
            startTime: anchor.addingTimeInterval(60 * 60),
            durationMinutes: 60
        )
        let secondHold = ScheduledBlock(
            task: occupyingTask,
            startTime: anchor.addingTimeInterval(3 * 60 * 60),
            durationMinutes: 60
        )
        context.insert(firstHold)
        context.insert(secondHold)

        // Buffered window ends at 13:00, leaving only 9–10 and 11–12.
        // A fixed [90, 30] split cannot use either first gap; slot-aware
        // placement should adapt it to [60, 60].
        let task = makeTask(effort: 120, deadlineHoursFromAnchor: 6)
        let result = SchedulerService.schedule(
            task: task,
            allBlocks: [firstHold, secondHold],
            settings: settings,
            from: anchor
        )

        guard case .success(let blocks) = result else {
            return XCTFail("expected both hour gaps to fit, got \(result)")
        }
        XCTAssertEqual(blocks.map(\.durationMinutes), [60, 60])
        XCTAssertEqual(
            blocks.map(\.startTime),
            [anchor, anchor.addingTimeInterval(2 * 60 * 60)]
        )
    }

    func testScheduleLooksAheadAcrossThreeSeparateFortyFiveMinuteGaps() {
        let settings = makeSettings()
        settings.wakeHour = 9
        settings.sleepHour = 13
        settings.minBlockMinutes = 30
        settings.maxBlockMinutes = 90
        settings.dailyFocusMinutes = 0

        let occupyingTask = makeTask(effort: 105, deadlineHoursFromAnchor: 24)
        let holds = [
            ScheduledBlock(
                task: occupyingTask,
                startTime: anchor.addingTimeInterval(45 * 60),
                durationMinutes: 15
            ),
            ScheduledBlock(
                task: occupyingTask,
                startTime: anchor.addingTimeInterval(105 * 60),
                durationMinutes: 15
            ),
            ScheduledBlock(
                task: occupyingTask,
                startTime: anchor.addingTimeInterval(165 * 60),
                durationMinutes: 75
            )
        ]
        for hold in holds { context.insert(hold) }

        // The usable window is exactly three independent 45-minute gaps.
        // Treating a 55-minute tail as one theoretical block would strand it;
        // looking at the actual future gaps yields 40 + 30 + 30 instead.
        let task = makeTask(effort: 100, deadlineHoursFromAnchor: 6)
        let result = SchedulerService.schedule(
            task: task,
            allBlocks: holds,
            settings: settings,
            from: anchor
        )

        guard case .success(let blocks) = result else {
            return XCTFail("expected all three gaps to fit, got \(result)")
        }
        XCTAssertEqual(blocks.map(\.durationMinutes), [40, 30, 30])
        XCTAssertEqual(
            blocks.map(\.startTime),
            [
                anchor,
                anchor.addingTimeInterval(60 * 60),
                anchor.addingTimeInterval(120 * 60)
            ]
        )
    }

    func testScheduleAllowsShortRemainderInShortSlot() {
        let settings = makeSettings() // configured minimum is 30 minutes
        settings.wakeHour = 9
        settings.sleepHour = 10

        let busy = BusyEvent(
            source: .appleCalendar,
            sourceId: "short-remainder",
            title: "Appointment",
            startTime: anchor.addingTimeInterval(20 * 60),
            endTime: anchor.addingTimeInterval(60 * 60)
        )
        context.insert(busy)

        let task = makeTask(effort: 20, deadlineHoursFromAnchor: 3)
        let result = SchedulerService.schedule(
            task: task,
            allBlocks: [],
            busyEvents: [busy],
            settings: settings,
            from: anchor
        )

        guard case .success(let blocks) = result else {
            return XCTFail("expected the 20-minute remainder to fit, got \(result)")
        }
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.first?.startTime, anchor)
        XCTAssertEqual(blocks.first?.durationMinutes, 20)
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

    func testDailyFocusCapPreservesRepresentableTailAcrossThreeDays() {
        let settings = makeSettings()
        settings.wakeHour = 9
        settings.sleepHour = 9
        settings.sleepMinute = 45
        settings.minBlockMinutes = 30
        settings.maxBlockMinutes = 90
        settings.dailyFocusMinutes = 45

        // Three 45-minute days can hold 100 minutes, but taking 45 first would
        // strand 55 minutes, which cannot be expressed in 30...45 blocks.
        let task = makeTask(effort: 100, deadlineHoursFromAnchor: 74)
        let result = SchedulerService.schedule(
            task: task,
            allBlocks: [],
            settings: settings,
            from: anchor
        )

        guard case .success(let blocks) = result else {
            return XCTFail("expected all three days to fit, got \(result)")
        }
        XCTAssertEqual(blocks.map(\.durationMinutes), [40, 30, 30])
        XCTAssertEqual(Set(blocks.map { calendar.startOfDay(for: $0.startTime) }).count, 3)
    }

    func testDailyFocusCapSplitsOvernightBlocksAcrossCalendarDays() {
        let settings = makeSettings()
        settings.wakeHour = 22
        settings.sleepHour = 2
        settings.dailyFocusMinutes = 100
        settings.minBlockMinutes = 90
        settings.maxBlockMinutes = 90

        let day = calendar.startOfDay(for: anchor)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: day)!
        let start = calendar.date(bySettingHour: 21, minute: 0, second: 0, of: day)!
        let existingStart = calendar.date(
            bySettingHour: 22, minute: 0, second: 0, of: nextDay
        )!
        let existingTask = makeTask(effort: 90, deadlineHoursFromAnchor: 120)
        let existing = ScheduledBlock(
            task: existingTask,
            startTime: existingStart,
            durationMinutes: 90
        )
        context.insert(existing)

        // Leave 23:00–02:00 open on the first overnight window. Charging a
        // 23:00–00:30 candidate only to its start day would put 120 minutes on
        // the following calendar day once the existing block is included.
        let busy = BusyEvent(
            source: .appleCalendar,
            sourceId: "overnight-cap",
            title: "Evening commitment",
            startTime: calendar.date(
                bySettingHour: 22, minute: 0, second: 0, of: day
            )!,
            endTime: calendar.date(
                bySettingHour: 23, minute: 0, second: 0, of: day
            )!
        )
        context.insert(busy)

        let task = makeTask(effort: 90, deadlineHoursFromAnchor: 120)
        let result = SchedulerService.schedule(
            task: task,
            allBlocks: [existing],
            busyEvents: [busy],
            settings: settings,
            from: start
        )
        let blocks = scheduledBlocks(from: result)
        XCTAssertEqual(blocks.reduce(0) { $0 + $1.durationMinutes }, 90)

        var perDay: [Date: Double] = [:]
        for block in [existing] + blocks {
            var cursor = block.startTime
            while cursor < block.endTime {
                let calendarDay = calendar.startOfDay(for: cursor)
                let followingDay = calendar.date(
                    byAdding: .day, value: 1, to: calendarDay
                )!
                let portionEnd = min(block.endTime, followingDay)
                perDay[calendarDay, default: 0] += portionEnd.timeIntervalSince(cursor) / 60
                cursor = portionEnd
            }
        }
        for (_, minutes) in perDay {
            XCTAssertLessThanOrEqual(minutes, 100, "daily focus cap exceeded")
        }
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

        XCTAssertEqual(summary.adjustedTasks, 1)
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

        XCTAssertEqual(summary.adjustedTasks, 1, "the topped-up plan should be surfaced")
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

    func testCatchUpReleasesAndReplansMissedLockedBlock() throws {
        let settings = makeSettings()
        let task = makeTask(effort: 60, deadlineHoursFromAnchor: 48)
        let missed = ScheduledBlock(
            task: task,
            startTime: anchor.addingTimeInterval(-3 * 3600),
            durationMinutes: 60
        )
        missed.isLocked = true
        let missedId = missed.id
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

        XCTAssertEqual(summary.adjustedTasks, 1)
        XCTAssertEqual(summary.replannedTasks, 1)
        let remaining = try context.fetch(FetchDescriptor<ScheduledBlock>())
        XCTAssertFalse(remaining.contains { $0.id == missedId }, "elapsed time cannot stay reserved by a lock")
        XCTAssertEqual(remaining.reduce(0) { $0 + $1.durationMinutes }, 60)
        XCTAssertTrue(remaining.allSatisfy { $0.startTime >= anchor })
    }

    func testNextCatchUpRefreshDateChoosesEarliestRelevantBlock() {
        let task = makeTask(effort: 120, deadlineHoursFromAnchor: 48)
        let missed = ScheduledBlock(
            task: task,
            startTime: anchor.addingTimeInterval(-2 * 3600),
            durationMinutes: 60
        )
        let future = ScheduledBlock(
            task: task,
            startTime: anchor.addingTimeInterval(2 * 3600),
            durationMinutes: 60
        )
        let completed = ScheduledBlock(
            task: task,
            startTime: anchor.addingTimeInterval(-4 * 3600),
            durationMinutes: 60
        )
        completed.isComplete = true

        let overdueTask = LoomTask(
            title: "Overdue",
            context: .school,
            deadline: anchor.addingTimeInterval(-3600),
            effortMinutes: 60
        )
        context.insert(overdueTask)
        let overdueBlock = ScheduledBlock(
            task: overdueTask,
            startTime: anchor.addingTimeInterval(-3 * 3600),
            durationMinutes: 60
        )

        let blocks = [future, completed, overdueBlock, missed]
        XCTAssertEqual(
            SchedulerService.nextCatchUpRefreshDate(blocks: blocks, now: anchor),
            missed.endTime,
            "an elapsed active block should trigger immediate catch-up instead of being skipped"
        )

        missed.isComplete = true
        XCTAssertEqual(
            SchedulerService.nextCatchUpRefreshDate(blocks: blocks, now: anchor),
            future.endTime,
            "completion should re-arm the one-shot refresh for the next block"
        )

        task.isComplete = true
        XCTAssertNil(SchedulerService.nextCatchUpRefreshDate(blocks: blocks, now: anchor))
    }

    func testCatchUpFeedbackKeepsVisualAndSpokenCopyInSync() {
        let refreshed = CatchUpSummary(adjustedTasks: 1, replannedTasks: 1)
        XCTAssertEqual(
            refreshed.accessibilityAnnouncement,
            "Plan refreshed after missed work. Your next steps are up to date."
        )

        let warning = CatchUpSummary(
            adjustedTasks: 2,
            replannedTasks: 1,
            unschedulableTasks: 2
        )
        XCTAssertEqual(
            warning.warningMessage,
            "2 tasks no longer fit before their deadlines. Extend them or trim the estimates."
        )
        XCTAssertEqual(
            warning.accessibilityAnnouncement,
            warning.feedbackMessage + " " + (warning.warningMessage ?? "")
        )
    }

    func testAutomaticPlanRefreshWaitsForActiveWorkSession() {
        XCTAssertTrue(
            AutomaticPlanRefreshPolicy.canRewriteSchedule(
                activeWorkSession: nil
            )
        )

        let activeSession = WorkSessionControlState(
            sessionID: UUID(),
            startedAt: anchor
        )
        XCTAssertFalse(
            AutomaticPlanRefreshPolicy.canRewriteSchedule(
                activeWorkSession: activeSession
            ),
            "catch-up and busy-time conflict repair must both defer while a timer owns its block"
        )
    }

    func testDeferredBusyTimeConflictReplanStateResumesExactlyOnce() {
        var state = DeferredBusyTimeConflictReplanState()

        XCTAssertFalse(state.request(canRewriteSchedule: false))
        XCTAssertTrue(state.hasPendingRequest)
        XCTAssertFalse(
            state.resume(canRewriteSchedule: false),
            "a second active session must preserve the deferred repair"
        )
        XCTAssertTrue(state.hasPendingRequest)
        XCTAssertTrue(state.resume(canRewriteSchedule: true))
        XCTAssertFalse(state.hasPendingRequest)
        XCTAssertFalse(
            state.resume(canRewriteSchedule: true),
            "the same deferred repair must not run twice"
        )
    }

    func testImmediateBusyTimeConflictRequestClearsOlderDeferral() {
        var state = DeferredBusyTimeConflictReplanState()

        XCTAssertFalse(state.request(canRewriteSchedule: false))
        XCTAssertTrue(state.request(canRewriteSchedule: true))
        XCTAssertFalse(state.hasPendingRequest)
        XCTAssertFalse(state.resume(canRewriteSchedule: true))
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

    func testLinkedTimedSessionReplacesCompletedBlockInTimeSpent() throws {
        let task = makeTask(effort: 100, deadlineHoursFromAnchor: 48)
        let block = ScheduledBlock(task: task, startTime: anchor, durationMinutes: 40)
        block.isComplete = true
        let session = WorkSession(
            task: task,
            startedAt: anchor,
            durationSeconds: 20 * 60,
            scheduledBlockId: block.id
        )
        context.insert(block)
        context.insert(session)
        try context.save()

        XCTAssertEqual(task.workedBlockMinutes, 0)
        XCTAssertEqual(task.timeSpentMinutes, 20, "the linked reservation must not count twice")
    }

    func testUnlinkedCompletedBlockStillCountsInTimeSpent() throws {
        let task = makeTask(effort: 100, deadlineHoursFromAnchor: 48)
        let block = ScheduledBlock(task: task, startTime: anchor, durationMinutes: 40)
        block.isComplete = true
        let floatingSession = WorkSession(
            task: task,
            startedAt: anchor.addingTimeInterval(3600),
            durationSeconds: 20 * 60
        )
        context.insert(block)
        context.insert(floatingSession)
        try context.save()

        XCTAssertEqual(task.workedBlockMinutes, 40)
        XCTAssertEqual(task.timeSpentMinutes, 60)
    }

    // MARK: - Work session block selection

    func testWorkSessionBlockSelectorIgnoresCompletedOverlap() throws {
        let task = makeTask(effort: 120, deadlineHoursFromAnchor: 48)
        let completed = ScheduledBlock(
            task: task,
            startTime: anchor.addingTimeInterval(-30 * 60),
            durationMinutes: 60
        )
        completed.isComplete = true
        let incomplete = ScheduledBlock(
            task: task,
            startTime: anchor.addingTimeInterval(-15 * 60),
            durationMinutes: 60
        )

        let selected = try XCTUnwrap(
            WorkSessionBlockSelector.currentIncompleteBlock(
                in: [completed, incomplete],
                at: anchor
            )
        )

        XCTAssertEqual(selected.id, incomplete.id)
    }

    func testWorkSessionBlockSelectorDeterministicallyPrefersEarliestStart() throws {
        let task = makeTask(effort: 120, deadlineHoursFromAnchor: 48)
        let earlier = ScheduledBlock(
            task: task,
            startTime: anchor.addingTimeInterval(-20 * 60),
            durationMinutes: 60
        )
        let later = ScheduledBlock(
            task: task,
            startTime: anchor.addingTimeInterval(-10 * 60),
            durationMinutes: 60
        )

        let forward = try XCTUnwrap(
            WorkSessionBlockSelector.currentIncompleteBlock(
                in: [earlier, later],
                at: anchor
            )
        )
        let reversed = try XCTUnwrap(
            WorkSessionBlockSelector.currentIncompleteBlock(
                in: [later, earlier],
                at: anchor
            )
        )

        XCTAssertEqual(forward.id, earlier.id)
        XCTAssertEqual(reversed.id, earlier.id)
    }

    // MARK: - Shared work-session clock

    func testWorkSessionControlStateExcludesPausedWallTime() {
        let start = anchor
        var state = WorkSessionControlState(sessionID: UUID(), startedAt: start)

        XCTAssertEqual(state.elapsedWorkedSeconds(at: start.addingTimeInterval(10)), 10)

        state.setPaused(true, at: start.addingTimeInterval(10))
        XCTAssertTrue(state.isPaused)
        XCTAssertEqual(
            state.elapsedWorkedSeconds(at: start.addingTimeInterval(40)),
            10,
            "worked time must freeze while the Live Activity reports paused"
        )

        state.setPaused(false, at: start.addingTimeInterval(40))
        XCTAssertFalse(state.isPaused)
        XCTAssertEqual(state.accumulatedPausedSeconds, 30)
        XCTAssertEqual(state.elapsedWorkedSeconds(at: start.addingTimeInterval(55)), 25)
    }

    func testWorkSessionControlStatePauseTransitionsAreIdempotentAndCodable() throws {
        let start = anchor
        var state = WorkSessionControlState(sessionID: UUID(), startedAt: start)

        state.setPaused(true, at: start.addingTimeInterval(5))
        state.setPaused(true, at: start.addingTimeInterval(20))
        state.setPaused(false, at: start.addingTimeInterval(25))
        state.setPaused(false, at: start.addingTimeInterval(40))

        XCTAssertEqual(state.accumulatedPausedSeconds, 20)
        XCTAssertEqual(state.elapsedWorkedSeconds(at: start.addingTimeInterval(40)), 20)

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(WorkSessionControlState.self, from: data)
        XCTAssertEqual(decoded, state)
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

    func testAvailableMinutesRespectsDailyFocusRemainingAfterExistingWork() {
        let settings = makeSettings()
        settings.dailyFocusMinutes = 120

        let other = makeTask(effort: 60, deadlineHoursFromAnchor: 48)
        // This block ends exactly when the queried window begins. It does not
        // occupy the window, but it has already spent half today's focus cap.
        let earlierBlock = ScheduledBlock(
            task: other,
            startTime: anchor.addingTimeInterval(-60 * 60),
            durationMinutes: 60
        )
        context.insert(earlierBlock)

        let available = SchedulerService.availableMinutes(
            from: anchor,
            to: anchor.addingTimeInterval(5 * 3600),
            allBlocks: [earlierBlock],
            settings: settings
        )
        XCTAssertEqual(available, 60)
    }

    func testAvailableMinutesRoundsEachDayDownToValidBlockCapacity() {
        let settings = makeSettings()
        settings.wakeHour = 9
        settings.sleepHour = 9
        settings.sleepMinute = 55
        settings.minBlockMinutes = 30
        settings.maxBlockMinutes = 45
        settings.dailyFocusMinutes = 55

        let available = SchedulerService.availableMinutes(
            from: anchor,
            to: anchor.addingTimeInterval(55 * 60),
            allBlocks: [],
            settings: settings
        )
        XCTAssertEqual(available, 45, "the unusable 10-minute tail is not capacity")
    }

    func testFragmentedFiftyFiveMinuteGapsHaveNinetyMinutesOfCapacity() {
        let settings = makeSettings()
        settings.wakeHour = 9
        settings.sleepHour = 11
        settings.minBlockMinutes = 30
        settings.maxBlockMinutes = 45
        settings.dailyFocusMinutes = 0

        let occupyingTask = makeTask(effort: 10, deadlineHoursFromAnchor: 24)
        let hold = ScheduledBlock(
            task: occupyingTask,
            startTime: anchor.addingTimeInterval(55 * 60),
            durationMinutes: 10
        )
        context.insert(hold)

        let windowEnd = anchor.addingTimeInterval(2 * 60 * 60)
        let available = SchedulerService.availableMinutes(
            from: anchor,
            to: windowEnd,
            allBlocks: [hold],
            settings: settings
        )
        XCTAssertEqual(
            available,
            90,
            "each 55-minute gap can hold one 45-minute block; their 10-minute tails cannot pool"
        )

        let task = makeTask(effort: 110, deadlineHoursFromAnchor: 4)
        let result = SchedulerService.schedule(
            task: task,
            allBlocks: [hold],
            settings: settings,
            from: anchor
        )
        guard case .partialFit(let blocks, let unscheduledMinutes) = result else {
            return XCTFail("expected maximal partial fit, got \(result)")
        }
        XCTAssertEqual(blocks.map(\.durationMinutes), [45, 45])
        XCTAssertEqual(blocks.reduce(0) { $0 + $1.durationMinutes }, 90)
        XCTAssertEqual(unscheduledMinutes, 20)
    }

    func testOvernightCapacityChargesFocusToTheAfterMidnightDay() throws {
        let settings = makeSettings()
        settings.wakeHour = 22
        settings.sleepHour = 2
        settings.dailyFocusMinutes = 120
        settings.minBlockMinutes = 30
        settings.maxBlockMinutes = 90

        let day = calendar.startOfDay(for: anchor)
        let overnightStart = calendar.date(
            bySettingHour: 23,
            minute: 0,
            second: 0,
            of: day
        )!
        let nextDay = calendar.date(byAdding: .day, value: 1, to: day)!
        let windowEnd = calendar.date(
            bySettingHour: 1,
            minute: 0,
            second: 0,
            of: nextDay
        )!

        // This reservation begins exactly when the query ends, so it does not
        // occupy the 23:00-01:00 gap. It does consume all of the next date's
        // focus budget, leaving only the hour before midnight available.
        let other = makeTask(effort: 120, deadlineHoursFromAnchor: 72)
        let afterMidnightWork = ScheduledBlock(
            task: other,
            startTime: windowEnd,
            durationMinutes: 120
        )
        context.insert(afterMidnightWork)

        let available = SchedulerService.availableMinutes(
            from: overnightStart,
            to: windowEnd,
            allBlocks: [afterMidnightWork],
            settings: settings
        )
        XCTAssertEqual(available, 60)

        let task = LoomTask(
            title: "Overnight task",
            context: .school,
            deadline: windowEnd.addingTimeInterval(
                TimeInterval(settings.deadlineBufferMinutes * 60)
            ),
            effortMinutes: 120
        )
        context.insert(task)
        let pace = try XCTUnwrap(SchedulerService.pressureAndAvailableMinutes(
            for: task,
            allBlocks: [afterMidnightWork],
            settings: settings,
            now: overnightStart
        ))
        XCTAssertEqual(pace.availableMinutes, 60)
        XCTAssertEqual(pace.pressure, 2.0, accuracy: 0.01)
    }

    func testOvernightCapacityPreservesAContinuousMinimumBlockAcrossMidnight() throws {
        let settings = makeSettings()
        settings.wakeHour = 23
        settings.wakeMinute = 45
        settings.sleepHour = 0
        settings.sleepMinute = 15
        settings.dailyFocusMinutes = 30
        settings.minBlockMinutes = 30
        settings.maxBlockMinutes = 30

        let day = calendar.startOfDay(for: anchor)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: day)!
        let windowStart = calendar.date(
            bySettingHour: 23,
            minute: 45,
            second: 0,
            of: day
        )!
        let windowEnd = calendar.date(
            bySettingHour: 0,
            minute: 15,
            second: 0,
            of: nextDay
        )!

        // Fifteen focus minutes remain on each date. Neither side of midnight
        // is a valid block alone, but the real continuous gap holds one 30m
        // block whose focus cost is split 15 + 15.
        let other = makeTask(effort: 30, deadlineHoursFromAnchor: 72)
        let before = ScheduledBlock(
            task: other,
            startTime: windowStart.addingTimeInterval(-45 * 60),
            durationMinutes: 15
        )
        let after = ScheduledBlock(
            task: other,
            startTime: windowEnd.addingTimeInterval(15 * 60),
            durationMinutes: 15
        )
        context.insert(before)
        context.insert(after)

        let existing = [before, after]
        let available = SchedulerService.availableMinutes(
            from: windowStart,
            to: windowEnd,
            allBlocks: existing,
            settings: settings
        )
        XCTAssertEqual(available, 30)

        let task = LoomTask(
            title: "Midnight seam",
            context: .school,
            deadline: windowEnd.addingTimeInterval(
                TimeInterval(settings.deadlineBufferMinutes * 60)
            ),
            effortMinutes: 30
        )
        context.insert(task)

        let pace = try XCTUnwrap(SchedulerService.pressureAndAvailableMinutes(
            for: task,
            allBlocks: existing,
            settings: settings,
            now: windowStart
        ))
        XCTAssertEqual(pace.availableMinutes, 30)
        XCTAssertEqual(pace.pressure, 1.0, accuracy: 0.01)

        let result = SchedulerService.schedule(
            task: task,
            allBlocks: existing,
            settings: settings,
            from: windowStart
        )
        guard case .success(let blocks) = result else {
            return XCTFail("expected seam block to fit, got \(result)")
        }
        XCTAssertEqual(blocks.map(\.durationMinutes), [30])
        XCTAssertEqual(blocks.first?.startTime, windowStart)
    }

    func testMixedSameDayAndMidnightGapsMaximizePartialFitAndMatchCapacity() throws {
        let settings = makeSettings()
        settings.wakeHour = 22
        settings.sleepHour = 1
        settings.minBlockMinutes = 30
        settings.maxBlockMinutes = 45
        settings.dailyFocusMinutes = 0

        let day = calendar.startOfDay(for: anchor)
        let windowStart = calendar.date(
            bySettingHour: 22,
            minute: 0,
            second: 0,
            of: day
        )!
        let nextDay = calendar.date(byAdding: .day, value: 1, to: day)!
        let windowEnd = calendar.date(
            bySettingHour: 0,
            minute: 30,
            second: 0,
            of: nextDay
        )!

        // Free time is 22:00-22:45 (45m) plus 23:35-00:30 (55m).
        // The second gap crosses midnight, but both can still hold a 45m block.
        let occupyingTask = makeTask(effort: 50, deadlineHoursFromAnchor: 72)
        let hold = ScheduledBlock(
            task: occupyingTask,
            startTime: windowStart.addingTimeInterval(45 * 60),
            durationMinutes: 50
        )
        context.insert(hold)

        let available = SchedulerService.availableMinutes(
            from: windowStart,
            to: windowEnd,
            allBlocks: [hold],
            settings: settings
        )
        XCTAssertEqual(available, 90)

        let task = LoomTask(
            title: "Mixed midnight gaps",
            context: .school,
            deadline: windowEnd.addingTimeInterval(
                TimeInterval(settings.deadlineBufferMinutes * 60)
            ),
            effortMinutes: 100
        )
        context.insert(task)

        let result = SchedulerService.schedule(
            task: task,
            allBlocks: [hold],
            settings: settings,
            from: windowStart
        )
        guard case .partialFit(let blocks, let unscheduledMinutes) = result else {
            return XCTFail("expected a maximal partial fit, got \(result)")
        }
        XCTAssertEqual(blocks.map(\.durationMinutes), [45, 45])
        XCTAssertEqual(blocks.reduce(0) { $0 + $1.durationMinutes }, available)
        XCTAssertEqual(unscheduledMinutes, 10)
    }

    func testAvailableMinutesCreditsOnlyOwnBlockPortionInsideWindow() {
        let settings = makeSettings()
        settings.dailyFocusMinutes = 120

        let task = makeTask(effort: 120, deadlineHoursFromAnchor: 48)
        // Only 13:00-14:00 overlaps the query. The locked 14:00-15:00
        // portion remains real focus usage and leaves 60 minutes of capacity.
        let ownBlock = ScheduledBlock(
            task: task,
            startTime: anchor.addingTimeInterval(4 * 60 * 60),
            durationMinutes: 120
        )
        ownBlock.isLocked = true
        context.insert(ownBlock)

        let available = SchedulerService.availableMinutes(
            from: anchor,
            to: anchor.addingTimeInterval(5 * 60 * 60),
            excludingTaskId: task.id,
            allBlocks: [ownBlock],
            settings: settings
        )
        XCTAssertEqual(available, 60)
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

    func testPressureRespectsDailyFocusRemainingAfterExistingWork() throws {
        let settings = makeSettings()
        settings.dailyFocusMinutes = 120

        let other = makeTask(effort: 60, deadlineHoursFromAnchor: 48)
        let earlierBlock = ScheduledBlock(
            task: other,
            startTime: anchor.addingTimeInterval(-60 * 60),
            durationMinutes: 60
        )
        context.insert(earlierBlock)

        // The wall-clock window is 300 minutes, but only 60 minutes of today's
        // focus budget remain, so 60 minutes of work creates full pressure.
        let task = makeTask(effort: 60, deadlineHoursFromAnchor: 7)
        let pace = try XCTUnwrap(SchedulerService.pressureAndAvailableMinutes(
            for: task,
            allBlocks: [earlierBlock],
            settings: settings,
            now: anchor
        ))
        XCTAssertEqual(pace.availableMinutes, 60)
        XCTAssertEqual(pace.pressure, 1.0, accuracy: 0.01)
    }

    func testPressureRejectsSubMinimumDailyFocusRemainder() throws {
        let settings = makeSettings()
        settings.minBlockMinutes = 30
        settings.maxBlockMinutes = 90
        settings.dailyFocusMinutes = 45

        let other = makeTask(effort: 20, deadlineHoursFromAnchor: 48)
        let earlierBlock = ScheduledBlock(
            task: other,
            startTime: anchor.addingTimeInterval(-20 * 60),
            durationMinutes: 20
        )
        context.insert(earlierBlock)

        // Twenty-five focus minutes remain today, but this task's 60-minute
        // remainder requires blocks of at least 30 minutes.
        let task = makeTask(effort: 60, deadlineHoursFromAnchor: 7)
        let pace = try XCTUnwrap(SchedulerService.pressureAndAvailableMinutes(
            for: task,
            allBlocks: [earlierBlock],
            settings: settings,
            now: anchor
        ))
        XCTAssertEqual(pace.availableMinutes, 0)
        XCTAssertTrue(pace.pressure.isInfinite)
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

    func testWeaveExcludesCompletedBlockLinkedToTimedSession() throws {
        let task = makeTask(effort: 120, deadlineHoursFromAnchor: 48)
        let block = ScheduledBlock(task: task, startTime: anchor, durationMinutes: 45)
        block.isComplete = true
        let session = WorkSession(
            task: task,
            startedAt: anchor,
            durationSeconds: 20 * 60,
            scheduledBlockId: block.id
        )
        context.insert(block)
        context.insert(session)
        try context.save()

        let days = WeaveBuilder.days(
            sessions: [session],
            blocks: [block],
            daysBack: 1,
            now: anchor
        )

        let day = try XCTUnwrap(days.first)
        XCTAssertEqual(day.totalMinutes, 20)
        XCTAssertEqual(day.minutesByContext[.school], 20)
        XCTAssertEqual(day.sessionCount, 1)
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

    // MARK: - Plan coordinator

    @MainActor
    func testProgressReconciliationTrimsExcessFutureCoverage() throws {
        _ = makeSettings()
        let task = makeTask(effort: 180, deadlineHoursFromAnchor: 72)
        let first = ScheduledBlock(task: task, startTime: anchor, durationMinutes: 90)
        let second = ScheduledBlock(
            task: task,
            startTime: anchor.addingTimeInterval(2 * 3600),
            durationMinutes: 90
        )
        context.insert(first)
        context.insert(second)
        try context.save()

        task.manualProgressPercent = 50
        PlanCoordinator.reconcileTaskAfterProgress(
            task,
            context: context,
            interactive: false
        )
        try context.save()

        let future = try context.fetch(FetchDescriptor<ScheduledBlock>()).filter {
            $0.task?.id == task.id && !$0.isComplete && $0.endTime > Date()
        }
        XCTAssertEqual(task.remainingMinutes, 90)
        XCTAssertEqual(
            future.reduce(0) { $0 + $1.durationMinutes },
            task.remainingMinutes,
            "future reservations should shrink to the newly reported remainder"
        )
        XCTAssertFalse(future.contains { $0.id == first.id || $0.id == second.id })
    }

    @MainActor
    func testProgressReconciliationCountsLockedCoverageTowardRemainder() throws {
        _ = makeSettings()
        let task = makeTask(effort: 180, deadlineHoursFromAnchor: 72)
        let locked = ScheduledBlock(task: task, startTime: anchor, durationMinutes: 60)
        locked.isLocked = true
        let movable = ScheduledBlock(
            task: task,
            startTime: anchor.addingTimeInterval(2 * 3600),
            durationMinutes: 120
        )
        context.insert(locked)
        context.insert(movable)
        try context.save()

        task.manualProgressPercent = 50
        PlanCoordinator.reconcileTaskAfterProgress(
            task,
            context: context,
            interactive: false
        )
        try context.save()

        let future = try context.fetch(FetchDescriptor<ScheduledBlock>()).filter {
            $0.task?.id == task.id && !$0.isComplete && $0.endTime > Date()
        }
        XCTAssertEqual(task.remainingMinutes, 90)
        XCTAssertTrue(future.contains { $0.id == locked.id })
        XCTAssertFalse(future.contains { $0.id == movable.id })
        XCTAssertEqual(future.reduce(0) { $0 + $1.durationMinutes }, 90)
        XCTAssertEqual(
            future.filter { !$0.isLocked }.reduce(0) { $0 + $1.durationMinutes },
            30,
            "only effort not already covered by the locked block should be placed"
        )
    }

    func testRescheduleCountsOnlyFutureOverlapOfInProgressLockedBlock() throws {
        let settings = makeSettings()
        settings.startBufferMinutes = 0
        let task = makeTask(effort: 120, deadlineHoursFromAnchor: 8)
        let locked = ScheduledBlock(
            task: task,
            startTime: anchor.addingTimeInterval(-30 * 60),
            durationMinutes: 60
        )
        locked.isLocked = true
        let movable = ScheduledBlock(
            task: task,
            startTime: anchor.addingTimeInterval(2 * 3600),
            durationMinutes: 120
        )
        context.insert(locked)
        context.insert(movable)
        try context.save()

        let result = SchedulerService.reschedule(
            task: task,
            allBlocks: [locked, movable],
            settings: settings,
            from: anchor,
            context: context
        )
        try context.save()

        guard case .success = result else {
            return XCTFail("expected clipped locked coverage to leave a full fit, got \(result)")
        }
        let blocks = try context.fetch(FetchDescriptor<ScheduledBlock>()).filter {
            $0.task?.id == task.id && !$0.isComplete
        }
        let replacements = blocks.filter { !$0.isLocked }
        XCTAssertTrue(blocks.contains { $0.id == locked.id })
        XCTAssertFalse(blocks.contains { $0.id == movable.id })
        XCTAssertEqual(
            replacements.reduce(0) { $0 + $1.durationMinutes },
            90,
            "only the locked block's 30 future minutes may cover the 120-minute remainder"
        )
    }

    func testRescheduleDoesNotCountLockedBlockAfterBufferedDeadline() throws {
        let settings = makeSettings()
        settings.startBufferMinutes = 0
        let task = makeTask(effort: 60, deadlineHoursFromAnchor: 4)
        let windowEnd = task.deadline.addingTimeInterval(
            -Double(settings.deadlineBufferMinutes) * 60
        )
        let locked = ScheduledBlock(
            task: task,
            startTime: windowEnd.addingTimeInterval(60 * 60),
            durationMinutes: 60
        )
        locked.isLocked = true
        let movable = ScheduledBlock(
            task: task,
            startTime: anchor.addingTimeInterval(30 * 60),
            durationMinutes: 60
        )
        context.insert(locked)
        context.insert(movable)
        try context.save()

        let result = SchedulerService.reschedule(
            task: task,
            allBlocks: [locked, movable],
            settings: settings,
            from: anchor,
            context: context
        )
        try context.save()

        guard case .success = result else {
            return XCTFail("expected replacement work before the deadline, got \(result)")
        }
        let blocks = try context.fetch(FetchDescriptor<ScheduledBlock>()).filter {
            $0.task?.id == task.id && !$0.isComplete
        }
        let replacements = blocks.filter { !$0.isLocked }
        XCTAssertTrue(blocks.contains { $0.id == locked.id }, "locks remain in place")
        XCTAssertFalse(blocks.contains { $0.id == movable.id })
        XCTAssertEqual(replacements.reduce(0) { $0 + $1.durationMinutes }, 60)
        XCTAssertTrue(replacements.allSatisfy { $0.endTime <= windowEnd })
    }

    func testRebalanceCountsOnlyFutureOverlapOfInProgressLockedBlock() throws {
        let settings = makeSettings()
        settings.startBufferMinutes = 0
        let task = makeTask(effort: 120, deadlineHoursFromAnchor: 8)
        let locked = ScheduledBlock(
            task: task,
            startTime: anchor.addingTimeInterval(-30 * 60),
            durationMinutes: 60
        )
        locked.isLocked = true
        let movable = ScheduledBlock(
            task: task,
            startTime: anchor.addingTimeInterval(2 * 3600),
            durationMinutes: 120
        )
        context.insert(locked)
        context.insert(movable)
        try context.save()

        let summary = SchedulerService.rebalance(
            tasks: [task],
            allBlocks: [locked, movable],
            blockedTimes: [],
            settings: settings,
            now: anchor,
            context: context
        )
        try context.save()

        let blocks = try context.fetch(FetchDescriptor<ScheduledBlock>()).filter {
            $0.task?.id == task.id && !$0.isComplete
        }
        let replacements = blocks.filter { !$0.isLocked }
        XCTAssertEqual(summary.unschedulableTasks, 0)
        XCTAssertTrue(blocks.contains { $0.id == locked.id })
        XCTAssertFalse(blocks.contains { $0.id == movable.id })
        XCTAssertEqual(replacements.reduce(0) { $0 + $1.durationMinutes }, 90)
    }

    func testRebalanceDoesNotCountLockedBlockAfterBufferedDeadline() throws {
        let settings = makeSettings()
        settings.startBufferMinutes = 0
        let task = makeTask(effort: 60, deadlineHoursFromAnchor: 4)
        let windowEnd = task.deadline.addingTimeInterval(
            -Double(settings.deadlineBufferMinutes) * 60
        )
        let locked = ScheduledBlock(
            task: task,
            startTime: windowEnd.addingTimeInterval(60 * 60),
            durationMinutes: 60
        )
        locked.isLocked = true
        let movable = ScheduledBlock(
            task: task,
            startTime: anchor.addingTimeInterval(30 * 60),
            durationMinutes: 60
        )
        context.insert(locked)
        context.insert(movable)
        try context.save()

        let summary = SchedulerService.rebalance(
            tasks: [task],
            allBlocks: [locked, movable],
            blockedTimes: [],
            settings: settings,
            now: anchor,
            context: context
        )
        try context.save()

        let blocks = try context.fetch(FetchDescriptor<ScheduledBlock>()).filter {
            $0.task?.id == task.id && !$0.isComplete
        }
        let replacements = blocks.filter { !$0.isLocked }
        XCTAssertEqual(summary.unschedulableTasks, 0)
        XCTAssertTrue(blocks.contains { $0.id == locked.id }, "locks remain in place")
        XCTAssertFalse(blocks.contains { $0.id == movable.id })
        XCTAssertEqual(replacements.reduce(0) { $0 + $1.durationMinutes }, 60)
        XCTAssertTrue(replacements.allSatisfy { $0.endTime <= windowEnd })
    }

    @MainActor
    func testLinkedBlockAttendanceReconciliationRestoresUnchangedCoverage() throws {
        _ = makeSettings()
        let task = makeTask(effort: 120, deadlineHoursFromAnchor: 72)
        let attended = ScheduledBlock(task: task, startTime: anchor, durationMinutes: 60)
        let existingFuture = ScheduledBlock(
            task: task,
            startTime: anchor.addingTimeInterval(2 * 3600),
            durationMinutes: 60
        )
        let session = WorkSession(
            task: task,
            startedAt: anchor,
            durationSeconds: 25 * 60,
            scheduledBlockId: attended.id
        )
        context.insert(attended)
        context.insert(existingFuture)
        context.insert(session)
        try context.save()

        attended.isComplete = true
        let result = PlanCoordinator.reconcileTaskAfterProgress(
            task,
            context: context,
            interactive: false
        )
        try context.save()

        guard case .success = result else {
            return XCTFail("expected full replacement coverage, got \(result)")
        }

        let blocks = try context.fetch(FetchDescriptor<ScheduledBlock>()).filter {
            $0.task?.id == task.id
        }
        let futureCoverage = blocks
            .filter { !$0.isComplete && $0.endTime > Date() }
            .reduce(0) { $0 + $1.durationMinutes }
        XCTAssertEqual(task.remainingMinutes, 120, "attendance alone must not imply progress")
        XCTAssertEqual(futureCoverage, task.remainingMinutes)
        XCTAssertTrue(blocks.contains { $0.id == attended.id && $0.isComplete })
        XCTAssertFalse(blocks.contains { $0.id == existingFuture.id })
    }

    @MainActor
    func testUncheckingAttendedBlockReconciliationAvoidsDuplicateCoverage() throws {
        _ = makeSettings()
        let task = makeTask(effort: 120, deadlineHoursFromAnchor: 72)
        let attended = ScheduledBlock(task: task, startTime: anchor, durationMinutes: 60)
        let existingFuture = ScheduledBlock(
            task: task,
            startTime: anchor.addingTimeInterval(2 * 3600),
            durationMinutes: 60
        )
        context.insert(attended)
        context.insert(existingFuture)
        try context.save()

        attended.isComplete = true
        PlanCoordinator.reconcileTaskAfterProgress(
            task,
            context: context,
            interactive: false
        )
        try context.save()

        attended.isComplete = false
        PlanCoordinator.reconcileTaskAfterProgress(
            task,
            context: context,
            interactive: false
        )
        try context.save()

        let future = try context.fetch(FetchDescriptor<ScheduledBlock>()).filter {
            $0.task?.id == task.id && !$0.isComplete && $0.endTime > Date()
        }
        let futureCoverage = future.reduce(0) { $0 + $1.durationMinutes }

        XCTAssertEqual(task.remainingMinutes, 120, "attendance changes must not imply progress")
        XCTAssertEqual(
            futureCoverage,
            task.remainingMinutes,
            "undoing attendance must replace, not stack on, the reconciled coverage"
        )
        XCTAssertNotEqual(futureCoverage, task.remainingMinutes + attended.durationMinutes)
        XCTAssertFalse(future.contains { $0.id == attended.id })
    }

    @MainActor
    func testPlanningPreferenceRebuildCountsLockedCoverageTowardRemainder() throws {
        let settings = makeSettings()
        settings.minBlockMinutes = 15
        let task = makeTask(effort: 180, deadlineHoursFromAnchor: 72)
        task.manualProgressPercent = 50
        let locked = ScheduledBlock(task: task, startTime: anchor, durationMinutes: 60)
        locked.isLocked = true
        let movable = ScheduledBlock(
            task: task,
            startTime: anchor.addingTimeInterval(2 * 3600),
            durationMinutes: 120
        )
        context.insert(locked)
        context.insert(movable)
        try context.save()

        PlanCoordinator.rebuildAfterPlanningPreferencesChange(
            context: context,
            interactive: false
        )
        try context.save()

        let future = try context.fetch(FetchDescriptor<ScheduledBlock>()).filter {
            $0.task?.id == task.id && !$0.isComplete && $0.endTime > Date()
        }
        XCTAssertEqual(task.remainingMinutes, 90)
        XCTAssertTrue(future.contains { $0.id == locked.id })
        XCTAssertFalse(future.contains { $0.id == movable.id })
        XCTAssertEqual(future.reduce(0) { $0 + $1.durationMinutes }, 90)
        XCTAssertEqual(future.filter { !$0.isLocked }.reduce(0) { $0 + $1.durationMinutes }, 30)
    }

    @MainActor
    func testCompletionReleasesIncompleteLockedBlocks() throws {
        _ = makeSettings()
        let task = makeTask(effort: 60, deadlineHoursFromAnchor: 48)
        let locked = ScheduledBlock(task: task, startTime: anchor, durationMinutes: 60)
        locked.isLocked = true
        context.insert(locked)
        try context.save()

        PlanCoordinator.completeTask(task, context: context, interactive: false)

        let surviving = try context.fetch(FetchDescriptor<ScheduledBlock>()).filter {
            $0.task?.id == task.id && !$0.isComplete
        }
        XCTAssertTrue(task.isComplete)
        XCTAssertTrue(surviving.isEmpty, "explicit completion must release locked reservations")
    }

    @MainActor
    func testBusyTimeReconciliationMovesConflictingBlock() throws {
        _ = makeSettings()
        let task = makeTask(effort: 60, deadlineHoursFromAnchor: 48)
        let original = ScheduledBlock(task: task, startTime: anchor, durationMinutes: 60)
        let busy = BusyEvent(
            source: .appleCalendar,
            sourceId: "coordinator-conflict",
            title: "New meeting",
            startTime: original.startTime,
            endTime: original.endTime
        )
        context.insert(original)
        context.insert(busy)
        try context.save()

        let replanned = PlanCoordinator.replanBusyTimeConflicts(
            context: context,
            interactive: false
        )
        try context.save()

        let replacements = try context.fetch(FetchDescriptor<ScheduledBlock>()).filter {
            $0.task?.id == task.id && !$0.isComplete
        }
        XCTAssertEqual(replanned, 1)
        XCTAssertFalse(replacements.isEmpty)
        XCTAssertFalse(replacements.contains { $0.id == original.id })
        XCTAssertTrue(replacements.allSatisfy {
            $0.startTime >= busy.endTime || $0.endTime <= busy.startTime
        })
    }

    // MARK: - Data export

    func testDataExportRoundTrips() throws {
        let task = makeTask(effort: 90, deadlineHoursFromAnchor: 48)
        task.firstStep = "Open the doc"
        let block = ScheduledBlock(task: task, startTime: anchor, durationMinutes: 45)
        context.insert(block)
        let session = WorkSession(
            task: task,
            startedAt: anchor,
            durationSeconds: 1200,
            scheduledBlockId: block.id
        )
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

        XCTAssertEqual(export.version, 2)
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
        XCTAssertEqual(export.workSessions.first?.scheduledBlockId, block.id)
        XCTAssertEqual(export.blockedTimes.first?.weekdays, [2, 4])

        // Export v1 had the same envelope but no session-to-block link. The
        // new optional field must keep those existing backups decodable.
        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        legacyObject["version"] = 1
        var legacySessions = try XCTUnwrap(
            legacyObject["workSessions"] as? [[String: Any]]
        )
        legacySessions[0].removeValue(forKey: "scheduledBlockId")
        legacyObject["workSessions"] = legacySessions
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let legacyExport = try decoder.decode(DataExporter.Export.self, from: legacyData)

        XCTAssertEqual(legacyExport.version, 1)
        XCTAssertNil(legacyExport.workSessions.first?.scheduledBlockId)
    }
}
