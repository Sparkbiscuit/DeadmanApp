import SwiftUI
import SwiftData

struct WorkSessionView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let task: LoomTask
    @State private var activeSession: WorkSession?
    @State private var elapsedSeconds: Int = 0
    @State private var timer: Timer?
    @State private var showProgressPrompt = false
    @State private var reportedProgress: Double = 0.0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Spacer()
                taskHeader
                Spacer()
                timerDisplay
                Spacer()
                timerControls
                Spacer()
                sessionHistory
            }
            .padding(.horizontal, 24)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Work Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(Color.loomSubtle)
                }
            }
            .sheet(isPresented: $showProgressPrompt) {
                ProgressPromptView(
                    task: task,
                    sessionMinutes: elapsedSeconds / 60,
                    currentProgress: task.selfReportedProgress,
                    onSubmit: { progress in
                        finalizeSession(progress: progress)
                    }
                )
                .presentationDetents([.medium])
            }
            .onAppear { checkForActiveSession() }
            .onDisappear { timer?.invalidate() }
        }
    }

    // MARK: - Task Header

    private var taskHeader: some View {
        VStack(spacing: 8) {
            Text(task.context.rawValue)
                .contextTag(task.context)

            Text(task.title)
                .font(AppFont.heading(22))
                .multilineTextAlignment(.center)

            // Time budget indicator
            HStack(spacing: 4) {
                Image(systemName: budgetIcon)
                    .font(.system(size: 12))
                    .foregroundStyle(budgetColor)
                Text(budgetLabel)
                    .font(AppFont.mono(13))
                    .foregroundStyle(budgetColor)
            }
            .padding(.top, 4)
        }
    }

    private var budgetIcon: String {
        task.isOverBudget ? "exclamationmark.triangle.fill" : "clock"
    }

    private var budgetColor: Color {
        task.isOverBudget ? .orange : Color.loomSubtle
    }

    private var budgetLabel: String {
        let spent = CountdownFormatter.effortString(minutes: task.totalTimeSpentMinutes)
        let budget = CountdownFormatter.effortString(minutes: task.effortMinutes)
        if task.isOverBudget {
            return "\(spent) / \(budget) (over budget)"
        }
        return "\(spent) / \(budget) spent"
    }

    // MARK: - Timer Display

    private var timerDisplay: some View {
        VStack(spacing: 12) {
            Text(timerString)
                .font(.system(size: 64, weight: .light, design: .monospaced))
                .foregroundStyle(activeSession != nil ? .primary : Color.loomSubtle)

            if activeSession != nil {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.loomRed)
                        .frame(width: 8, height: 8)
                    Text("Working")
                        .font(AppFont.caption(13))
                        .foregroundStyle(Color.loomRed)
                }
                .transition(.opacity)
            }
        }
    }

    private var timerString: String {
        let hours = elapsedSeconds / 3600
        let minutes = (elapsedSeconds % 3600) / 60
        let seconds = elapsedSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    // MARK: - Controls

    private var timerControls: some View {
        HStack(spacing: 24) {
            if activeSession != nil {
                // Stop button
                Button {
                    stopSession()
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.white)
                            .frame(width: 72, height: 72)
                            .background(Color.loomRed, in: Circle())
                        Text("Stop")
                            .font(AppFont.caption(12))
                            .foregroundStyle(Color.loomSubtle)
                    }
                }
            } else {
                // Start button
                Button {
                    startSession()
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.white)
                            .frame(width: 72, height: 72)
                            .background(task.context.color, in: Circle())
                            .shadow(color: task.context.color.opacity(0.4), radius: 12, y: 6)
                        Text("Start Working")
                            .font(AppFont.caption(12))
                            .foregroundStyle(Color.loomSubtle)
                    }
                }
            }
        }
    }

    // MARK: - Session History

    private var sessionHistory: some View {
        let sessions = task.workSessions
            .sorted { $0.startedAt > $1.startedAt }
            .prefix(5)

        return VStack(alignment: .leading, spacing: 8) {
            if !sessions.isEmpty {
                Text("Recent Sessions")
                    .font(AppFont.caption(12))
                    .foregroundStyle(Color.loomSubtle)
                    .padding(.bottom, 2)

                ForEach(Array(sessions), id: \.id) { session in
                    HStack {
                        Text(sessionDateString(session.startedAt))
                            .font(AppFont.caption(12))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(CountdownFormatter.effortString(minutes: session.durationMinutes))
                            .font(AppFont.mono(12))
                            .foregroundStyle(.primary)
                        if session.progressAfter > 0 {
                            Text("+\(Int(session.progressAfter * 100))%")
                                .font(AppFont.mono(11))
                                .foregroundStyle(task.context.color)
                        }
                    }
                }
            }
        }
        .padding(.bottom, 24)
    }

    private func sessionDateString(_ date: Date) -> String {
        SharedFormatters.sessionFormatter.string(from: date)
    }

    // MARK: - Session Logic

    private func checkForActiveSession() {
        if let existing = task.workSessions.first(where: { $0.isActive }) {
            activeSession = existing
            elapsedSeconds = Int(Date().timeIntervalSince(existing.startedAt))
            startTimer()
        }
    }

    private func startSession() {
        Haptics.impact(.medium)
        let session = WorkSession(task: task)
        modelContext.insert(session)
        activeSession = session
        elapsedSeconds = 0
        startTimer()
    }

    private func stopSession() {
        Haptics.impact(.medium)
        timer?.invalidate()
        timer = nil
        reportedProgress = task.selfReportedProgress
        showProgressPrompt = true
    }

    private func finalizeSession(progress: Double) {
        guard let session = activeSession else { return }
        session.endedAt = Date()

        let previousProgress = task.selfReportedProgress
        let progressDelta = max(0, progress - previousProgress)
        session.progressAfter = progressDelta
        task.selfReportedProgress = min(1.0, progress)

        Haptics.notification(.success)
        activeSession = nil
        elapsedSeconds = 0
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            if let session = activeSession {
                elapsedSeconds = Int(Date().timeIntervalSince(session.startedAt))
            }
        }
    }
}

// MARK: - Progress Prompt

struct ProgressPromptView: View {
    let task: LoomTask
    let sessionMinutes: Int
    let currentProgress: Double
    let onSubmit: (Double) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var progress: Double

    init(task: LoomTask, sessionMinutes: Int, currentProgress: Double, onSubmit: @escaping (Double) -> Void) {
        self.task = task
        self.sessionMinutes = sessionMinutes
        self.currentProgress = currentProgress
        self.onSubmit = onSubmit
        self._progress = State(initialValue: currentProgress)
    }

    var body: some View {
        VStack(spacing: 24) {
            // Handle
            Capsule()
                .fill(Color(.tertiaryLabel))
                .frame(width: 36, height: 5)
                .padding(.top, 10)

            VStack(spacing: 6) {
                Text("Nice work!")
                    .font(AppFont.heading(20))
                Text("You worked for \(CountdownFormatter.effortString(minutes: sessionMinutes)).")
                    .font(AppFont.body())
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 12) {
                Text("How much of this task is done overall?")
                    .font(AppFont.caption(14))
                    .foregroundStyle(Color.loomSubtle)

                // Progress slider
                VStack(spacing: 8) {
                    HStack {
                        Text("\(Int(progress * 100))%")
                            .font(AppFont.heading(32))
                            .foregroundStyle(task.context.color)
                        Spacer()
                    }

                    Slider(value: $progress, in: currentProgress...1.0, step: 0.05)
                        .tint(task.context.color)

                    HStack {
                        Text("Before: \(Int(currentProgress * 100))%")
                            .font(AppFont.mono(11))
                            .foregroundStyle(Color.loomSubtle)
                        Spacer()
                        Text("Done")
                            .font(AppFont.mono(11))
                            .foregroundStyle(Color.loomSubtle)
                    }
                }
            }
            .padding(.horizontal, 4)

            Button {
                onSubmit(progress)
                dismiss()
            } label: {
                Text("Save Progress")
                    .font(AppFont.heading(16))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(task.context.color, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            Spacer()
        }
        .padding(.horizontal, 24)
    }
}
