import SwiftUI
import SwiftData

struct TaskListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \LoomTask.deadline) private var tasks: [LoomTask]
    @Query(sort: \Reminder.dueDate) private var reminders: [Reminder]
    @Binding var replanSummary: CatchUpSummary
    @State private var showingCapture = false
    @State private var expandedContexts: Set<TaskContext> = Set(TaskContext.allCases)
    @State private var workSessionTask: LoomTask?
    @State private var celebrationTask: LoomTask?
    @State private var editingTask: LoomTask?
    @State private var showCompleted = false

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    VStack(spacing: 0) {
                        headerSection
                        statsBar
                        replanBanner
                        remindersSection
                        taskSections
                        completedSection
                    }
                    .padding(.bottom, 100)
                }
                .background(Color.loomBackground)

                captureButton
            }
            .sheet(isPresented: $showingCapture) {
                CaptureSheetView()
            }
            .sheet(item: $workSessionTask) { task in
                WorkSessionView(task: task) { completed in
                    workSessionTask = nil
                    if completed {
                        // Let the sheet finish dismissing before presenting the
                        // celebration cover, or SwiftUI drops the presentation.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            completeTask(task)
                        }
                    }
                }
            }
            .fullScreenCover(item: $celebrationTask) { task in
                TaskCompletionView(task: task) {
                    celebrationTask = nil
                } onUndo: {
                    restoreTask(task, context: modelContext)
                    celebrationTask = nil
                }
            }
            .sheet(item: $editingTask) { task in
                TaskEditView(task: task)
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(greeting)
                .font(AppFont.caption(12))
                .foregroundStyle(Color.loomSubtle)
            Text("Your Tasks")
                .font(AppFont.title(26))
                .foregroundStyle(Color.loomText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        if hour < 12 { return "Good morning" }
        else if hour < 17 { return "Good afternoon" }
        else { return "Good evening" }
    }

    // MARK: - Stats Bar

    private var statsBar: some View {
        let incomplete = tasks.filter { !$0.isComplete }
        let unscheduled = incomplete.filter { !$0.isFullyScheduled }
        let todayBlocks = todayBlockCount

        return HStack(spacing: 10) {
            StatPill(value: "\(incomplete.count)", label: "active", color: .loomText)
            StatPill(value: "\(todayBlocks)", label: "today", color: .schoolColor)
            if !unscheduled.isEmpty {
                StatPill(value: "\(unscheduled.count)", label: "unblocked", color: .loomRed)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }

    private var todayBlockCount: Int {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else { return 0 }

        return tasks.flatMap { $0.scheduledBlocks }
            .filter { !$0.isComplete && $0.startTime >= today && $0.startTime < tomorrow }
            .count
    }

    // MARK: - Replan banner

    @ViewBuilder
    private var replanBanner: some View {
        if replanSummary.replannedTasks > 0 {
            VStack(spacing: 10) {
                InfoBanner(
                    icon: "arrow.triangle.2.circlepath",
                    text: replanSummary.replannedTasks == 1
                        ? "Replanned 1 task with missed blocks"
                        : "Replanned \(replanSummary.replannedTasks) tasks with missed blocks"
                )
                if replanSummary.unschedulableTasks > 0 {
                    InfoBanner(
                        icon: "exclamationmark.triangle.fill",
                        text: replanSummary.unschedulableTasks == 1
                            ? "1 task no longer fits before its deadline. Extend it or trim the estimate"
                            : "\(replanSummary.unschedulableTasks) tasks no longer fit before their deadlines. Extend them or trim the estimates",
                        tint: .loomRed
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
            .onTapGesture {
                withAnimation { replanSummary = CatchUpSummary() }
            }
        }
    }

    // MARK: - Reminders

    @ViewBuilder
    private var remindersSection: some View {
        let pending = reminders.filter { !$0.isComplete }
        if !pending.isEmpty {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "bell.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.brand500)
                    Text("Reminders")
                        .font(AppFont.heading(15))
                        .foregroundStyle(Color.loomText)
                    Text("\(pending.count)")
                        .font(AppFont.caption(12))
                        .foregroundStyle(Color.loomFaint)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)

                VStack(spacing: 10) {
                    ForEach(pending) { reminder in
                        ReminderRow(reminder: reminder) {
                            completeReminder(reminder)
                        } onDelete: {
                            deleteReminder(reminder)
                        }
                        .padding(.horizontal, 20)
                    }
                }
                .padding(.bottom, 16)
            }
        }
    }

    private func completeReminder(_ reminder: Reminder) {
        withAnimation {
            reminder.isComplete = true
        }
        NotificationService.cancel(reminder)
    }

    private func deleteReminder(_ reminder: Reminder) {
        NotificationService.cancel(reminder)
        withAnimation {
            modelContext.delete(reminder)
        }
    }

    // MARK: - Task Sections (grouped by context)

    @ViewBuilder
    private var taskSections: some View {
        let incomplete = tasks.filter { !$0.isComplete }
        let sorted = incomplete.sorted { lhs, rhs in
            let lhsNext = lhs.nextBlock?.startTime ?? Date.distantFuture
            let rhsNext = rhs.nextBlock?.startTime ?? Date.distantFuture
            return lhsNext < rhsNext
        }

        if incomplete.isEmpty {
            EmptyStateView(
                icon: "tray",
                title: "All clear",
                subtitle: "Tap + to add your next task.",
                actionLabel: "Add a task",
                action: { showingCapture = true }
            )
            .padding(.top, 40)
        } else {
            ForEach(TaskContext.allCases) { context in
                let contextTasks = sorted.filter { $0.context == context }
                if !contextTasks.isEmpty {
                    contextSection(context: context, tasks: contextTasks)
                }
            }
        }
    }

    private func contextSection(context: TaskContext, tasks: [LoomTask]) -> some View {
        let isExpanded = expandedContexts.contains(context)

        return VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    if isExpanded {
                        expandedContexts.remove(context)
                    } else {
                        expandedContexts.insert(context)
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: context.icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(context.color)
                    Text(context.rawValue)
                        .font(AppFont.heading(15))
                        .foregroundStyle(Color.loomText)
                    Text("\(tasks.count)")
                        .font(AppFont.caption(12))
                        .foregroundStyle(Color.loomFaint)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.loomFaint)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(spacing: 10) {
                    ForEach(tasks) { task in
                        TaskRowView(
                            task: task,
                            onStartSession: { workSessionTask = task },
                            onComplete: { completeTask(task) },
                            onEdit: { editingTask = task }
                        )
                        .padding(.horizontal, 20)
                    }
                }
                .padding(.bottom, 16)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: - Completed section

    @ViewBuilder
    private var completedSection: some View {
        let completed = tasks.filter(\.isComplete)
        if !completed.isEmpty {
            VStack(spacing: 0) {
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        showCompleted.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.personalColor)
                        Text("Completed")
                            .font(AppFont.heading(15))
                            .foregroundStyle(Color.loomText)
                        Text("\(completed.count)")
                            .font(AppFont.caption(12))
                            .foregroundStyle(Color.loomFaint)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.loomFaint)
                            .rotationEffect(.degrees(showCompleted ? 90 : 0))
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.plain)

                if showCompleted {
                    VStack(spacing: 10) {
                        ForEach(completed.sorted { $0.deadline > $1.deadline }) { task in
                            CompletedTaskRow(task: task) {
                                withAnimation {
                                    restoreTask(task, context: modelContext)
                                }
                            } onDelete: {
                                withAnimation {
                                    modelContext.delete(task)
                                }
                                SharedStore.reloadWidgets()
                            }
                            .padding(.horizontal, 20)
                        }
                    }
                    .padding(.bottom, 16)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    // MARK: - Completion

    private func completeTask(_ task: LoomTask) {
        withAnimation {
            task.isComplete = true
            // Reserved future time is released back to the schedule.
            for block in task.scheduledBlocks where !block.isComplete && !block.isLocked {
                modelContext.delete(block)
            }
        }
        celebrationTask = task
        CalendarExportService.syncIfEnabled(context: modelContext)
        SharedStore.reloadWidgets()
    }

    // MARK: - Capture FAB

    private var captureButton: some View {
        Button {
            showingCapture = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(Color.brand500, in: Circle())
                .shadow(color: Color.brand500.opacity(0.33), radius: 10, y: 10)
        }
        .padding(.trailing, 20)
        .padding(.bottom, 24)
    }
}

// MARK: - Stat Pill

private struct StatPill: View {
    let value: String
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Text(value)
                .font(AppFont.heading(14))
                .foregroundStyle(color)
            Text(label)
                .font(AppFont.body(11))
                .foregroundStyle(Color.loomSubtle)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.loomSurface2, in: Capsule())
    }
}


// MARK: - Reminder Row

private struct ReminderRow: View {
    let reminder: Reminder
    var onComplete: () -> Void
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "bell.fill")
                .font(.system(size: 13))
                .foregroundStyle(isOverdue ? Color.loomRed : Color.brand500)

            VStack(alignment: .leading, spacing: 2) {
                Text(reminder.title)
                    .font(AppFont.bodySemibold(15))
                    .foregroundStyle(Color.loomText)
                    .lineLimit(1)
                Text(dueLabel)
                    .font(AppFont.caption(11))
                    .foregroundStyle(isOverdue ? Color.loomRed : Color.loomSubtle)
            }

            Spacer()

            Button(action: onComplete) {
                Image(systemName: "circle")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(Color.loomFaint)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.loomSurface)
        .clipShape(RoundedRectangle(cornerRadius: LoomRadius.card, style: .continuous))
        .contextMenu {
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var isOverdue: Bool {
        reminder.dueDate < Date()
    }

    private var dueLabel: String {
        let calendar = Calendar.current
        let time = TimeFormatter.clock.string(from: reminder.dueDate)
        if calendar.isDateInToday(reminder.dueDate) {
            return time
        } else if calendar.isDateInTomorrow(reminder.dueDate) {
            return "Tomorrow \(time)"
        } else if calendar.isDateInYesterday(reminder.dueDate) {
            return "Yesterday \(time)"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return "\(formatter.string(from: reminder.dueDate)), \(time)"
    }
}

// MARK: - Completed Task Row

private struct CompletedTaskRow: View {
    let task: LoomTask
    var onRestore: () -> Void
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(Color.personalColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(AppFont.bodySemibold(15))
                    .strikethrough()
                    .foregroundStyle(Color.loomSubtle)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(task.context.rawValue)
                        .font(AppFont.caption(11))
                        .foregroundStyle(task.context.color)
                    if task.timeSpentMinutes > 0 {
                        Text("· \(CountdownFormatter.effortString(minutes: task.timeSpentMinutes)) worked")
                            .font(AppFont.caption(11))
                            .foregroundStyle(Color.loomFaint)
                    }
                }
            }

            Spacer()

            Button(action: onRestore) {
                Image(systemName: "arrow.uturn.backward.circle")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(Color.loomSubtle)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.loomSurface.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: LoomRadius.card, style: .continuous))
        .contextMenu {
            Button(action: onRestore) {
                Label("Restore", systemImage: "arrow.uturn.backward")
            }
            Button(role: .destructive, action: onDelete) {
                Label("Delete Permanently", systemImage: "trash")
            }
        }
    }
}

// MARK: - Restore

/// Bring a completed task back: un-complete it and put its remaining effort
/// back on the schedule.
@MainActor
func restoreTask(_ task: LoomTask, context: ModelContext) {
    task.isComplete = false
    // A task completed from a 100% progress report has nothing left to
    // schedule; nudge it back so the schedule reopens and progress stays
    // adjustable.
    if task.manualProgressPercent >= 100 {
        task.manualProgressPercent = 90
    }

    let settings = UserSettings.fetchOrCreate(in: context)
    let allBlocks = (try? context.fetch(FetchDescriptor<ScheduledBlock>())) ?? []
    let blockedTimes = (try? context.fetch(FetchDescriptor<BlockedTime>())) ?? []
    let busyEvents = (try? context.fetch(FetchDescriptor<BusyEvent>())) ?? []

    SchedulerService.reschedule(
        task: task,
        allBlocks: allBlocks,
        blockedTimes: blockedTimes,
        busyEvents: busyEvents,
        settings: settings,
        context: context
    )
    CalendarExportService.syncIfEnabled(context: context)
    SharedStore.reloadWidgets()
}
