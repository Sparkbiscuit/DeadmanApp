import SwiftUI
import SwiftData

/// Multi-row task entry, reached from the capture sheet's "Bulk add" link.
struct BulkEntryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    /// Called when scheduling finished and the whole capture flow should close.
    var onFinished: (() -> Void)? = nil

    @State private var rows: [BulkRow] = [BulkRow()]
    @State private var scheduleSummary: String?
    @State private var showSummary = false

    var body: some View {
        VStack(spacing: 0) {
            header
            headerInfo
            rowList
            bottomBar
        }
        .hearthScreen(topGlow: 0.18, bottomGlow: 0.24)
        .toolbar(.hidden, for: .navigationBar)
        .alert("Scheduled", isPresented: $showSummary) {
            Button("Done") {
                if let onFinished {
                    onFinished()
                } else {
                    dismiss()
                }
            }
        } message: {
            Text(scheduleSummary ?? "")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Button("Back") { dismiss() }
                .font(AppFont.caption(14))
                .foregroundStyle(Color.loomSubtle)

            Spacer()

            Text("Bulk Entry")
                .font(AppFont.heading(14))
                .foregroundStyle(Color.loomText)

            Spacer()

            Color.clear.frame(width: 44, height: 1)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 10)
    }

    private var headerInfo: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Add multiple tasks at once")
                .font(AppFont.body(14))
                .foregroundStyle(Color.loomText)
            Text("Great for entering assignments from a syllabus.")
                .font(AppFont.body(12))
                .foregroundStyle(Color.loomSubtle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
    }

    // MARK: - Row List

    private var rowList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach($rows) { $row in
                    BulkRowCard(row: $row) {
                        if rows.count > 1 {
                            withAnimation { rows.removeAll { $0.id == row.id } }
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
            .padding(.vertical, 4)
            .padding(.bottom, 16)
        }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider().overlay(Color.loomBorder)

            HStack(spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        rows.append(BulkRow())
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .bold))
                        Text("Add Row")
                            .font(AppFont.caption(13))
                    }
                    .foregroundStyle(Color.loomRed)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.loomRed, lineWidth: 1.5)
                    )
                }

                Button {
                    scheduleAll()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "calendar.badge.clock")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Schedule All")
                            .font(AppFont.heading(14))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(validRows.isEmpty ? Color.loomFaint : Color.brand500)
                    )
                }
                .disabled(validRows.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 16)
        }
    }

    // MARK: - Scheduling

    private var validRows: [BulkRow] {
        rows.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private func scheduleAll() {
        let settings = UserSettings.fetchOrCreate(in: modelContext)
        let blockedTimes = (try? modelContext.fetch(FetchDescriptor<BlockedTime>())) ?? []
        let busyEvents = (try? modelContext.fetch(FetchDescriptor<BusyEvent>())) ?? []

        var blockDescriptor = FetchDescriptor<ScheduledBlock>()
        blockDescriptor.sortBy = [SortDescriptor(\ScheduledBlock.startTime)]
        var allBlocks = (try? modelContext.fetch(blockDescriptor)) ?? []

        var successCount = 0
        var warningCount = 0

        for row in validRows {
            let task = LoomTask(
                title: row.name.trimmingCharacters(in: .whitespaces),
                context: row.context,
                deadline: row.deadline,
                effortMinutes: row.effortMinutes,
                source: .bulkEntry
            )
            modelContext.insert(task)

            let result = SchedulerService.schedule(
                task: task,
                allBlocks: allBlocks,
                blockedTimes: blockedTimes,
                busyEvents: busyEvents,
                settings: settings,
                from: Date().addingTimeInterval(TimeInterval(settings.startBufferMinutes * 60))
            )

            switch result {
            case .success(let blocks):
                for block in blocks {
                    modelContext.insert(block)
                    allBlocks.append(block)
                }
                successCount += 1
            case .partialFit(let blocks, _):
                for block in blocks {
                    modelContext.insert(block)
                    allBlocks.append(block)
                }
                warningCount += 1
            case .noSlots:
                warningCount += 1
            }
        }

        CalendarExportService.syncIfEnabled(context: modelContext)
        GoogleCalendarService.exportIfEnabled(context: modelContext)
        scheduleDidChange(context: modelContext)

        if warningCount > 0 {
            scheduleSummary = "\(successCount) tasks fully scheduled, \(warningCount) had scheduling warnings. Check the schedule view for details."
        } else {
            scheduleSummary = "\(successCount) tasks scheduled successfully."
        }
        showSummary = true
    }
}

// MARK: - Bulk Row Data

struct BulkRow: Identifiable {
    let id = UUID()
    var name: String = ""
    var deadline: Date = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
    var effortMinutes: Int = 60
    var context: TaskContext = .school
}

// MARK: - Bulk Row Card

private struct BulkRowCard: View {
    @Binding var row: BulkRow
    let onDelete: () -> Void

    private let effortOptions = [30, 60, 120, 180]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Task name", text: $row.name)
                    .font(AppFont.bodySemibold(14))
                    .foregroundStyle(Color.loomText)

                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(Color.loomFaint)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 8) {
                // Context
                Menu {
                    ForEach(TaskContext.allCases) { ctx in
                        Button {
                            row.context = ctx
                        } label: {
                            Label(ctx.rawValue, systemImage: ctx.icon)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: row.context.icon)
                            .font(.system(size: 10))
                        Text(row.context.rawValue)
                            .font(AppFont.caption(11))
                    }
                    .foregroundStyle(row.context.color)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule().fill(row.context.color.opacity(0.13))
                    )
                }

                // Effort
                Menu {
                    ForEach(effortOptions, id: \.self) { mins in
                        Button(CountdownFormatter.effortString(minutes: mins)) {
                            row.effortMinutes = mins
                        }
                    }
                } label: {
                    Text(CountdownFormatter.effortString(minutes: row.effortMinutes))
                        .font(AppFont.monoMedium(11))
                        .foregroundStyle(Color.loomText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(Color.loomSurface3)
                        )
                }

                Spacer()

                // Deadline
                DatePicker(
                    "",
                    selection: $row.deadline,
                    in: Date()...,
                    displayedComponents: [.date]
                )
                .labelsHidden()
                .datePickerStyle(.compact)
                .tint(Color.brand500)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.loomSurface2)
        )
    }
}
