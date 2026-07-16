import SwiftUI
import SwiftData

/// How far to push the current/next block when the honest answer to
/// "starting now?" is no.
enum BlockPushChoice {
    case thirtyMinutes
    case oneHour
    case tomorrow
}

struct TaskListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \LoomTask.deadline) private var tasks: [LoomTask]
    @Query(sort: \Reminder.dueDate) private var reminders: [Reminder]
    @Binding var replanSummary: CatchUpSummary
    @Binding var sessionRequestTaskId: UUID?
    @State private var showingCapture = false
    @State private var expandedContexts: Set<TaskContext> = Set(TaskContext.allCases)
    @State private var workSessionTask: LoomTask?
    @State private var celebrationTask: LoomTask?
    @State private var editingTask: LoomTask?
    @State private var triageEditTask: LoomTask?
    @State private var showCompleted = false
    @State private var pushNote: String?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    VStack(spacing: 0) {
                        headerSection
                        heroSection
                        upNextThreadSection
                        replanBanner
                        pushBanner
                        statsBar
                        overdueTriageSection
                        remindersSection
                        taskSections
                        completedSection
                    }
                    .padding(.bottom, 110)
                    .frame(maxWidth: LoomLayout.readableContentMaxWidth)
                    .frame(maxWidth: .infinity)
                }
                .hearthScreen()
            }
            .sheet(isPresented: $showingCapture) {
                CaptureSheetView()
            }
            .fullScreenCover(item: $workSessionTask) { task in
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
            .sheet(item: $triageEditTask) { task in
                TaskEditView(task: task, emphasizeDeadline: true)
            }
            .onAppear {
                consumeSessionRequest()
            }
            .onChange(of: sessionRequestTaskId) { _, _ in
                consumeSessionRequest()
            }
        }
    }

    private func consumeSessionRequest() {
        guard let requestedTaskID = sessionRequestTaskId else { return }
        sessionRequestTaskId = nil

        let taskID: UUID
        if let journalTaskID = WorkSessionControlStore.load()?.taskID,
           journalTaskID != requestedTaskID,
           tasks.contains(where: { $0.id == journalTaskID && !$0.isComplete }) {
            // Loom has one active timer. Route back to its live task so a new
            // request cannot strand the recovery journal behind another task.
            taskID = journalTaskID
        } else {
            taskID = requestedTaskID
        }
        if let task = tasks.first(where: { $0.id == taskID && !$0.isComplete }) {
            workSessionTask = task
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(greeting)
                    .font(AppFont.caption(13))
                    .foregroundStyle(Color.brand300)
                HearthTitle(text: "Your Tasks", size: 32)
            }
            Spacer()
            // The flame pill counts what's alive on the loom right now.
            let activeCount = tasks.filter { !$0.isComplete }.count
            if activeCount > 0 {
                ActiveCountPill(count: activeCount)
            }
        }
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

    // MARK: - Right Now hero

    /// The one-glance answer to "what should I be doing this minute?" — the
    /// running block if there is one, else the next upcoming block, with a
    /// single big Start button. Opening the app should never require a decision.
    private var heroSection: some View {
        let candidates = currentAndUpcomingBlocks(at: Date())

        // One-second cadence: the hero ring carries a live mm:ss countdown.
        return TimelineView(.periodic(from: .now, by: 1)) { timeline in
            if let block = candidates.first(where: { $0.endTime > timeline.date }),
               let task = block.task {
                RightNowCard(
                    task: task,
                    block: block,
                    now: timeline.date,
                    onStart: { workSessionTask = task },
                    onPush: { choice in push(task: task, choice: choice) }
                )
                .padding(.horizontal, 20)
                .padding(.bottom, 4)
            }
        }
    }

    // MARK: - Up next (the glowing thread)

    /// The thread of light connecting "now" to what comes after: the next few
    /// scheduled blocks beyond the hero, each row's context dot breaking
    /// through the thread.
    @ViewBuilder
    private var upNextThreadSection: some View {
        let now = Date()
        let heroBlock = currentOrNextBlock(at: now)
        let upcoming = tasks
            .filter { !$0.isComplete }
            .flatMap(\.scheduledBlocks)
            .filter { !$0.isComplete && $0.endTime > now && $0.id != heroBlock?.id }
            .sorted { $0.startTime < $1.startTime }
            .prefix(3)

        if !upcoming.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("UP NEXT")
                    .font(AppFont.caption(11))
                    .foregroundStyle(Color.loomSubtle)
                    .kerning(1.2)
                    .padding(.leading, 34)
                    .padding(.bottom, 10)

                VStack(spacing: 10) {
                    ForEach(Array(upcoming)) { block in
                        if let task = block.task {
                            UpNextThreadRow(task: task, block: block) {
                                workSessionTask = task
                            } onEdit: {
                                editingTask = task
                            }
                        }
                    }
                }
                .padding(.leading, 20)
            }
            // Size the light from the whole section, not a fixed estimate of
            // the header's height. It therefore stays continuous with larger
            // text, split-view iPad widths, and taller wrapped rows.
            .background(alignment: .topLeading) {
                GeometryReader { geometry in
                    LinearGradient(
                        colors: [Color.brand300.opacity(0.75), Color.brand300.opacity(0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(width: 2, height: geometry.size.height + 18)
                    // The hero contributes 4pt bottom spacing and this
                    // section contributes 14pt top spacing. Reaching through
                    // both makes the two strokes overlap instead of merely
                    // appearing close at one text size.
                    .offset(x: 6, y: -18)
                    .hearthGlow(.brand500, radius: 5, opacity: 0.5)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 16)
        }
    }

    /// Transient confirmation after a block push — tap to dismiss.
    @ViewBuilder
    private var pushBanner: some View {
        if let note = pushNote {
            InfoBanner(icon: "arrow.uturn.forward", text: note)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
                .onTapGesture {
                    withAnimation { pushNote = nil }
                }
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Dismisses this message")
        }
    }

    /// "Can't right now" — move the task's plan without shame or ceremony.
    /// The whole task replans from the chosen start, so the deadline math
    /// stays honest instead of one orphaned block landing somewhere random.
    private func push(task: LoomTask, choice: BlockPushChoice) {
        let settings = UserSettings.fetchOrCreate(in: modelContext)
        let calendar = Calendar.current

        let start: Date
        switch choice {
        case .thirtyMinutes:
            start = Date().addingTimeInterval(30 * 60)
        case .oneHour:
            start = Date().addingTimeInterval(3600)
        case .tomorrow:
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))
            start = tomorrow.flatMap {
                calendar.date(
                    bySettingHour: settings.wakeHour,
                    minute: settings.wakeMinute,
                    second: 0, of: $0
                )
            } ?? Date().addingTimeInterval(24 * 3600)
        }

        let result = PlanCoordinator.rescheduleTask(
            task,
            context: modelContext,
            from: start
        )

        withAnimation {
            switch result {
            case .success(let blocks):
                if let next = blocks.min(by: { $0.startTime < $1.startTime }) {
                    pushNote = "Pushed. Next block \(relativeTime(next.startTime))."
                } else {
                    pushNote = "Pushed — nothing left to schedule."
                }
            case .partialFit:
                pushNote = "Pushed, but not everything fits before the deadline now. Consider extending it."
            case .noSlots:
                pushNote = "Pushed, but no room remains before the deadline — extend it or trim the estimate."
            }
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = TimeFormatter.clock.string(from: date)
        if calendar.isDateInToday(date) { return "today at \(time)" }
        if calendar.isDateInTomorrow(date) { return "tomorrow at \(time)" }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        return "\(formatter.string(from: date)) at \(time)"
    }

    private func currentOrNextBlock(at now: Date) -> ScheduledBlock? {
        tasks
            .filter { !$0.isComplete }
            .flatMap(\.scheduledBlocks)
            .filter { !$0.isComplete && $0.endTime > now }
            .min { $0.startTime < $1.startTime }
    }

    private func currentAndUpcomingBlocks(at now: Date) -> [ScheduledBlock] {
        tasks
            .filter { !$0.isComplete }
            .flatMap(\.scheduledBlocks)
            .filter { !$0.isComplete && $0.endTime > now }
            .sorted { $0.startTime < $1.startTime }
    }

    // MARK: - Overdue triage

    /// Tasks whose deadline slipped by. Left alone they'd sit in the list
    /// reading "Past due" forever — a guilt pile. Force one of three kind
    /// exits instead: reschedule, mark done, or deliberately drop it.
    @ViewBuilder
    private var overdueTriageSection: some View {
        let overdue = overdueTasks
        if !overdue.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.loomRed)
                        .accessibilityHidden(true)
                    Text("Needs a decision")
                        .font(AppFont.heading(15))
                        .foregroundStyle(Color.loomText)
                    Text("\(overdue.count)")
                        .font(AppFont.caption(12))
                        .foregroundStyle(Color.loomFaint)
                    Spacer()
                }
                .accessibilityElement(children: .combine)

                Text("These slipped past their deadline. It happens — pick a path for each and move on.")
                    .font(AppFont.body(12))
                    .foregroundStyle(Color.loomSubtle)

                ForEach(overdue) { task in
                    OverdueTriageRow(
                        task: task,
                        onNewDeadline: { triageEditTask = task },
                        onComplete: { completeTask(task) },
                        onLetGo: { letGo(task) }
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
    }

    private var overdueTasks: [LoomTask] {
        tasks
            .filter { !$0.isComplete && $0.deadline <= Date() }
            .sorted { $0.deadline < $1.deadline }
    }

    /// Deliberately dropping a task is a decision, not a failure.
    private func letGo(_ task: LoomTask) {
        withAnimation {
            deleteTask(task, context: modelContext)
        }
        PlanCoordinator.publishChange(context: modelContext)
    }

    // MARK: - Stats Bar

    private var statsBar: some View {
        let incomplete = tasks.filter { !$0.isComplete }
        let unscheduled = incomplete.filter { !$0.isFullyScheduled }
        let todayBlocks = todayBlockCount

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                StatPill(value: "\(incomplete.count)", label: "active", color: .loomText)
                StatPill(value: "\(todayBlocks)", label: "today", color: .schoolColor)
                if !unscheduled.isEmpty {
                    StatPill(value: "\(unscheduled.count)", label: "unblocked", color: .loomRed)
                }
                Spacer()
            }
            paceSummary
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }

    /// One honest sentence about the most-pressured task — the early warning
    /// that fires days before anything turns red.
    @ViewBuilder
    private var paceSummary: some View {
        if let (taskId, entry) = PaceCache.worst(context: modelContext),
           entry.pressure >= 0.5,
           let task = tasks.first(where: { $0.id == taskId && !$0.isComplete }) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "gauge.with.needle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(entry.level == .critical ? Color.loomRed : Color.workColor)
                    .padding(.top, 1)
                Text(paceLine(task: task, entry: entry))
                    .font(AppFont.body(12))
                    .foregroundStyle(Color.loomSubtle)
            }
        }
    }

    private func paceLine(task: LoomTask, entry: PaceCache.Entry) -> String {
        guard !entry.pressure.isInfinite, entry.availableMinutes > 0 else {
            return "\(task.title) no longer fits before its deadline — extend it or trim the estimate."
        }
        let need = CountdownFormatter.effortString(minutes: entry.remainingMinutes)
        let free = CountdownFormatter.effortString(minutes: entry.availableMinutes)
        if entry.level == .critical {
            return "\(task.title) needs \(need) of the \(free) you have free — start today."
        }
        return "\(task.title) needs \(need) of the \(free) free before its deadline."
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
        if replanSummary.adjustedTasks > 0 {
            VStack(spacing: 10) {
                InfoBanner(
                    icon: "arrow.triangle.2.circlepath",
                    text: replanSummary.feedbackMessage
                )
                if let warningMessage = replanSummary.warningMessage {
                    InfoBanner(
                        icon: "exclamationmark.triangle.fill",
                        text: warningMessage,
                        tint: .loomRed
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
            .onTapGesture {
                withAnimation { replanSummary = CatchUpSummary() }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(replanSummary.accessibilityAnnouncement)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Dismisses this message")
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
                        .accessibilityHidden(true)
                    Text("Reminders")
                        .font(AppFont.heading(15))
                        .foregroundStyle(Color.loomText)
                    Text("\(pending.count)")
                        .font(AppFont.caption(12))
                        .foregroundStyle(Color.loomFaint)
                    Spacer()
                }
                .accessibilityElement(children: .combine)
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
        SharedStore.reloadWidgets()
    }

    private func deleteReminder(_ reminder: Reminder) {
        NotificationService.cancel(reminder)
        withAnimation {
            modelContext.delete(reminder)
        }
        SharedStore.reloadWidgets()
    }

    // MARK: - Task Sections (grouped by context)

    @ViewBuilder
    private var taskSections: some View {
        // Overdue tasks live in the triage section above, not here — the whole
        // point is that the pile can't silently accumulate in the regular list.
        let now = Date()
        let allIncomplete = tasks.filter { !$0.isComplete }
        let incomplete = allIncomplete.filter { $0.deadline > now }
        let sorted = incomplete.sorted { lhs, rhs in
            let lhsNext = lhs.nextBlock?.startTime ?? Date.distantFuture
            let rhsNext = rhs.nextBlock?.startTime ?? Date.distantFuture
            return lhsNext < rhsNext
        }

        if allIncomplete.isEmpty {
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
                        .accessibilityHidden(true)
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
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(context.rawValue), \(tasks.count) tasks")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

            CollapsibleSectionBody(isExpanded: isExpanded) {
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
            }
        }
    }

    // MARK: - Completed section

    @ViewBuilder
    private var completedSection: some View {
        let completed = tasks.filter(\.isComplete)
        let completedReminders = reminders.filter(\.isComplete)
        if !completed.isEmpty || !completedReminders.isEmpty {
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
                            .accessibilityHidden(true)
                        Text("Completed")
                            .font(AppFont.heading(15))
                            .foregroundStyle(Color.loomText)
                        Text("\(completed.count + completedReminders.count)")
                            .font(AppFont.caption(12))
                            .foregroundStyle(Color.loomFaint)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.loomFaint)
                            .rotationEffect(.degrees(showCompleted ? 90 : 0))
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Completed, \(completed.count + completedReminders.count) items")
                .accessibilityValue(showCompleted ? "Expanded" : "Collapsed")

                CollapsibleSectionBody(isExpanded: showCompleted) {
                    VStack(spacing: 10) {
                        ForEach(completed.sorted {
                            ($0.completedAt ?? $0.deadline) > ($1.completedAt ?? $1.deadline)
                        }) { task in
                            CompletedTaskRow(task: task) {
                                withAnimation {
                                    restoreTask(task, context: modelContext)
                                }
                            } onDelete: {
                                withAnimation {
                                    deleteTask(task, context: modelContext)
                                }
                                PlanCoordinator.publishChange(context: modelContext)
                            }
                            .padding(.horizontal, 20)
                        }
                        ForEach(completedReminders.sorted { $0.dueDate > $1.dueDate }) { reminder in
                            CompletedReminderRow(reminder: reminder) {
                                restoreReminder(reminder)
                            } onDelete: {
                                withAnimation {
                                    modelContext.delete(reminder)
                                }
                            }
                            .padding(.horizontal, 20)
                        }
                    }
                }
            }
        }
    }

    private func restoreReminder(_ reminder: Reminder) {
        withAnimation {
            reminder.isComplete = false
        }
        // Re-arm the alert if it hasn't fired yet; a past-due restore just
        // returns to the pending list.
        if reminder.dueDate > Date() {
            NotificationService.schedule(for: reminder)
        }
        SharedStore.reloadWidgets()
    }

    // MARK: - Completion

    private func completeTask(_ task: LoomTask) {
        withAnimation {
            PlanCoordinator.completeTask(task, context: modelContext)
        }
        celebrationTask = task
    }

}

// MARK: - Collapsible section body

/// The stable clipping frame that makes a disclosure's rows fold up into the
/// header when collapsed: without it, the removed rows slide up across the
/// whole screen instead of disappearing under the disclosure. Every
/// expandable section on this screen should collapse through this wrapper.
private struct CollapsibleSectionBody<Content: View>: View {
    let isExpanded: Bool
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            if isExpanded {
                content
                    .padding(.bottom, 16)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .clipped()
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
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Active count pill

/// Flame-and-count capsule in the header: how many tasks are on the loom.
private struct ActiveCountPill: View {
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "flame.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.brand300)
            Text("\(count)")
                .font(AppFont.mono(14))
                .foregroundStyle(Color.brand300)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .background(Color.brand500.opacity(0.12), in: Capsule())
        .overlay(Capsule().stroke(Color.brand500.opacity(0.35), lineWidth: 1))
        .hearthGlow(.brand500, radius: 12, opacity: 0.3)
        .accessibilityLabel("\(count) active tasks")
    }
}

// MARK: - Thread connector

/// The prototype's corner-glow path (`M1 0 V54 Q1 76 23 76 H86`): a vertical
/// drop from the hero card that curves into the "Up next" list.
private struct ThreadConnector: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 1, y: 0))
        path.addLine(to: CGPoint(x: 1, y: 54))
        path.addQuadCurve(to: CGPoint(x: 23, y: 76), control: CGPoint(x: 1, y: 76))
        path.addLine(to: CGPoint(x: 86, y: 76))

        // Branch from the rounded corner down to the section thread's rail.
        // The section rail's centerline sits at +7pt from the content leading
        // edge (6pt offset + half its 2pt width); this shape is drawn shifted
        // x: -0.5, so x = 7.5 here lands the branch exactly on that line.
        // Without this short overlap the two independently laid-out strokes
        // can show a gap at some sizes and display scales.
        path.move(to: CGPoint(x: 7.5, y: 70))
        path.addLine(to: CGPoint(x: 7.5, y: rect.maxY))
        return path
    }
}

// MARK: - Up next thread row

/// One bead on the thread of light: context dot breaking through the line,
/// task title, meta line, and a mono start-time badge.
private struct UpNextThreadRow: View {
    let task: LoomTask
    let block: ScheduledBlock
    var onStart: () -> Void
    var onEdit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(task.title)
                    .font(AppFont.cardTitle(14))
                    .foregroundStyle(Color.loomText)
                    .lineLimit(1)
                Text(metaLine)
                    .font(AppFont.caption(11))
                    .foregroundStyle(isUrgent ? Color.loomRed : Color.loomSubtle)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(TimeFormatter.clock.string(from: block.startTime))
                .font(AppFont.mono(12))
                .foregroundStyle(task.context.displayColor)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .background(Color.loomSurface)
        .clipShape(RoundedRectangle(cornerRadius: LoomRadius.row, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: LoomRadius.row, style: .continuous)
                .stroke(Color.loomBorder, lineWidth: 1)
        )
        // The context dot breaks through the thread at the row's heart line.
        .overlay(alignment: .leading) {
            Circle()
                .fill(task.context.color)
                .frame(width: 10, height: 10)
                .hearthGlow(task.context.color, radius: 7, opacity: 0.8)
                .offset(x: -18)
        }
        .contentShape(RoundedRectangle(cornerRadius: LoomRadius.row, style: .continuous))
        .onTapGesture(perform: onEdit)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .contextMenu {
            Button(action: onStart) {
                Label("Start Session", systemImage: "play.fill")
            }
            Button(action: onEdit) {
                Label("Edit", systemImage: "pencil")
            }
        }
    }

    private var isUrgent: Bool {
        task.deadline.timeIntervalSinceNow < 24 * 3600
    }

    private var metaLine: String {
        var parts = [task.context.rawValue]
        let due = CountdownFormatter.deadlineString(from: Date(), to: task.deadline)
            .replacingOccurrences(of: "Due", with: "due")
        parts.append(due)
        if task.progressPercent > 0 {
            parts.append("\(task.progressPercent)%")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Right Now card

/// The hero card at the top of the Tasks tab: what to do this minute, with
/// one button. Deliberately louder than everything below it — the block nudge
/// gets you to open the app; this removes the last decision.
private struct RightNowCard: View {
    let task: LoomTask
    let block: ScheduledBlock
    let now: Date
    var onStart: () -> Void
    var onPush: (BlockPushChoice) -> Void

    @State private var showPushOptions = false

    private var isActive: Bool { block.startTime <= now }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 16) {
                // The held flame in miniature: ring + live countdown, with the
                // same pulsing halo as the full-size session flame.
                ZStack {
                    HearthProgressRing(progress: ringProgress, size: 74, lineWidth: 7, showsHalo: isActive)
                    VStack(spacing: 0) {
                        Text(ringCountdown)
                            .font(AppFont.mono(15))
                            .foregroundStyle(Color.loomText)
                            .contentTransition(.numericText())
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                        Text(isActive ? "LEFT" : "UNTIL")
                            .font(AppFont.caption(8))
                            .foregroundStyle(Color.brand300)
                            .kerning(1)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                    }
                    .padding(.horizontal, 4)
                }
                .frame(width: 88, height: 88)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(isActive ? "Time left in block" : "Time until block")
                .accessibilityValue(ringCountdown)

                VStack(alignment: .leading, spacing: 4) {
                    Text(isActive ? "RIGHT NOW" : "UP NEXT")
                        .font(AppFont.caption(11))
                        .foregroundStyle(Color.brand300)
                        .kerning(1.4)
                    Text(task.title)
                        .font(AppFont.cardTitle(18))
                        .foregroundStyle(Color.loomText)
                        .lineLimit(2)
                    if let step = task.firstStep, !step.isEmpty {
                        Text("First step: \(step)")
                            .font(AppFont.bodySemibold(12))
                            .foregroundStyle(Color.loomSubtle)
                            .lineLimit(2)
                    } else {
                        Text(timelineLabel)
                            .font(AppFont.monoMedium(11))
                            .foregroundStyle(Color.loomSubtle)
                    }
                }
                .accessibilityElement(children: .combine)

                Spacer(minLength: 0)
            }

            Button(action: onStart) {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 14, weight: .semibold))
                    Text(isActive ? "Continue session" : "Start early")
                }
                .primaryButtonStyle()
            }

            Button {
                showPushOptions = true
            } label: {
                Text("Can't right now?")
                    .font(AppFont.caption(12))
                    .foregroundStyle(Color.loomSubtle)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        // A soft ember pooled in the top-right corner (applied before the
        // gradient fill so it renders in front of it, behind the content)…
        .background(alignment: .topTrailing) {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.brand500.opacity(0.3), .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: 75
                    )
                )
                .frame(width: 150, height: 150)
                .blur(radius: 10)
                .offset(x: 30, y: -40)
        }
        // …over accent light banked into the top-left one.
        .background(
            LinearGradient(
                stops: [
                    .init(color: Color.brand500.opacity(0.22), location: 0),
                    .init(color: Color(hex: 0x1A1A1E), location: 0.58)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: LoomRadius.hero, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: LoomRadius.hero, style: .continuous)
                .stroke(Color.brand300.opacity(0.28), lineWidth: 1)
        )
        // The thread's origin: light rims the card's bottom-left corner —
        // down the left edge, around the corner, along the bottom — and the
        // Up Next thread below picks it up. "Now → next" is one thread.
        .overlay(alignment: .bottomLeading) {
            ThreadConnector()
                .stroke(
                    LinearGradient(
                        stops: [
                            .init(color: Color.brand300.opacity(0), location: 0),
                            .init(color: Color.brand300.opacity(0.95), location: 0.45),
                            .init(color: Color.brand300.opacity(0), location: 1)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round)
                )
                .frame(width: 90, height: 78)
                .offset(x: -0.5, y: 1.5)
                .shadow(color: Color.brand500.opacity(0.6), radius: 6)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .shadow(color: Color.brand500.opacity(0.22), radius: 30, y: 12)
        .confirmationDialog("Can't right now?", isPresented: $showPushOptions, titleVisibility: .visible) {
            Button("Push 30 minutes") { onPush(.thirtyMinutes) }
            Button("Push 1 hour") { onPush(.oneHour) }
            Button("Push to tomorrow") { onPush(.tomorrow) }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("Life happens. The plan moves and the deadline math stays honest — no blocks quietly rot.")
        }
    }

    private var elapsedFraction: Double {
        let total = block.endTime.timeIntervalSince(block.startTime)
        guard total > 0 else { return 0 }
        return min(1, max(0, now.timeIntervalSince(block.startTime) / total))
    }

    /// Active: how far through the block the flame has burned. Upcoming: a
    /// faint spark so the ring never reads as empty.
    private var ringProgress: Double {
        isActive ? elapsedFraction : 0.03
    }

    /// mm:ss (or h:mm:ss) left in the block when active, or until it starts.
    private var ringCountdown: String {
        let target = isActive ? block.endTime : block.startTime
        let seconds = max(0, Int(target.timeIntervalSince(now)))
        if seconds >= 3600 * 10 {
            // Far-future block: mm:ss would be absurd, show hours.
            return "\(seconds / 3600)h"
        }
        return CountdownFormatter.timerString(seconds: seconds)
    }

    private var timelineLabel: String {
        if isActive {
            let elapsed = Int(now.timeIntervalSince(block.startTime)) / 60
            let remaining = max(0, Int(block.endTime.timeIntervalSince(now)) / 60)
            let elapsedPart = elapsed < 1
                ? "Just started"
                : "Started \(CountdownFormatter.effortString(minutes: elapsed)) ago"
            return "\(elapsedPart) · \(CountdownFormatter.effortString(minutes: remaining)) left"
        } else {
            let start = CountdownFormatter.string(from: now, to: block.startTime)
            let startPart = start == "now" ? "Starts now" : "Starts \(start)"
            return "\(startPart) · \(CountdownFormatter.effortString(minutes: block.durationMinutes)) block"
        }
    }
}

// MARK: - Overdue triage row

/// One overdue task, three kind exits. The framing matters: the pile is a
/// decision queue, not a wall of shame.
private struct OverdueTriageRow: View {
    let task: LoomTask
    var onNewDeadline: () -> Void
    var onComplete: () -> Void
    var onLetGo: () -> Void

    @State private var confirmLetGo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(task.title)
                    .font(AppFont.heading(15))
                    .foregroundStyle(Color.loomText)
                    .lineLimit(2)
                HStack(spacing: 5) {
                    Text("Was due \(dueLabel)")
                        .font(AppFont.caption(11))
                        .foregroundStyle(Color.loomRed)
                    Text("·")
                        .foregroundStyle(Color.loomFaint)
                    Text(task.context.rawValue)
                        .font(AppFont.caption(11))
                        .foregroundStyle(task.context.color)
                }
            }
            .accessibilityElement(children: .combine)

            HStack(spacing: 8) {
                TriageButton(
                    label: "New deadline",
                    icon: "calendar.badge.clock",
                    tint: .brand500,
                    action: onNewDeadline
                )
                TriageButton(
                    label: "Done actually",
                    icon: "checkmark.circle",
                    tint: .personalColor,
                    action: onComplete
                )
                TriageButton(
                    label: "Let it go",
                    icon: "wind",
                    tint: .loomSubtle
                ) {
                    confirmLetGo = true
                }
            }
        }
        .padding(16)
        .background(Color.loomSurface)
        .clipShape(RoundedRectangle(cornerRadius: LoomRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: LoomRadius.card, style: .continuous)
                .stroke(Color.loomRed.opacity(0.3), lineWidth: 1)
        )
        .confirmationDialog("Let it go?", isPresented: $confirmLetGo, titleVisibility: .visible) {
            Button("Let it go", role: .destructive, action: onLetGo)
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("\"\(task.title)\" disappears from your list. Dropping a task on purpose is a decision, not a failure.")
        }
    }

    private var dueLabel: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(task.deadline) {
            return "today at \(TimeFormatter.clock.string(from: task.deadline))"
        } else if calendar.isDateInYesterday(task.deadline) {
            return "yesterday"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: task.deadline)
    }
}

private struct TriageButton: View {
    let label: String
    let icon: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                Text(label)
                    .font(AppFont.caption(11))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(tint.opacity(0.12))
            )
        }
        .buttonStyle(.plain)
    }
}


// MARK: - Reminder Row

private struct ReminderRow: View {
    let reminder: Reminder
    var onComplete: () -> Void
    var onDelete: () -> Void

    @State private var confirmDelete = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "bell.fill")
                .font(.system(size: 13))
                .foregroundStyle(isOverdue ? Color.loomRed : Color.brand500)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(reminder.title)
                    .font(AppFont.bodySemibold(15))
                    .foregroundStyle(Color.loomText)
                    .lineLimit(1)
                Text(dueLabel)
                    .font(AppFont.caption(11))
                    .foregroundStyle(isOverdue ? Color.loomRed : Color.loomSubtle)
            }
            .accessibilityElement(children: .combine)

            Spacer()

            Button(action: onComplete) {
                Image(systemName: "circle")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(Color.loomFaint)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle().inset(by: -12))
            .accessibilityLabel("Mark reminder complete")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.loomSurface)
        .clipShape(RoundedRectangle(cornerRadius: LoomRadius.card, style: .continuous))
        .contextMenu {
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .confirmationDialog("Delete this reminder?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive, action: onDelete)
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("\"\(reminder.title)\" goes away for good. This can't be undone.")
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

    @State private var confirmDelete = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(Color.personalColor)
                .accessibilityHidden(true)

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
            .accessibilityElement(children: .combine)

            Spacer()

            Button(action: onRestore) {
                Image(systemName: "arrow.uturn.backward.circle")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(Color.loomSubtle)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle().inset(by: -12))
            .accessibilityLabel("Restore task")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.loomSurface.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: LoomRadius.card, style: .continuous))
        .contextMenu {
            Button(action: onRestore) {
                Label("Restore", systemImage: "arrow.uturn.backward")
            }
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("Delete Permanently", systemImage: "trash")
            }
        }
        .confirmationDialog("Delete permanently?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive, action: onDelete)
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("\"\(task.title)\" and its history go away for good. This can't be undone.")
        }
    }
}

// MARK: - Completed Reminder Row

private struct CompletedReminderRow: View {
    let reminder: Reminder
    var onRestore: () -> Void
    var onDelete: () -> Void

    @State private var confirmDelete = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "bell.fill")
                .font(.system(size: 15))
                .foregroundStyle(Color.loomFaint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(reminder.title)
                    .font(AppFont.bodySemibold(15))
                    .strikethrough()
                    .foregroundStyle(Color.loomSubtle)
                    .lineLimit(1)
                Text("Reminder · \(dueLabel)")
                    .font(AppFont.caption(11))
                    .foregroundStyle(Color.loomFaint)
            }
            .accessibilityElement(children: .combine)

            Spacer()

            Button(action: onRestore) {
                Image(systemName: "arrow.uturn.backward.circle")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(Color.loomSubtle)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle().inset(by: -12))
            .accessibilityLabel("Restore reminder")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.loomSurface.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: LoomRadius.card, style: .continuous))
        .contextMenu {
            Button(action: onRestore) {
                Label("Restore", systemImage: "arrow.uturn.backward")
            }
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("Delete Permanently", systemImage: "trash")
            }
        }
        .confirmationDialog("Delete permanently?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive, action: onDelete)
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("\"\(reminder.title)\" goes away for good. This can't be undone.")
        }
    }

    private var dueLabel: String {
        let calendar = Calendar.current
        let time = TimeFormatter.clock.string(from: reminder.dueDate)
        if calendar.isDateInToday(reminder.dueDate) {
            return time
        } else if calendar.isDateInYesterday(reminder.dueDate) {
            return "Yesterday \(time)"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return "\(formatter.string(from: reminder.dueDate)), \(time)"
    }
}

// MARK: - Delete

/// Delete a task and everything hanging off it, explicitly. The cascade rule
/// on `LoomTask.scheduledBlocks`/`workSessions` should handle this, but
/// SwiftData cascades have a history of leaving children behind with a nil
/// task — those are the "Unknown Task" ghost blocks on the Schedule. Deleting
/// the children first and saving immediately closes that hole.
@MainActor
func deleteTask(_ task: LoomTask, context: ModelContext) {
    for block in task.scheduledBlocks {
        context.delete(block)
    }
    for session in task.workSessions {
        context.delete(session)
    }
    context.delete(task)
    try? context.save()
}

// MARK: - Restore

/// Bring a completed task back: un-complete it and put its remaining effort
/// back on the schedule.
@MainActor
func restoreTask(_ task: LoomTask, context: ModelContext) {
    task.isComplete = false
    task.completedAt = nil
    // A task completed from a 100% progress report has nothing left to
    // schedule; nudge it back so the schedule reopens and progress stays
    // adjustable.
    if task.manualProgressPercent >= 100 {
        task.manualProgressPercent = 90
    }

    PlanCoordinator.reconcileTaskAfterProgress(task, context: context)
}
