import SwiftUI
import SwiftData

struct CompletedTasksView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \LoomTask.completedAt, order: .reverse) private var tasks: [LoomTask]

    private var completedTasks: [LoomTask] {
        tasks.filter { $0.isComplete }
    }

    private var totalTimeSpent: Int {
        completedTasks.reduce(0) { $0 + $1.totalTimeSpentMinutes }
    }

    var body: some View {
        NavigationStack {
            Group {
                if completedTasks.isEmpty {
                    emptyState
                } else {
                    List {
                        summarySection
                        ForEach(groupedTasks, id: \.key) { group in
                            Section(group.header) {
                                ForEach(group.tasks) { task in
                                    CompletedTaskRow(task: task)
                                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                            Button(role: .destructive) {
                                                deleteTask(task)
                                            } label: {
                                                Label("Delete", systemImage: "trash")
                                            }
                                            Button {
                                                unmarkComplete(task)
                                            } label: {
                                                Label("Reopen", systemImage: "arrow.uturn.backward")
                                            }
                                            .tint(.blue)
                                        }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Completed")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(Color.loomSubtle)
                }
            }
        }
    }

    // MARK: - Summary

    private var summarySection: some View {
        Section {
            HStack(spacing: 14) {
                SummaryTile(
                    value: "\(completedTasks.count)",
                    label: "completed",
                    color: .green
                )
                SummaryTile(
                    value: CountdownFormatter.effortString(minutes: totalTimeSpent),
                    label: "time logged",
                    color: .loomRed
                )
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        }
    }

    // MARK: - Grouping

    private struct TaskGroup {
        let key: String
        let header: String
        let tasks: [LoomTask]
    }

    private var groupedTasks: [TaskGroup] {
        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        let startOfWeek = calendar.date(byAdding: .day, value: -7, to: startOfToday) ?? startOfToday
        let startOfMonth = calendar.date(byAdding: .day, value: -30, to: startOfToday) ?? startOfToday

        var today: [LoomTask] = []
        var thisWeek: [LoomTask] = []
        var thisMonth: [LoomTask] = []
        var older: [LoomTask] = []

        for task in completedTasks {
            let completed = task.completedAt ?? Date.distantPast
            if completed >= startOfToday {
                today.append(task)
            } else if completed >= startOfWeek {
                thisWeek.append(task)
            } else if completed >= startOfMonth {
                thisMonth.append(task)
            } else {
                older.append(task)
            }
        }

        var groups: [TaskGroup] = []
        if !today.isEmpty { groups.append(TaskGroup(key: "today", header: "Today", tasks: today)) }
        if !thisWeek.isEmpty { groups.append(TaskGroup(key: "week", header: "This Week", tasks: thisWeek)) }
        if !thisMonth.isEmpty { groups.append(TaskGroup(key: "month", header: "This Month", tasks: thisMonth)) }
        if !older.isEmpty { groups.append(TaskGroup(key: "older", header: "Older", tasks: older)) }
        return groups
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(Color.loomSubtle)
            Text("No completed tasks yet")
                .font(AppFont.heading(18))
                .foregroundStyle(.primary)
            Text("Finished tasks will show up here with the time you logged against them.")
                .font(AppFont.body(14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(iOS)
        .background(Color(.systemGroupedBackground))
        #endif
    }

    // MARK: - Actions

    private func unmarkComplete(_ task: LoomTask) {
        Haptics.impact(.light)
        withAnimation(.easeInOut(duration: 0.25)) {
            task.isComplete = false
            task.completedAt = nil
            // Leave selfReportedProgress as-is so users don't lose their work estimate.
        }
    }

    private func deleteTask(_ task: LoomTask) {
        Haptics.notification(.warning)
        withAnimation(.easeInOut(duration: 0.25)) {
            modelContext.delete(task)
        }
    }
}

// MARK: - Row

private struct CompletedTaskRow: View {
    let task: LoomTask

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(task.title)
                    .font(AppFont.body(15))
                    .fontWeight(.medium)
                    .strikethrough(color: Color.loomSubtle)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Spacer()
                Text(task.context.rawValue)
                    .contextTag(task.context)
            }

            HStack(spacing: 10) {
                if let completedAt = task.completedAt {
                    Label(SharedFormatters.sessionFormatter.string(from: completedAt),
                          systemImage: "checkmark.circle.fill")
                        .font(AppFont.caption(11))
                        .foregroundStyle(Color.loomSubtle)
                        .labelStyle(.titleAndIcon)
                }
                if task.totalTimeSpentMinutes > 0 {
                    Label(CountdownFormatter.effortString(minutes: task.totalTimeSpentMinutes),
                          systemImage: "timer")
                        .font(AppFont.mono(11))
                        .foregroundStyle(task.isOverBudget ? .orange : Color.loomSubtle)
                        .labelStyle(.titleAndIcon)
                }
                if !task.workSessions.isEmpty {
                    Label("\(task.workSessions.count)",
                          systemImage: "waveform.path")
                        .font(AppFont.mono(11))
                        .foregroundStyle(Color.loomSubtle)
                        .labelStyle(.titleAndIcon)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Summary Tile

private struct SummaryTile: View {
    let value: String
    let label: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(AppFont.title(24))
                .foregroundStyle(color)
            Text(label)
                .font(AppFont.caption(12))
                .foregroundStyle(Color.loomSubtle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        #if os(iOS)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        #endif
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(value) \(label)")
    }
}
