import SwiftUI
import SwiftData

/// Focused timer sheet for a single task: start/stop a session, then
/// self-report overall progress. Saving at 100% completes the task.
struct WorkSessionView: View {
    @Environment(\.modelContext) private var modelContext

    let task: LoomTask
    /// Called with `true` when the user reported the task finished.
    var onFinish: (Bool) -> Void

    @State private var isRunning = false
    @State private var elapsedSeconds = 0
    @State private var showProgressPrompt = false
    @State private var progressValue: Double = 0
    @State private var sessionStart: Date?

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            header

            if showProgressPrompt {
                progressPrompt
            } else {
                timerBody
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 30)
        .background(Color.loomBackground)
        .presentationDetents([.fraction(0.8)])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(LoomRadius.sheet)
        .onReceive(timer) { _ in
            if isRunning {
                elapsedSeconds += 1
            }
        }
        .onDisappear {
            // Sheet dragged away mid-session: keep the worked time, skip the prompt.
            if isRunning {
                recordSession()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Button("Close") {
                if isRunning {
                    stopTapped()
                } else {
                    if showProgressPrompt {
                        recordSession()
                    }
                    onFinish(false)
                }
            }
            .font(AppFont.caption(14))
            .foregroundStyle(Color.loomSubtle)

            Spacer()

            Text("Work Session")
                .font(AppFont.heading(14))
                .foregroundStyle(Color.loomText)

            Spacer()

            Color.clear.frame(width: 44, height: 1)
        }
        .padding(.top, 18)
        .padding(.bottom, 18)
    }

    // MARK: - Timer

    private var timerBody: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Text(task.context.rawValue)
                    .contextTag(task.context)
                Text(task.title)
                    .font(AppFont.heading(20))
                    .foregroundStyle(Color.loomText)
                    .multilineTextAlignment(.center)
                Text(budgetLabel)
                    .font(AppFont.monoMedium(13))
                    .foregroundStyle(isOverBudgetNow ? Color.workColor : Color.loomSubtle)
            }
            .padding(.top, 10)

            Spacer()

            VStack(spacing: 20) {
                Text(CountdownFormatter.timerString(seconds: elapsedSeconds))
                    .font(AppFont.mono(56))
                    .foregroundStyle(isRunning ? Color.loomText : Color.loomFaint)
                    .contentTransition(.numericText())

                if isRunning {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.loomRed)
                            .frame(width: 8, height: 8)
                        Text("Working")
                            .font(AppFont.caption(13))
                            .foregroundStyle(Color.loomRed)
                    }
                }

                Button {
                    isRunning ? stopTapped() : startTapped()
                } label: {
                    VStack(spacing: 6) {
                        ZStack {
                            Circle()
                                .fill(isRunning ? Color.loomRed : task.context.color)
                                .frame(width: 72, height: 72)
                                .shadow(
                                    color: (isRunning ? Color.loomRed : task.context.color).opacity(0.33),
                                    radius: 10, y: 10
                                )
                            Image(systemName: isRunning ? "stop.fill" : "play.fill")
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        Text(isRunning ? "Stop" : "Start Working")
                            .font(AppFont.body(12))
                            .foregroundStyle(Color.loomSubtle)
                    }
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
    }

    // MARK: - Progress prompt

    private var progressPrompt: some View {
        VStack(spacing: 16) {
            Spacer()

            Text("Nice work!")
                .font(AppFont.display(20))
                .foregroundStyle(Color.loomText)
            Text("You worked for \(sessionLengthLabel).")
                .font(AppFont.body(14))
                .foregroundStyle(Color.loomSubtle)

            VStack(spacing: 10) {
                Text("How much of this task is done overall?")
                    .font(AppFont.body(13))
                    .foregroundStyle(Color.loomSubtle)
                Text("\(Int(progressValue))%")
                    .font(AppFont.display(32))
                    .foregroundStyle(task.context.color)
                    .contentTransition(.numericText())
                Slider(value: $progressValue, in: sliderRange, step: 5)
                    .tint(task.context.color)
            }
            .padding(.top, 8)

            Button {
                saveProgress()
            } label: {
                Text("Save Progress")
                    .primaryButtonStyle(fill: task.context.color)
            }
            .padding(.top, 10)

            Spacer()
        }
    }

    private var sliderRange: ClosedRange<Double> {
        let minimum = Double(min(task.progressPercent, 95))
        return minimum...100
    }

    // MARK: - Labels

    private var spentTotalMinutes: Int {
        task.timeSpentMinutes + elapsedSeconds / 60
    }

    private var isOverBudgetNow: Bool {
        spentTotalMinutes > task.effortMinutes
    }

    private var budgetLabel: String {
        let spent = CountdownFormatter.effortString(minutes: spentTotalMinutes)
        let budget = CountdownFormatter.effortString(minutes: task.effortMinutes)
        return isOverBudgetNow ? "\(spent) / \(budget) (over budget)" : "\(spent) / \(budget) spent"
    }

    private var sessionLengthLabel: String {
        CountdownFormatter.effortString(minutes: max(1, elapsedSeconds / 60))
    }

    // MARK: - Actions

    private func startTapped() {
        let now = Date()
        sessionStart = now
        elapsedSeconds = 0
        withAnimation { isRunning = true }
        WorkSessionActivityController.start(
            taskTitle: task.title,
            contextName: task.context.rawValue,
            effortMinutes: task.effortMinutes,
            startedAt: now
        )
    }

    private func stopTapped() {
        WorkSessionActivityController.end()
        withAnimation {
            isRunning = false
            progressValue = Double(task.progressPercent)
            showProgressPrompt = true
        }
    }

    private func recordSession() {
        WorkSessionActivityController.end()
        guard elapsedSeconds > 0 else { return }
        let session = WorkSession(
            task: task,
            startedAt: sessionStart ?? Date().addingTimeInterval(-Double(elapsedSeconds)),
            durationSeconds: elapsedSeconds
        )
        modelContext.insert(session)
        isRunning = false
        elapsedSeconds = 0
    }

    private func saveProgress() {
        let reported = Int(progressValue)
        recordSession()
        task.manualProgressPercent = max(task.manualProgressPercent, reported)
        onFinish(reported >= 100)
    }
}
