import SwiftUI
import SwiftData

struct TaskRowView: View {
    @Environment(\.modelContext) private var modelContext
    let task: LoomTask
    @Binding var taskToComplete: LoomTask?
    @State private var showWorkSession = false
    @State private var rescheduleFeedback: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Top row: title + context tag
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.title)
                        .font(AppFont.heading(16))
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    HStack(spacing: 4) {
                        if let icon = deadlineIcon {
                            Image(systemName: icon)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(deadlineColor)
                        }
                        Text(CountdownFormatter.deadlineString(from: Date(), to: task.deadline))
                            .font(AppFont.caption(12))
                            .foregroundStyle(deadlineColor)
                    }
                    .accessibilityElement(children: .combine)
                }

                Spacer()

                Text(task.context.rawValue)
                    .contextTag(task.context)
            }

            // Middle row: next block info or warning
            if let nextBlock = task.nextBlock {
                HStack(spacing: 6) {
                    Image(systemName: "clock.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(task.context.color)
                    Text("Starts \(CountdownFormatter.string(from: Date(), to: nextBlock.startTime))")
                        .font(AppFont.caption(12))
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text(CountdownFormatter.effortString(minutes: nextBlock.durationMinutes))
                        .font(AppFont.mono(11))
                        .foregroundStyle(.secondary)
                }
            } else if !task.isFullyScheduled && task.remainingMinutes > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.loomRed)
                    Text("Unscheduled")
                        .font(AppFont.caption(12))
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.loomRed)
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text("\(CountdownFormatter.effortString(minutes: task.remainingMinutes)) remaining")
                        .font(AppFont.caption(12))
                        .foregroundStyle(.secondary)
                }
            }

            // Time tracking row
            HStack(spacing: 6) {
                // Self-reported progress bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color(.tertiarySystemFill))
                            .frame(height: 4)
                        Capsule()
                            .fill(task.context.color)
                            .frame(width: geo.size.width * CGFloat(task.selfReportedProgress), height: 4)
                            .animation(.easeInOut(duration: 0.4), value: task.selfReportedProgress)
                    }
                }
                .frame(height: 4)
                .accessibilityLabel("Progress: \(Int(task.selfReportedProgress * 100)) percent")

                Text("\(Int(task.selfReportedProgress * 100))%")
                    .font(AppFont.mono(11))
                    .foregroundStyle(task.context.color)
                    .frame(width: 32, alignment: .trailing)
                    .layoutPriority(1)
            }

            // Bottom row: time spent + actions
            HStack(spacing: 0) {
                timeSpentLabel

                Spacer()

                // Work session button
                Button {
                    Haptics.impact(.light)
                    showWorkSession = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: hasActiveSession ? "stop.circle.fill" : "play.circle.fill")
                            .font(.system(size: 14))
                        Text(hasActiveSession ? "Working..." : "Start")
                            .font(AppFont.caption(12))
                            .fontWeight(.semibold)
                    }
                    .foregroundStyle(hasActiveSession ? Color.loomRed : task.context.color)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(hasActiveSession ? Color.loomRed.opacity(0.12) : task.context.color.opacity(0.12))
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(hasActiveSession ? "Stop working on \(task.title)" : "Start working on \(task.title)")

                // Complete task button
                Button {
                    completeTask()
                } label: {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(Color.loomSubtle)
                }
                .buttonStyle(.plain)
                .padding(.leading, 10)
                .accessibilityLabel("Mark \(task.title) complete")
            }
        }
        .cardStyle()
        .overlay(alignment: .top) {
            if let message = rescheduleFeedback {
                Text(message)
                    .font(AppFont.caption(12))
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule().fill(task.context.color)
                    )
                    .offset(y: -10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .accessibilityAddTraits(.isStaticText)
            }
        }
        .sheet(isPresented: $showWorkSession) {
            WorkSessionView(task: task)
        }
        .contextMenu {
            Button {
                completeTask()
            } label: {
                Label("Mark Complete", systemImage: "checkmark.circle")
            }
            Button {
                showWorkSession = true
            } label: {
                Label("Start Working", systemImage: "play.circle")
            }
            Button {
                rescheduleTask()
            } label: {
                Label("Reschedule", systemImage: "arrow.clockwise")
            }
            Button(role: .destructive) {
                Haptics.notification(.warning)
                modelContext.delete(task)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: - Time Spent Label

    private var timeSpentLabel: some View {
        let spent = task.totalTimeSpentMinutes
        let estimate = task.effortMinutes

        return HStack(spacing: 4) {
            if spent > 0 {
                Image(systemName: "timer")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.loomSubtle)
                Text(CountdownFormatter.effortString(minutes: spent))
                    .font(AppFont.mono(11))
                    .foregroundStyle(task.isOverBudget ? .orange : .primary)
                Text("/")
                    .font(AppFont.mono(11))
                    .foregroundStyle(Color.loomSubtle)
                Text(CountdownFormatter.effortString(minutes: estimate))
                    .font(AppFont.mono(11))
                    .foregroundStyle(Color.loomSubtle)
                if task.isOverBudget {
                    Text("over")
                        .font(AppFont.caption(10))
                        .foregroundStyle(.orange)
                }
            } else {
                Image(systemName: "timer")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.loomSubtle)
                Text("0m / \(CountdownFormatter.effortString(minutes: estimate))")
                    .font(AppFont.mono(11))
                    .foregroundStyle(Color.loomSubtle)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var hasActiveSession: Bool {
        task.workSessions.contains { $0.isActive }
    }

    private var deadlineColor: Color {
        let hours = task.deadline.timeIntervalSince(Date()) / 3600
        if hours < 0 { return .loomRed }
        if hours < 24 { return .loomRed }
        if hours < 72 { return .orange }
        return .secondary
    }

    /// Non-color indicator for deadline urgency so users who can't perceive the
    /// color difference still get a signal.
    private var deadlineIcon: String? {
        let hours = task.deadline.timeIntervalSince(Date()) / 3600
        if hours < 0 { return "exclamationmark.triangle.fill" }
        if hours < 24 { return "exclamationmark.circle.fill" }
        if hours < 72 { return "clock.fill" }
        return nil
    }

    private func completeTask() {
        Haptics.notification(.success)
        withAnimation(.easeInOut(duration: 0.3)) {
            task.isComplete = true
            task.completedAt = Date()
            task.selfReportedProgress = 1.0
        }
        taskToComplete = task
    }

    private func rescheduleTask() {
        Haptics.impact(.medium)
        let descriptor = FetchDescriptor<UserSettings>()
        guard let settings = try? modelContext.fetch(descriptor).first else { return }

        let blockDescriptor = FetchDescriptor<ScheduledBlock>()
        let allBlocks = (try? modelContext.fetch(blockDescriptor)) ?? []

        let blockedDescriptor = FetchDescriptor<BlockedTime>()
        let blockedTimes = (try? modelContext.fetch(blockedDescriptor)) ?? []

        let result = SchedulerService.reschedule(
            task: task,
            allBlocks: allBlocks,
            blockedTimes: blockedTimes,
            settings: settings,
            context: modelContext
        )

        let message: String
        switch result {
        case .success(let blocks):
            Haptics.notification(.success)
            message = blocks.isEmpty ? "Nothing to reschedule" : "Rescheduled \(blocks.count) block\(blocks.count == 1 ? "" : "s")"
        case .partialFit(let blocks, let unscheduled):
            Haptics.notification(.warning)
            message = "Partial: \(blocks.count) block\(blocks.count == 1 ? "" : "s"), \(CountdownFormatter.effortString(minutes: unscheduled)) unscheduled"
        case .noSlots:
            Haptics.notification(.warning)
            message = "No slots available"
        }

        withAnimation(.easeInOut(duration: 0.25)) {
            rescheduleFeedback = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            withAnimation(.easeInOut(duration: 0.25)) {
                rescheduleFeedback = nil
            }
        }
    }
}
