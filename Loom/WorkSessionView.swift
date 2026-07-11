import SwiftUI
import SwiftData
import UIKit

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

    // Immersion: the end of the currently running scheduled block, if the
    // session started inside one. Bounds the hyperfocus spurt from both sides.
    @State private var blockEndTarget: Date?
    @State private var didWarnNearEnd = false
    @State private var didMarkBlockEnd = false
    @State private var immersionMessage: String?

    // Micro-start: a deliberately tiny commitment. "Work on the essay" is
    // unstartable; "ten minutes" is a dare you can take.
    @State private var microGoalSeconds: Int?
    @State private var didHitMicroGoal = false

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
                checkBlockBoundary()
                checkMicroGoal()
            }
        }
        .onDisappear {
            // Sheet dragged away mid-session: keep the worked time, skip the prompt.
            if isRunning {
                recordSession()
            }
            UIApplication.shared.isIdleTimerDisabled = false
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

                // The captured opening move, shown only while idle — once the
                // timer runs the start problem is solved.
                if !isRunning, let step = task.firstStep, !step.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.brand500)
                            .padding(.top, 3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Just start here")
                                .font(AppFont.caption(11))
                                .foregroundStyle(Color.loomSubtle)
                            Text(step)
                                .font(AppFont.bodySemibold(14))
                                .foregroundStyle(Color.loomText)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.loomSurface)
                    )
                    .padding(.top, 6)
                }
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

                if isRunning, let subtext = runningSubtext {
                    Text(subtext)
                        .font(AppFont.body(12))
                        .foregroundStyle(Color.loomSubtle)
                        .multilineTextAlignment(.center)
                        .transition(.opacity)
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

                if !isRunning {
                    Button {
                        startTapped(microMinutes: 10)
                    } label: {
                        Text("Just 10 minutes")
                            .font(AppFont.caption(13))
                            .foregroundStyle(task.context.color)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .overlay(
                                Capsule().stroke(task.context.color.opacity(0.35), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
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

    private func startTapped(microMinutes: Int? = nil) {
        let now = Date()
        sessionStart = now
        elapsedSeconds = 0
        withAnimation { isRunning = true }

        // Immersion: the screen stays awake for the whole session, and the
        // running block's end becomes the gentle boundary chime.
        UIApplication.shared.isIdleTimerDisabled = true
        blockEndTarget = task.scheduledBlocks
            .first { $0.startTime <= now && now < $0.endTime }?
            .endTime
        didWarnNearEnd = false
        didMarkBlockEnd = false
        immersionMessage = nil
        microGoalSeconds = microMinutes.map { $0 * 60 }
        didHitMicroGoal = false

        WorkSessionActivityController.start(
            taskTitle: task.title,
            contextName: task.context.rawValue,
            effortMinutes: task.effortMinutes,
            startedAt: now
        )
    }

    /// While a micro-goal is pending it owns the subtext (a countdown reads
    /// louder than any coaching); afterwards the immersion messages take over.
    private var runningSubtext: String? {
        if let goal = microGoalSeconds, !didHitMicroGoal {
            let left = CountdownFormatter.timerString(seconds: max(0, goal - elapsedSeconds))
            return "\(left) to your ten — that's the whole ask."
        }
        return immersionMessage
    }

    private func checkMicroGoal() {
        guard let goal = microGoalSeconds, !didHitMicroGoal, elapsedSeconds >= goal else { return }
        didHitMicroGoal = true
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation {
            immersionMessage = "Ten minutes done — that was the hard part. Keep going or stop; both count."
        }
    }

    /// Haptic + one-line nudge near and at the end of the running block. The
    /// near-end warning offers an off-ramp; the end marker bounds the
    /// Herculean spurt the app exists to prevent.
    private func checkBlockBoundary() {
        guard let end = blockEndTarget else { return }
        let remaining = end.timeIntervalSinceNow

        if remaining <= 600 && remaining > 0 && !didWarnNearEnd {
            didWarnNearEnd = true
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            withAnimation {
                immersionMessage = "About 10 minutes left in this block — a good stopping point is coming."
            }
        } else if remaining <= 0 && !didMarkBlockEnd {
            didMarkBlockEnd = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation {
                immersionMessage = "Block done. Stopping now is a win — no heroics required."
            }
        }
    }

    private func stopTapped() {
        WorkSessionActivityController.end()
        UIApplication.shared.isIdleTimerDisabled = false
        withAnimation {
            isRunning = false
            progressValue = Double(task.progressPercent)
            showProgressPrompt = true
        }
    }

    private func recordSession() {
        WorkSessionActivityController.end()
        UIApplication.shared.isIdleTimerDisabled = false
        guard elapsedSeconds > 0 else { return }
        let session = WorkSession(
            task: task,
            startedAt: sessionStart ?? Date().addingTimeInterval(-Double(elapsedSeconds)),
            durationSeconds: elapsedSeconds
        )
        modelContext.insert(session)
        // The first step's whole job is getting the first session started;
        // once that's happened it would just be stale noise.
        task.firstStep = nil
        isRunning = false
        elapsedSeconds = 0
        microGoalSeconds = nil
    }

    private func saveProgress() {
        let reported = Int(progressValue)
        recordSession()
        task.manualProgressPercent = max(task.manualProgressPercent, reported)
        onFinish(reported >= 100)
    }
}
