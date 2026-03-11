import SwiftUI
import SwiftData

struct TaskListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \LoomTask.deadline) private var tasks: [LoomTask]
    @State private var showingCapture = false
    @State private var expandedContexts: Set<TaskContext> = Set(TaskContext.allCases)
    @State private var taskToComplete: LoomTask?

    var body: some View {
        NavigationStack {
            ZStack {
                // Main content
                ZStack(alignment: .bottomTrailing) {
                    ScrollView {
                        VStack(spacing: 0) {
                            headerSection
                            statsBar
                            if incompleteTasks.isEmpty {
                                emptyState
                            } else {
                                taskSections
                            }
                        }
                        .padding(.bottom, 100)
                    }
                    #if os(iOS)
                    .background(Color(uiColor: .systemGroupedBackground))
                    #else
                    .background(Color(nsColor: .controlBackgroundColor))
                    #endif

                    captureButton
                }
                .sheet(isPresented: $showingCapture) {
                    CaptureSheetView()
                }

                // Completion celebration overlay
                if let completedTask = taskToComplete {
                    Color.black.opacity(0.6)
                        .ignoresSafeArea()
                        .transition(.opacity)

                    TaskCompletionView(task: completedTask) {
                        withAnimation(.easeOut(duration: 0.3)) {
                            taskToComplete = nil
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 40)
                    .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.35), value: taskToComplete?.id)
        }
    }

    // MARK: - Data

    private var incompleteTasks: [LoomTask] {
        tasks.filter { !$0.isComplete }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(greeting)
                .font(AppFont.caption())
                .foregroundStyle(Color.loomSubtle)
            Text("Your Tasks")
                .font(AppFont.title(32))
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
        let incomplete = incompleteTasks
        let unscheduled = incomplete.filter { !$0.isFullyScheduled }
        let todayBlocks = todayBlockCount

        return HStack(spacing: 12) {
            StatPill(
                value: "\(incomplete.count)",
                label: "active",
                color: .primary
            )
            StatPill(
                value: "\(todayBlocks)",
                label: "today",
                color: .schoolColor
            )
            if !unscheduled.isEmpty {
                StatPill(
                    value: "\(unscheduled.count)",
                    label: "unscheduled",
                    color: .loomRed
                )
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }

    private var todayBlockCount: Int {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!

        return tasks.flatMap { $0.scheduledBlocks }
            .filter { !$0.isComplete && $0.startTime >= today && $0.startTime < tomorrow }
            .count
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer().frame(height: 40)

            Image(systemName: "text.badge.plus")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(Color.loomSubtle)

            VStack(spacing: 6) {
                Text("No tasks yet")
                    .font(AppFont.heading(20))
                    .foregroundStyle(.primary)
                Text("Tap the + button to add your first task\nand Loom will schedule it for you.")
                    .font(AppFont.body(15))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 40)
    }

    // MARK: - Task Sections (grouped by context)

    private var taskSections: some View {
        let sorted = incompleteTasks.sorted { lhs, rhs in
            let lhsNext = lhs.nextBlock?.startTime ?? Date.distantFuture
            let rhsNext = rhs.nextBlock?.startTime ?? Date.distantFuture
            return lhsNext < rhsNext
        }

        return ForEach(TaskContext.allCases) { context in
            let contextTasks = sorted.filter { $0.context == context }
            if !contextTasks.isEmpty {
                contextSection(context: context, tasks: contextTasks)
            }
        }
    }

    private func contextSection(context: TaskContext, tasks: [LoomTask]) -> some View {
        let isExpanded = expandedContexts.contains(context)

        return VStack(spacing: 0) {
            // Section header
            Button {
                Haptics.selection()
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
                        .font(AppFont.heading(16))
                        .foregroundStyle(.primary)
                    Text("\(tasks.count)")
                        .font(AppFont.caption(12))
                        .foregroundStyle(Color.loomSubtle)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.loomSubtle)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(context.rawValue), \(tasks.count) tasks")
            .accessibilityHint(isExpanded ? "Double tap to collapse" : "Double tap to expand")

            if isExpanded {
                VStack(spacing: 10) {
                    ForEach(tasks) { task in
                        TaskRowView(task: task, taskToComplete: $taskToComplete)
                            .padding(.horizontal, 20)
                    }
                }
                .padding(.bottom, 16)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: - Capture FAB

    private var captureButton: some View {
        Button {
            Haptics.impact(.medium)
            showingCapture = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 60, height: 60)
                .background(Color.loomRed, in: Circle())
                .shadow(color: Color.loomRed.opacity(0.4), radius: 12, y: 6)
        }
        .accessibilityLabel("Add new task")
        .padding(.trailing, 24)
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
                .font(AppFont.heading(16))
                .foregroundStyle(color)
            Text(label)
                .font(AppFont.caption(12))
                .foregroundStyle(Color.loomSubtle)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        #if os(iOS)
        .background(Color(uiColor: .tertiarySystemGroupedBackground), in: Capsule())
        #else
        .background(Color(nsColor: .tertiaryLabelColor).opacity(0.1), in: Capsule())
        #endif
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(value) \(label)")
    }
}
