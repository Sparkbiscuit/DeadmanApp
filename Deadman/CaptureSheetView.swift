import SwiftUI
import SwiftData
import Speech

struct CaptureSheetView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var deadline = defaultDeadline()
    @State private var effortMinutes = 60
    @State private var context: TaskContext = .school
    @State private var customEffort = 180
    @State private var showCustomEffort = false

    // Scheduling result
    @State private var scheduleWarning: String?
    @State private var showWarning = false

    // Voice
    @State private var isListening = false
    @State private var speechRecognizer = SFSpeechRecognizer()
    @State private var recognitionTask: SFSpeechRecognitionTask?
    @State private var audioEngine = AVAudioEngine()

    @FocusState private var titleFocused: Bool

    private let effortOptions = [30, 60, 120]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Drag handle
                Capsule()
                    .fill(Color(.tertiaryLabel))
                    .frame(width: 36, height: 5)
                    .padding(.top, 10)
                    .padding(.bottom, 20)

                ScrollView {
                    VStack(spacing: 24) {
                        titleField
                        contextPicker
                        deadlinePicker
                        effortPicker
                        scheduleButton
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 40)
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Color.deadmanSubtle)
                }
            }
            .alert("Scheduling Warning", isPresented: $showWarning) {
                Button("Save Anyway") { saveTask() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(scheduleWarning ?? "")
            }
            .onAppear { titleFocused = true }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
    }

    // MARK: - Title Field

    private var titleField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What needs to get done?")
                .font(AppFont.caption())
                .foregroundStyle(Color.deadmanSubtle)

            HStack(spacing: 12) {
                TextField("e.g. Finish lab report", text: $title)
                    .font(AppFont.heading(20))
                    .focused($titleFocused)
                    .submitLabel(.done)

                Button {
                    toggleVoiceInput()
                } label: {
                    Image(systemName: isListening ? "mic.fill" : "mic")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(isListening ? Color.deadmanRed : Color.deadmanSubtle)
                        .frame(width: 44, height: 44)
                        .background(
                            Circle()
                                .fill(isListening ? Color.deadmanRed.opacity(0.15) : Color(.tertiarySystemFill))
                        )
                }
            }
        }
    }

    // MARK: - Context Picker

    private var contextPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Context")
                .font(AppFont.caption())
                .foregroundStyle(Color.deadmanSubtle)

            HStack(spacing: 10) {
                ForEach(TaskContext.allCases) { ctx in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            context = ctx
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: ctx.icon)
                                .font(.system(size: 13, weight: .semibold))
                            Text(ctx.rawValue)
                                .font(AppFont.caption(13))
                                .fontWeight(.semibold)
                        }
                        .foregroundStyle(context == ctx ? .white : .primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            Capsule()
                                .fill(context == ctx ? ctx.color : Color(.tertiarySystemFill))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Deadline Picker

    private var deadlinePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Deadline")
                .font(AppFont.caption())
                .foregroundStyle(Color.deadmanSubtle)

            DatePicker(
                "",
                selection: $deadline,
                in: Date()...,
                displayedComponents: [.date, .hourAndMinute]
            )
            .datePickerStyle(.compact)
            .labelsHidden()
        }
    }

    // MARK: - Effort Picker

    private var effortPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Estimated effort")
                .font(AppFont.caption())
                .foregroundStyle(Color.deadmanSubtle)

            HStack(spacing: 10) {
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
                }
                .onChange(of: customEffort) { _, newValue in
                    effortMinutes = newValue
                }
                .padding(.top, 4)
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
                    .font(AppFont.heading(17))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(title.isEmpty ? Color.deadmanSubtle : Color.deadmanRed)
            )
        }
        .disabled(title.isEmpty)
    }

    // MARK: - Scheduling Logic

    private func attemptSchedule() {
        let descriptor = FetchDescriptor<UserSettings>()
        let settings = (try? modelContext.fetch(descriptor))?.first ?? createDefaultSettings()

        let blockDescriptor = FetchDescriptor<ScheduledBlock>()
        let allBlocks = (try? modelContext.fetch(blockDescriptor)) ?? []

        let blockedDescriptor = FetchDescriptor<BlockedTime>()
        let blockedTimes = (try? modelContext.fetch(blockedDescriptor)) ?? []

        let task = DeadmanTask(
            title: title,
            context: context,
            deadline: deadline,
            effortMinutes: effortMinutes
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
            for block in blocks { modelContext.insert(block) }
            dismiss()

        case .partialFit(let blocks, let unscheduledMinutes):
            for block in blocks { modelContext.insert(block) }
            let hours = unscheduledMinutes / 60
            let mins = unscheduledMinutes % 60
            let timeStr = hours > 0 ? "\(hours)h \(mins)m" : "\(mins)m"
            scheduleWarning = "\(timeStr) of effort couldn't be scheduled before your deadline. Consider extending your deadline or reducing the estimate."
            showWarning = true

        case .noSlots:
            scheduleWarning = "No available time slots found before your deadline. Try extending the deadline, reducing the estimate, or allowing overnight scheduling."
            showWarning = true
        }
    }

    private func saveTask() {
        // Task is already inserted from attemptSchedule; just dismiss
        dismiss()
    }

    private func createDefaultSettings() -> UserSettings {
        let settings = UserSettings()
        modelContext.insert(settings)
        return settings
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

                let request = SFSpeechAudioBufferRecognitionRequest()
                request.shouldReportPartialResults = true

                let inputNode = audioEngine.inputNode
                let format = inputNode.outputFormat(forBus: 0)

                inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                    request.append(buffer)
                }

                audioEngine.prepare()
                try? audioEngine.start()
                isListening = true

                recognitionTask = speechRecognizer?.recognitionTask(with: request) { result, error in
                    if let result = result {
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
        }
    }

    private func stopListening() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionTask?.cancel()
        recognitionTask = nil
        isListening = false
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
                .font(AppFont.caption(14))
                .fontWeight(.semibold)
                .foregroundStyle(isSelected ? .white : .primary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    Capsule()
                        .fill(isSelected ? Color.deadmanRed : Color(.tertiarySystemFill))
                )
        }
        .buttonStyle(.plain)
    }
}
