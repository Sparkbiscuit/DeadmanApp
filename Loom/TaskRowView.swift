import SwiftUI
import SwiftData

struct TaskRowView: View {
    @Environment(\.modelContext) private var modelContext
    let task: LoomTask
    var onStartSession: () -> Void = {}
    var onComplete: () -> Void = {}
    var onEdit: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Top row: title + context tag
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.title)
                        .font(AppFont.heading(16))
                        .foregroundStyle(Color.loomText)
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

                Text("\(task.progressPercent)%")
                    .font(AppFont.monoMedium(11))
                    .foregroundStyle(task.context.color)
                    .frame(width: 36, alignment: .trailing)
            }

            // Bottom row: time spent + session pill + complete button
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

                Spacer()

                Button(action: onStartSession) {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10))
                        Text("Start")
                            .font(AppFont.caption(12))
                    }
                    .foregroundStyle(task.context.color)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(task.context.color.opacity(0.13), in: Capsule())
                }
                .buttonStyle(.plain)

                Button(action: onComplete) {
                    Image(systemName: "circle")
                        .font(.system(size: 20, weight: .light))
                        .foregroundStyle(Color.loomFaint)
                }
                .buttonStyle(.plain)
            }
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
            Button(role: .destructive) {
                modelContext.delete(task)
                CalendarExportService.syncIfEnabled(context: modelContext)
                scheduleDidChange(context: modelContext)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var deadlineColor: Color {
        let hours = task.deadline.timeIntervalSince(Date()) / 3600
        if hours < 24 { return .loomRed }
        if hours < 72 { return .workColor }
        return .loomSubtle
    }

    private func rescheduleTask() {
        let settings = UserSettings.fetchOrCreate(in: modelContext)
        let allBlocks = (try? modelContext.fetch(FetchDescriptor<ScheduledBlock>())) ?? []
        let blockedTimes = (try? modelContext.fetch(FetchDescriptor<BlockedTime>())) ?? []
        let busyEvents = (try? modelContext.fetch(FetchDescriptor<BusyEvent>())) ?? []

        SchedulerService.reschedule(
            task: task,
            allBlocks: allBlocks,
            blockedTimes: blockedTimes,
            busyEvents: busyEvents,
            settings: settings,
            context: modelContext
        )
        CalendarExportService.syncIfEnabled(context: modelContext)
        scheduleDidChange(context: modelContext)
    }
}
