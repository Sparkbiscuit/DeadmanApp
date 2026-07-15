import SwiftUI
import SwiftData

struct TaskRowView: View {
    @Environment(\.modelContext) private var modelContext
    let task: LoomTask
    var onStartSession: () -> Void = {}
    var onComplete: () -> Void = {}
    var onEdit: () -> Void = {}

    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            summarySection
            actionRow
        }
        .cardStyle()
        .contentShape(RoundedRectangle(cornerRadius: LoomRadius.card, style: .continuous))
        .onTapGesture {
            onEdit()
        }
        .contextMenu {
            Button {
                onEdit()
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            Button {
                onComplete()
            } label: {
                Label("Mark Complete", systemImage: "checkmark.circle")
            }
            Button {
                rescheduleTask()
            } label: {
                Label("Reschedule", systemImage: "arrow.clockwise")
            }
            if task.templateId != nil {
                Button {
                    stopRepeating()
                } label: {
                    Label("Stop Repeating", systemImage: "repeat.circle")
                }
            }
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .confirmationDialog("Delete this task?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                deleteTask(task, context: modelContext)
                PlanCoordinator.publishChange(context: modelContext)
            }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("\"\(task.title)\" and its scheduled blocks go away for good. This can't be undone.")
        }
    }

    // MARK: - Summary (title, deadline, next block, progress)

    /// Everything that just describes the task, read as one VoiceOver stop
    /// with the row's own edit action — the interactive Start/Complete
    /// controls below stay individually reachable instead of being folded in.
    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Top row: title + context tag
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.title)
                        .font(AppFont.cardTitle(16))
                        .foregroundStyle(Color.loomText)
                        .lineLimit(2)

                    HStack(spacing: 5) {
                        // Pace dot: how much of the free time left this task
                        // would eat — the early warning, days before red.
                        if let pace = PaceCache.entry(for: task.id, context: modelContext) {
                            Circle()
                                .fill(paceColor(pace.level))
                                .frame(width: 7, height: 7)
                        }
                        Text(CountdownFormatter.deadlineString(from: Date(), to: task.deadline))
                            .font(AppFont.caption(12))
                            .foregroundStyle(deadlineColor)
                        if task.templateId != nil {
                            Image(systemName: "repeat")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Color.loomFaint)
                                .accessibilityHidden(true)
                        }
                    }
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
                        .accessibilityHidden(true)
                    Text("Starts \(CountdownFormatter.string(from: Date(), to: nextBlock.startTime))")
                        .font(AppFont.body(12))
                        .foregroundStyle(Color.loomSubtle)
                    Text("·")
                        .foregroundStyle(Color.loomSubtle)
                    Text(CountdownFormatter.effortString(minutes: nextBlock.durationMinutes))
                        .font(AppFont.monoMedium(11))
                        .foregroundStyle(Color.loomSubtle)
                }
            } else if !task.isFullyScheduled && task.remainingMinutes > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.loomRed)
                        .accessibilityHidden(true)
                    Text("Not blocked")
                        .font(AppFont.caption(12))
                        .foregroundStyle(Color.loomRed)
                    Text("·")
                        .foregroundStyle(Color.loomSubtle)
                    Text("\(CountdownFormatter.effortString(minutes: task.remainingMinutes)) remaining")
                        .font(AppFont.body(12))
                        .foregroundStyle(Color.loomSubtle)
                }
            }

            // Progress bar + percent
            HStack(spacing: 8) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.loomSurface3)
                            .frame(height: 4)
                        Capsule()
                            .fill(task.context.color)
                            .frame(width: geo.size.width * task.progressFraction, height: 4)
                    }
                }
                .frame(height: 4)
                .accessibilityHidden(true)

                Text("\(task.progressPercent)%")
                    .font(AppFont.monoMedium(11))
                    .foregroundStyle(task.context.color)
                    .frame(width: 36, alignment: .trailing)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onEdit() }
    }

    // MARK: - Actions (time spent, start, complete)

    private var actionRow: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                Image(systemName: "stopwatch")
                    .font(.system(size: 10))
                Text(CountdownFormatter.effortString(minutes: task.timeSpentMinutes))
                Text("/")
                Text(CountdownFormatter.effortString(minutes: task.effortMinutes))
                if task.isOverBudget {
                    Text("over")
                        .font(AppFont.caption(10))
                        .foregroundStyle(Color.workColor)
                }
            }
            .font(AppFont.monoMedium(11))
            .foregroundStyle(Color.loomSubtle)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(timeSpentAccessibilityLabel)

            Spacer()

            Button(action: onStartSession) {
                HStack(spacing: 4) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10))
                        .accessibilityHidden(true)
                    Text("Start")
                        .font(AppFont.caption(12))
                }
                .foregroundStyle(task.context.color)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(task.context.color.opacity(0.13), in: Capsule())
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle().inset(by: -8))
            .accessibilityLabel("Start work session")

            Button(action: onComplete) {
                Image(systemName: "circle")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(Color.loomFaint)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle().inset(by: -12))
            .accessibilityLabel("Mark complete")
        }
    }

    private var timeSpentAccessibilityLabel: String {
        let spent = CountdownFormatter.effortString(minutes: task.timeSpentMinutes)
        let budget = CountdownFormatter.effortString(minutes: task.effortMinutes)
        return task.isOverBudget
            ? "\(spent) of \(budget) worked, over budget"
            : "\(spent) of \(budget) worked"
    }

    private var deadlineColor: Color {
        let hours = task.deadline.timeIntervalSince(Date()) / 3600
        if hours < 24 { return .loomRed }
        if hours < 72 { return .workDisplay }
        return .loomSubtle
    }

    private func paceColor(_ level: PaceLevel) -> Color {
        switch level {
        case .comfortable: return .personalColor
        case .tightening: return .workColor
        case .critical: return .loomRed
        }
    }

    /// End the recurrence this task came from. Existing occurrences stay;
    /// no new copies get stamped out.
    private func stopRepeating() {
        guard let templateId = task.templateId else { return }
        let descriptor = FetchDescriptor<TaskTemplate>(
            predicate: #Predicate { $0.id == templateId }
        )
        if let template = (try? modelContext.fetch(descriptor))?.first {
            modelContext.delete(template)
        }
        // Clear the marker on every occurrence so their menus stop offering it.
        let siblings = (try? modelContext.fetch(FetchDescriptor<LoomTask>())) ?? []
        for sibling in siblings where sibling.templateId == templateId {
            sibling.templateId = nil
        }
    }

    private func rescheduleTask() {
        PlanCoordinator.rescheduleTask(task, context: modelContext)
    }
}
