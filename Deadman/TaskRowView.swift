import SwiftUI
import SwiftData

struct TaskRowView: View {
    @Environment(\.modelContext) private var modelContext
    let task: DeadmanTask
    @State private var showActions = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Top row: title + context tag
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.title)
                        .font(AppFont.heading(16))
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    Text(CountdownFormatter.deadlineString(from: Date(), to: task.deadline))
                        .font(AppFont.caption(12))
                        .foregroundStyle(deadlineColor)
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
                        .foregroundStyle(Color.deadmanRed)
                    Text("Not blocked")
                        .font(AppFont.caption(12))
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.deadmanRed)
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text("\(CountdownFormatter.effortString(minutes: task.remainingMinutes)) remaining")
                        .font(AppFont.caption(12))
                        .foregroundStyle(.secondary)
                }
            }

            // Bottom row: effort progress
            HStack(spacing: 8) {
                // Progress bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color(.tertiarySystemFill))
                            .frame(height: 4)
                        Capsule()
                            .fill(task.context.color)
                            .frame(width: geo.size.width * progress, height: 4)
                    }
                }
                .frame(height: 4)

                Text(CountdownFormatter.effortString(minutes: task.completedMinutes) +
                     " / " +
                     CountdownFormatter.effortString(minutes: task.effortMinutes))
                    .font(AppFont.mono(11))
                    .foregroundStyle(Color.deadmanSubtle)
                    .layoutPriority(1)
            }
        }
        .cardStyle()
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                withAnimation { modelContext.delete(task) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                withAnimation { task.isComplete = true }
            } label: {
                Label("Complete", systemImage: "checkmark.circle.fill")
            }
            .tint(.green)
        }
        .contextMenu {
            Button {
                task.isComplete = true
            } label: {
                Label("Mark Complete", systemImage: "checkmark.circle")
            }
            Button {
                rescheduleTask()
            } label: {
                Label("Reschedule", systemImage: "arrow.clockwise")
            }
            Button(role: .destructive) {
                modelContext.delete(task)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var progress: CGFloat {
        guard task.effortMinutes > 0 else { return 0 }
        return CGFloat(task.completedMinutes) / CGFloat(task.effortMinutes)
    }

    private var deadlineColor: Color {
        let hours = task.deadline.timeIntervalSince(Date()) / 3600
        if hours < 0 { return .deadmanRed }
        if hours < 24 { return .deadmanRed }
        if hours < 72 { return .orange }
        return .secondary
    }

    private func rescheduleTask() {
        // Fetch settings and all blocks to reschedule
        let descriptor = FetchDescriptor<UserSettings>()
        guard let settings = try? modelContext.fetch(descriptor).first else { return }

        let blockDescriptor = FetchDescriptor<ScheduledBlock>()
        let allBlocks = (try? modelContext.fetch(blockDescriptor)) ?? []

        _ = SchedulerService.reschedule(
            task: task,
            allBlocks: allBlocks,
            settings: settings,
            context: modelContext
        )
    }
}
