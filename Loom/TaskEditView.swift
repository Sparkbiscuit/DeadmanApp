import SwiftUI
import SwiftData

/// Edit an existing task. Changes stay local until Save; edits that invalidate
/// the plan (deadline or effort) push the task back through the reschedule path.
struct TaskEditView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let task: LoomTask

    @State private var title: String = ""
    @State private var context: TaskContext = .school
    @State private var deadline: Date = Date()
    @State private var effortMinutes: Int = 60
    @State private var scheduleWarning: String?
    @State private var showWarning = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    titleField
                    contextPicker
                    deadlinePicker
                    effortPicker
                    saveButton
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
            .background(Color.loomBackground)
            .navigationTitle("Edit Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Color.loomSubtle)
                }
            }
            .alert("Scheduling Warning", isPresented: $showWarning) {
                Button("OK") { dismiss() }
            } message: {
                Text(scheduleWarning ?? "")
            }
            .onAppear(perform: loadTask)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(LoomRadius.sheet)
    }

    private func loadTask() {
        title = task.title
        context = task.context
        deadline = task.deadline
        effortMinutes = task.effortMinutes
    }

    // MARK: - Fields

    private var titleField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Title")
                .font(AppFont.caption(12))
                .foregroundStyle(Color.loomSubtle)
            TextField("Task title", text: $title)
                .font(AppFont.heading(19))
                .foregroundStyle(Color.loomText)
        }
    }

    private var contextPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Context")
                .font(AppFont.caption(12))
                .foregroundStyle(Color.loomSubtle)

            HStack(spacing: 8) {
                ForEach(TaskContext.allCases) { ctx in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            context = ctx
                        }
                    } label: {
                        Text(ctx.rawValue)
                            .font(AppFont.caption(12))
                            .foregroundStyle(context == ctx ? .white : Color.loomText)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 9)
                            .background(
                                Capsule()
                                    .fill(context == ctx ? ctx.color : Color.loomSurface2)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var deadlinePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Deadline")
                .font(AppFont.caption(12))
                .foregroundStyle(Color.loomSubtle)

            DatePicker(
                "",
                selection: $deadline,
                in: Date()...,
                displayedComponents: [.date, .hourAndMinute]
            )
            .datePickerStyle(.compact)
            .labelsHidden()
            .tint(Color.brand500)
        }
    }

    private var effortPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Estimated effort")
                .font(AppFont.caption(12))
                .foregroundStyle(Color.loomSubtle)

            Stepper(value: $effortMinutes, in: 15...720, step: 15) {
                Text(CountdownFormatter.effortString(minutes: effortMinutes))
                    .font(AppFont.mono(15))
                    .foregroundStyle(Color.loomText)
            }
        }
    }

    private var saveButton: some View {
        Button {
            save()
        } label: {
            Text("Save Changes")
                .primaryButtonStyle(enabled: isValid)
        }
        .disabled(!isValid)
        .padding(.top, 6)
    }

    private var isValid: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Save

    private func save() {
        let needsReplan = deadline != task.deadline || effortMinutes != task.effortMinutes

        task.title = title.trimmingCharacters(in: .whitespaces)
        task.context = context
        task.deadline = deadline
        task.effortMinutes = effortMinutes
        task.userModified = true

        var result: ScheduleResult?
        if needsReplan {
            let settings = UserSettings.fetchOrCreate(in: modelContext)
            let allBlocks = (try? modelContext.fetch(FetchDescriptor<ScheduledBlock>())) ?? []
            let blockedTimes = (try? modelContext.fetch(FetchDescriptor<BlockedTime>())) ?? []
            let busyEvents = (try? modelContext.fetch(FetchDescriptor<BusyEvent>())) ?? []

            result = SchedulerService.reschedule(
                task: task,
                allBlocks: allBlocks,
                blockedTimes: blockedTimes,
                busyEvents: busyEvents,
                settings: settings,
                context: modelContext
            )
        }

        CalendarExportService.syncIfEnabled(context: modelContext)
        SharedStore.reloadWidgets()

        switch result {
        case .partialFit(_, let unscheduledMinutes):
            let timeStr = CountdownFormatter.effortString(minutes: unscheduledMinutes)
            scheduleWarning = "Changes saved, but \(timeStr) of effort couldn't be scheduled before the deadline. Consider extending it or trimming the estimate."
            showWarning = true
        case .noSlots:
            scheduleWarning = "Changes saved, but no open time remains before the deadline. The task will show as not blocked."
            showWarning = true
        case .success, nil:
            dismiss()
        }
    }
}
