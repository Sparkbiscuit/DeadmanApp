import SwiftUI
import SwiftData

struct TaskListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \LoomTask.deadline) private var tasks: [LoomTask]
    @Binding var replanSummary: CatchUpSummary
    @State private var showingCapture = false
    @State private var expandedContexts: Set<TaskContext> = Set(TaskContext.allCases)
    @State private var workSessionTask: LoomTask?
    @State private var celebrationTask: LoomTask?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    VStack(spacing: 0) {
                        headerSection
                        statsBar
                        replanBanner
                        taskSections
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
                }
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
                            ? "1 task no longer fits before its deadline — extend it or trim the estimate"
                            : "\(replanSummary.unschedulableTasks) tasks no longer fit before their deadlines — extend them or trim the estimates",
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
                            onComplete: { completeTask(task) }
                        )
                        .padding(.horizontal, 20)
                    }
                }
                .padding(.bottom, 16)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: - Completion

    private func completeTask(_ task: LoomTask) {
        withAnimation {
            task.isComplete = true
            task.manualProgressPercent = 100
            // Reserved future time is released back to the schedule.
            for block in task.scheduledBlocks where !block.isComplete && !block.isLocked {
                modelContext.delete(block)
            }
        }
        celebrationTask = task
        CalendarExportService.syncIfEnabled(context: modelContext)
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
