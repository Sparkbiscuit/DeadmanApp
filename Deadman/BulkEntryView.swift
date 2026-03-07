import SwiftUI
import SwiftData

struct BulkEntryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var rows: [BulkRow] = [BulkRow()]
    @State private var isScheduling = false
    @State private var scheduleSummary: String?
    @State private var showSummary = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                headerInfo
                Divider()
                rowList
                bottomBar
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Bulk Entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Color.deadmanSubtle)
                }
            }
            .alert("Scheduled", isPresented: $showSummary) {
                Button("Done") { dismiss() }
            } message: {
                Text(scheduleSummary ?? "")
            }
        }
    }

    // MARK: - Header Info

    private var headerInfo: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Add multiple tasks at once")
                .font(AppFont.body())
                .foregroundStyle(.primary)
            Text("Great for entering assignments from a syllabus.")
                .font(AppFont.caption())
                .foregroundStyle(Color.deadmanSubtle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
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
            .padding(.vertical, 16)
        }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        VStack(spacing: 12) {
            Divider()

            HStack(spacing: 12) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        rows.append(BulkRow())
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .bold))
                        Text("Add Row")
                            .font(AppFont.caption(14))
                            .fontWeight(.semibold)
                    }
                    .foregroundStyle(Color.deadmanRed)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.deadmanRed, lineWidth: 1.5)
                    )
                }

                Spacer()

                Button {
                    scheduleAll()
                } label: {
                    HStack(spacing: 6) {
                        if isScheduling {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: "calendar.badge.clock")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        Text("Schedule All")
                            .font(AppFont.heading(15))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(validRows.isEmpty ? Color.deadmanSubtle : Color.deadmanRed)
                    )
                }
                .disabled(validRows.isEmpty || isScheduling)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
    }

    // MARK: - Scheduling

    private var validRows: [BulkRow] {
        rows.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private func scheduleAll() {
        isScheduling = true

        let descriptor = FetchDescriptor<UserSettings>()
        let settings = (try? modelContext.fetch(descriptor))?.first ?? {
            let s = UserSettings()
            modelContext.insert(s)
            return s
        }()

        var blockDescriptor = FetchDescriptor<ScheduledBlock>()
        blockDescriptor.sortBy = [SortDescriptor(\ScheduledBlock.startTime)]
        var allBlocks = (try? modelContext.fetch(blockDescriptor)) ?? []

        let blockedDescriptor = FetchDescriptor<BlockedTime>()
        let blockedTimes = (try? modelContext.fetch(blockedDescriptor)) ?? []

        var successCount = 0
        var warningCount = 0

        for row in validRows {
            let task = DeadmanTask(
                title: row.name,
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
                settings: settings
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

        isScheduling = false

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
                    .font(AppFont.body(15))
                    .fontWeight(.medium)

                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Color.deadmanSubtle)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 12) {
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
                            .font(.system(size: 11))
                        Text(row.context.rawValue)
                            .font(AppFont.caption(12))
                    }
                    .foregroundStyle(row.context.color)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule().fill(row.context.color.opacity(0.15))
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
                        .font(AppFont.mono(12))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(Color(.tertiarySystemFill))
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
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }
}
