import SwiftUI
import SwiftData
import Speech
import AVFoundation

struct CaptureSheetView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var firstStep = ""
    @State private var deadline = defaultDeadline()
    @State private var effortMinutes = 60
    @State private var context: TaskContext = .school
    @State private var customEffort = 180
    @State private var showCustomEffort = false
    @State private var showBulk = false
    @State private var useCustomStart = false
    @State private var customStart = Date().addingTimeInterval(15 * 60)
    @State private var repeatWeekly = false
    @State private var repeatUntil = Date().addingTimeInterval(35 * 86_400)

    // Capture mode: a scheduled task, or a one-off reminder
    private enum CaptureMode: String, CaseIterable {
        case task = "Task"
        case reminder = "Reminder"
    }
    @State private var captureMode: CaptureMode = .task
    @State private var reminderDate = Date().addingTimeInterval(3600)
    @State private var showNotificationsDeniedNote = false

    // Estimate reality-check: what the planned-vs-actual record says about
    // the current guess, and whether the suggestion was taken.
    @State private var estimateAdvice: EstimateAdvisor.Advice?
    @State private var estimateAccepted = false

    // Scheduling result — nothing is committed until the user confirms.
    @State private var scheduleWarning: String?
    @State private var showWarning = false
    @State private var pendingTask: LoomTask?
    @State private var pendingBlocks: [ScheduledBlock] = []

    // Voice
    @State private var isListening = false
    @State private var speechRecognizer = SFSpeechRecognizer()
    @State private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    @State private var recognitionTask: SFSpeechRecognitionTask?
    @State private var audioEngine = AVAudioEngine()

    @FocusState private var titleFocused: Bool

    private let effortOptions = [30, 60, 120]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                sheetHeader

                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        modePicker
                        titleField
                        if captureMode == .task {
                            firstStepField
                            contextPicker
                            deadlinePicker
                            repeatPicker
                            effortPicker
                            estimateAdviceRow
                            startPicker
                            scheduleButton
                        } else {
                            reminderDatePicker
                            reminderButton
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 40)
                }
            }
            .hearthScreen(topGlow: 0.18, bottomGlow: 0.24)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showBulk) {
                BulkEntryView {
                    dismiss()
                }
            }
            .alert("Scheduling Warning", isPresented: $showWarning) {
                Button("Make Room") { makeRoom() }
                Button("Save Anyway") { commitPending() }
                Button("Cancel", role: .cancel) { discardPending() }
            } message: {
                Text(scheduleWarning ?? "")
            }
            .onAppear {
                titleFocused = true
                refreshEstimateAdvice()
            }
            .onChange(of: context) { _, _ in
                estimateAccepted = false
                refreshEstimateAdvice()
            }
            .onChange(of: effortMinutes) { _, newValue in
                // Accepting the suggestion changes the effort too — don't
                // treat that as a fresh guess and immediately re-advise on it.
                if estimateAccepted && newValue == estimateAdvice?.suggestedMinutes { return }
                estimateAccepted = false
                refreshEstimateAdvice()
            }
            .onDisappear { if isListening { stopListening() } }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(LoomRadius.sheet)
    }

    // MARK: - Header

    private var sheetHeader: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .font(AppFont.caption(14))
                .foregroundStyle(Color.loomSubtle)
                .contentShape(Rectangle().inset(by: -14))

            Spacer()

            Button("Bulk add") { showBulk = true }
                .font(AppFont.caption(14))
                .foregroundStyle(Color.brand300)
                .contentShape(Rectangle().inset(by: -14))
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 18)
    }

    // MARK: - Mode picker

    private var modePicker: some View {
        HStack(spacing: 2) {
            ForEach(CaptureMode.allCases, id: \.self) { mode in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        captureMode = mode
                    }
                } label: {
                    Text(mode.rawValue)
                        .font(AppFont.caption(13))
                        .foregroundStyle(captureMode == mode ? Color.brand100 : Color.loomSubtle)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(
                            Capsule()
                                .fill(captureMode == mode ? Color.brand500.opacity(0.28) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.loomSurface))
        .overlay(Capsule().stroke(Color.loomBorder, lineWidth: 1))
    }

    // MARK: - Reminder form

    private var reminderDatePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Remind me at")
                .font(AppFont.caption(12))
                .foregroundStyle(Color.loomSubtle)

            DatePicker(
                "",
                selection: $reminderDate,
                in: Date()...,
                displayedComponents: [.date, .hourAndMinute]
            )
            .datePickerStyle(.compact)
            .labelsHidden()
            .tint(Color.brand500)
            .accessibilityLabel("Remind me at")

            if showNotificationsDeniedNote {
                Text("Notifications are off for Loom. The reminder is saved, but no alert will fire; enable notifications in Settings.")
                    .font(AppFont.body(12))
                    .foregroundStyle(Color.loomRed)
            }
        }
    }

    private var reminderButton: some View {
        Button {
            saveReminder()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "bell.badge")
                    .font(.system(size: 16, weight: .semibold))
                Text("Set Reminder")
            }
            .primaryButtonStyle(enabled: !title.isEmpty)
        }
        .disabled(title.isEmpty)
        .padding(.top, 6)
    }

    private func saveReminder() {
        let reminder = Reminder(
            title: title.trimmingCharacters(in: .whitespaces),
            dueDate: reminderDate
        )
        modelContext.insert(reminder)
        SharedStore.reloadWidgets()

        Task { @MainActor in
            let granted = await NotificationService.requestAuthorization()
            if granted {
                NotificationService.schedule(for: reminder)
                dismiss()
            } else {
                showNotificationsDeniedNote = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { dismiss() }
            }
        }
    }

    // MARK: - Title Field

    private var titleField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What needs to get done?")
                .font(AppFont.caption(12))
                .foregroundStyle(Color.loomSubtle)

            HStack(spacing: 12) {
                TextField("e.g. Finish lab report", text: $title)
                    .font(AppFont.heading(19))
                    .foregroundStyle(Color.loomText)
                    .focused($titleFocused)
                    .submitLabel(.done)

                Button {
                    toggleVoiceInput()
                } label: {
                    Image(systemName: isListening ? "mic.fill" : "mic")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(isListening ? Color.loomRed : Color.loomSubtle)
                        .frame(width: 40, height: 40)
                        .background(
                            Circle()
                                .fill(isListening ? Color.loomRed.opacity(0.13) : Color.loomSurface2)
                        )
                }
                .contentShape(Rectangle().inset(by: -2))
                .accessibilityLabel(isListening ? "Stop voice input" : "Start voice input")
            }
        }
    }

    // MARK: - First Step Field

    /// Optional, never required — but a concrete opening move is what makes a
    /// task startable later. Surfaces in the hero card, the block-start nudge,
    /// and the work session timer.
    private var firstStepField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What's the very first physical action? (optional)")
                .font(AppFont.caption(12))
                .foregroundStyle(Color.loomSubtle)

            TextField("e.g. Open the doc and paste the data", text: $firstStep)
                .font(AppFont.body(15))
                .foregroundStyle(Color.loomText)
                .submitLabel(.done)
        }
    }

    // MARK: - Context Picker

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
                    .accessibilityAddTraits(context == ctx ? [.isSelected] : [])
                }
            }
        }
    }

    // MARK: - Deadline Picker

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
            .accessibilityLabel("Deadline")
        }
    }

    // MARK: - Effort Picker

    private var effortPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Estimated effort")
                .font(AppFont.caption(12))
                .foregroundStyle(Color.loomSubtle)

            HStack(spacing: 8) {
                ForEach(effortOptions, id: \.self) { mins in
                    EffortChip(
                        label: CountdownFormatter.effortString(minutes: mins),
                        isSelected: !showCustomEffort && effortMinutes == mins
                    ) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showCustomEffort = false
                            effortMinutes = mins
                        }
                    }
                }
                EffortChip(
                    label: "3h+",
                    isSelected: showCustomEffort
                ) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showCustomEffort = true
                        effortMinutes = customEffort
                    }
                }
            }

            if showCustomEffort {
                Stepper(
                    value: $customEffort,
                    in: 180...720,
                    step: 30
                ) {
                    Text(CountdownFormatter.effortString(minutes: customEffort))
                        .font(AppFont.mono(15))
                        .foregroundStyle(Color.loomText)
                }
                .onChange(of: customEffort) { _, newValue in
                    effortMinutes = newValue
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: - Repeat picker

    /// Weekly problem sets, readings, chores: capture once, and a fresh copy
    /// with the same shape appears each week until the end date.
    private var repeatPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Repeats")
                .font(AppFont.caption(12))
                .foregroundStyle(Color.loomSubtle)

            HStack(spacing: 8) {
                EffortChip(label: "One-off", isSelected: !repeatWeekly) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        repeatWeekly = false
                    }
                }
                EffortChip(label: "Weekly", isSelected: repeatWeekly) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        repeatWeekly = true
                        repeatUntil = max(repeatUntil, deadline.addingTimeInterval(7 * 86_400))
                    }
                }
            }

            if repeatWeekly {
                HStack {
                    Text("Until")
                        .font(AppFont.body(13))
                        .foregroundStyle(Color.loomSubtle)
                    DatePicker(
                        "",
                        selection: $repeatUntil,
                        in: Date()...,
                        displayedComponents: [.date]
                    )
                    .datePickerStyle(.compact)
                    .labelsHidden()
                    .tint(Color.brand500)
                    .accessibilityLabel("Repeat until")
                    Spacer()
                }
                .padding(.top, 4)
                Text("A fresh copy appears each week, scheduled around whatever that week holds.")
                    .font(AppFont.body(11))
                    .foregroundStyle(Color.loomFaint)
            }
        }
    }

    // MARK: - Estimate reality-check

    /// A gentle line from the record, not a lecture: "your last N tasks like
    /// this ran over — plan for X instead?" with a one-tap accept.
    @ViewBuilder
    private var estimateAdviceRow: some View {
        if let advice = estimateAdvice {
            if estimateAccepted {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.personalColor)
                        .accessibilityHidden(true)
                    Text("Planned for \(CountdownFormatter.effortString(minutes: effortMinutes)) — future you says thanks.")
                        .font(AppFont.body(12))
                        .foregroundStyle(Color.loomSubtle)
                    Spacer(minLength: 0)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "hourglass")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.workColor)
                            .padding(.top, 1)
                            .accessibilityHidden(true)
                        Text("Your last \(advice.sampleCount) \(context.rawValue) tasks ran about \(advice.ratioLabel) over their estimates.")
                            .font(AppFont.body(13))
                            .foregroundStyle(Color.loomText)
                    }

                    Button {
                        acceptEstimateSuggestion()
                    } label: {
                        Text("Plan for \(CountdownFormatter.effortString(minutes: advice.suggestedMinutes)) instead")
                            .font(AppFont.caption(13))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.workColor, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.workColor.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: LoomRadius.card, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: LoomRadius.card, style: .continuous)
                        .stroke(Color.workColor.opacity(0.25), lineWidth: 1)
                )
            }
        }
    }

    private func refreshEstimateAdvice() {
        estimateAdvice = EstimateAdvisor.advice(
            for: context,
            effortMinutes: effortMinutes,
            in: modelContext
        )
    }

    private func acceptEstimateSuggestion() {
        guard let advice = estimateAdvice else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            if advice.suggestedMinutes >= 180 {
                showCustomEffort = true
                customEffort = advice.suggestedMinutes
            } else {
                showCustomEffort = false
            }
            effortMinutes = advice.suggestedMinutes
            estimateAccepted = true
        }
    }

    // MARK: - Earliest start

    private var startPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Earliest start")
                .font(AppFont.caption(12))
                .foregroundStyle(Color.loomSubtle)

            HStack(spacing: 8) {
                EffortChip(label: "Soon", isSelected: !useCustomStart) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        useCustomStart = false
                    }
                }
                EffortChip(label: "Pick a time", isSelected: useCustomStart) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        useCustomStart = true
                        customStart = max(customStart, Date())
                    }
                }
            }

            if useCustomStart {
                DatePicker(
                    "",
                    selection: $customStart,
                    in: Date()...,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .datePickerStyle(.compact)
                .labelsHidden()
                .tint(Color.brand500)
                .accessibilityLabel("Earliest start")
                .padding(.top, 4)
            } else {
                Text("Leaves a short gap before your first block so you can settle in.")
                    .font(AppFont.body(11))
                    .foregroundStyle(Color.loomFaint)
            }
        }
    }

    // MARK: - Schedule Button

    private var scheduleButton: some View {
        Button {
            attemptSchedule()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 16, weight: .semibold))
                Text("Schedule it")
            }
            .primaryButtonStyle(enabled: !title.isEmpty)
        }
        .disabled(title.isEmpty)
        .padding(.top, 6)
    }

    // MARK: - Scheduling Logic

    private func attemptSchedule() {
        let settings = UserSettings.fetchOrCreate(in: modelContext)
        let allBlocks = (try? modelContext.fetch(FetchDescriptor<ScheduledBlock>())) ?? []
        let blockedTimes = (try? modelContext.fetch(FetchDescriptor<BlockedTime>())) ?? []
        let busyEvents = (try? modelContext.fetch(FetchDescriptor<BusyEvent>())) ?? []

        // Build without inserting — a cancelled warning must leave no trace.
        let trimmedStep = firstStep.trimmingCharacters(in: .whitespaces)
        let task = LoomTask(
            title: title,
            context: context,
            deadline: deadline,
            effortMinutes: effortMinutes,
            firstStep: trimmedStep.isEmpty ? nil : trimmedStep
        )

        // Never book work to start "right now" — leave the configured buffer,
        // unless the user picked an explicit earliest start.
        let earliestStart = useCustomStart
            ? max(customStart, Date())
            : Date().addingTimeInterval(TimeInterval(settings.startBufferMinutes * 60))

        let result = SchedulerService.schedule(
            task: task,
            allBlocks: allBlocks,
            blockedTimes: blockedTimes,
            busyEvents: busyEvents,
            settings: settings,
            from: earliestStart
        )

        switch result {
        case .success(let blocks):
            pendingTask = task
            pendingBlocks = blocks
            commitPending()

        case .partialFit(let blocks, let unscheduledMinutes):
            pendingTask = task
            pendingBlocks = blocks
            let timeStr = CountdownFormatter.effortString(minutes: unscheduledMinutes)
            scheduleWarning = "\(timeStr) of effort couldn't fit in the open gaps before your deadline. Make Room moves later-deadline work aside; Save Anyway keeps the partial plan."
            showWarning = true

        case .noSlots:
            pendingTask = task
            pendingBlocks = []
            scheduleWarning = "No open gaps before your deadline. Make Room moves later-deadline work aside, or extend the deadline."
            showWarning = true
        }
    }

    private func commitPending() {
        guard let task = pendingTask else { return }
        modelContext.insert(task)
        for block in pendingBlocks {
            modelContext.insert(block)
        }
        insertTemplateIfRepeating(for: task)
        pendingTask = nil
        pendingBlocks = []
        CalendarExportService.syncIfEnabled(context: modelContext)
        GoogleCalendarService.exportIfEnabled(context: modelContext)
        scheduleDidChange(context: modelContext)
        dismiss()
    }

    /// A weekly capture leaves a template behind; the foreground refresh
    /// stamps out the future occurrences from it.
    private func insertTemplateIfRepeating(for task: LoomTask) {
        guard repeatWeekly,
              let nextDeadline = Calendar.current.date(byAdding: .day, value: 7, to: task.deadline),
              nextDeadline <= repeatUntil else { return }
        let template = TaskTemplate(
            title: task.title,
            context: task.context,
            effortMinutes: task.effortMinutes,
            firstStep: task.firstStep,
            nextDeadline: nextDeadline,
            repeatUntil: repeatUntil
        )
        modelContext.insert(template)
        task.templateId = template.id
    }

    /// The new task doesn't fit in the gaps: commit it and rebuild the whole
    /// plan by deadline, letting it bump later-deadline work.
    private func makeRoom() {
        guard let task = pendingTask else { return }
        modelContext.insert(task)
        insertTemplateIfRepeating(for: task)
        pendingTask = nil
        pendingBlocks = []

        let settings = UserSettings.fetchOrCreate(in: modelContext)
        let tasks = (try? modelContext.fetch(FetchDescriptor<LoomTask>())) ?? []
        let allBlocks = (try? modelContext.fetch(FetchDescriptor<ScheduledBlock>())) ?? []
        let blockedTimes = (try? modelContext.fetch(FetchDescriptor<BlockedTime>())) ?? []
        let busyEvents = (try? modelContext.fetch(FetchDescriptor<BusyEvent>())) ?? []

        SchedulerService.rebalance(
            tasks: tasks,
            allBlocks: allBlocks,
            blockedTimes: blockedTimes,
            busyEvents: busyEvents,
            settings: settings,
            context: modelContext
        )
        CalendarExportService.syncIfEnabled(context: modelContext)
        GoogleCalendarService.exportIfEnabled(context: modelContext)
        scheduleDidChange(context: modelContext)
        dismiss()
    }

    private func discardPending() {
        pendingTask = nil
        pendingBlocks = []
    }

    private static func defaultDeadline() -> Date {
        Calendar.current.date(byAdding: .day, value: 3, to: Date()) ?? Date()
    }

    // MARK: - Voice Input

    private func toggleVoiceInput() {
        if isListening {
            stopListening()
        } else {
            startListening()
        }
    }

    private func startListening() {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                guard status == .authorized else { return }
                beginRecognition()
            }
        }
    }

    private func beginRecognition() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            return
        }
        isListening = true

        recognitionTask = speechRecognizer?.recognitionTask(with: request) { result, error in
            if let result {
                DispatchQueue.main.async {
                    title = result.bestTranscription.formattedString
                }
            }
            if error != nil || (result?.isFinal ?? false) {
                DispatchQueue.main.async {
                    stopListening()
                }
            }
        }
    }

    private func stopListening() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        isListening = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

// MARK: - Effort Chip

private struct EffortChip: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(AppFont.caption(12))
                .foregroundStyle(isSelected ? .white : Color.loomText)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    Capsule()
                        .fill(isSelected ? Color.brand500 : Color.loomSurface2)
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
