import Foundation
import SwiftData

/// The app-level boundary for mutating an existing plan. Views report the
/// user's intent here; scheduling, calendar mirrors, widgets, and nudges stay
/// in sync behind one small surface.
@MainActor
enum PlanCoordinator {
    /// Publish the current plan to every downstream consumer.
    static func publishChange(context: ModelContext, interactive: Bool = true) {
        CalendarExportService.syncIfEnabled(context: context)
        GoogleCalendarService.exportIfEnabled(context: context)
        scheduleDidChange(context: context, interactive: interactive)
    }

    /// Replace one task's movable future blocks, then publish the resulting
    /// plan. Callers keep the scheduling result so their existing warning or
    /// confirmation UI can stay specific to the user's action.
    @discardableResult
    static func rescheduleTask(
        _ task: LoomTask,
        context: ModelContext,
        from startDate: Date? = nil,
        interactive: Bool = true
    ) -> ScheduleResult {
        let settings = UserSettings.fetchOrCreate(in: context)
        let allBlocks = (try? context.fetch(FetchDescriptor<ScheduledBlock>())) ?? []
        let blockedTimes = (try? context.fetch(FetchDescriptor<BlockedTime>())) ?? []
        let busyEvents = (try? context.fetch(FetchDescriptor<BusyEvent>())) ?? []

        let result = SchedulerService.reschedule(
            task: task,
            allBlocks: allBlocks,
            blockedTimes: blockedTimes,
            busyEvents: busyEvents,
            settings: settings,
            from: startDate,
            context: context
        )
        publishChange(context: context, interactive: interactive)
        return result
    }

    /// Progress changes remaining effort, so replace the task's movable future
    /// blocks with coverage for that smaller remainder.
    @discardableResult
    static func reconcileTaskAfterProgress(
        _ task: LoomTask,
        context: ModelContext,
        interactive: Bool = true
    ) -> ScheduleResult {
        rescheduleTask(task, context: context, interactive: interactive)
    }

    /// Complete a task and release every incomplete reservation. A lock keeps
    /// a block fixed while planning; it must not outlive explicit completion.
    static func completeTask(
        _ task: LoomTask,
        context: ModelContext,
        interactive: Bool = true
    ) {
        task.isComplete = true
        task.completedAt = Date()
        for block in task.scheduledBlocks where !block.isComplete {
            context.delete(block)
        }

        // Persist releases immediately. This prevents deleted child blocks
        // from resurfacing later as orphaned schedule rows.
        try? context.save()
        publishChange(context: context, interactive: interactive)
    }

    /// Planning preferences invalidate every active task's movable blocks.
    @discardableResult
    static func rebuildAfterPlanningPreferencesChange(
        context: ModelContext,
        interactive: Bool = true
    ) -> CatchUpSummary {
        rebuildPlan(context: context, interactive: interactive)
    }

    /// Rebuild every active task by deadline and publish the resulting plan.
    /// This is also the application boundary for explicit "make room" actions.
    @discardableResult
    static func rebuildPlan(
        context: ModelContext,
        interactive: Bool = true
    ) -> CatchUpSummary {
        let settings = UserSettings.fetchOrCreate(in: context)
        let tasks = (try? context.fetch(FetchDescriptor<LoomTask>())) ?? []
        let allBlocks = (try? context.fetch(FetchDescriptor<ScheduledBlock>())) ?? []
        let blockedTimes = (try? context.fetch(FetchDescriptor<BlockedTime>())) ?? []
        let busyEvents = (try? context.fetch(FetchDescriptor<BusyEvent>())) ?? []

        let summary = SchedulerService.rebalance(
            tasks: tasks,
            allBlocks: allBlocks,
            blockedTimes: blockedTimes,
            busyEvents: busyEvents,
            settings: settings,
            context: context
        )
        publishChange(context: context, interactive: interactive)
        return summary
    }

    /// Move upcoming work that now overlaps recurring or imported busy time.
    @discardableResult
    static func replanBusyTimeConflicts(
        context: ModelContext,
        interactive: Bool = true
    ) -> Int {
        let settings = UserSettings.fetchOrCreate(in: context)
        let tasks = (try? context.fetch(FetchDescriptor<LoomTask>())) ?? []
        let allBlocks = (try? context.fetch(FetchDescriptor<ScheduledBlock>())) ?? []
        let blockedTimes = (try? context.fetch(FetchDescriptor<BlockedTime>())) ?? []
        let busyEvents = (try? context.fetch(FetchDescriptor<BusyEvent>())) ?? []

        let replanned = SchedulerService.replanConflicts(
            tasks: tasks,
            allBlocks: allBlocks,
            blockedTimes: blockedTimes,
            busyEvents: busyEvents,
            settings: settings,
            context: context
        )
        publishChange(context: context, interactive: interactive)
        return replanned
    }
}
