import SwiftUI
import SwiftData
import UIKit

/// The held flame: a full-height focus timer for a single task. Start/pause/
/// stop a session around the glowing ring, then self-report overall progress.
/// Saving at 100% completes the task.
struct WorkSessionView: View {
    @Environment(\.modelContext) private var modelContext

    let task: LoomTask
    /// Called with `true` when the user reported the task finished.
    var onFinish: (Bool) -> Void

    @State private var isRunning = false
    @State private var isPaused = false
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
        // The held flame at full strength: no top glow to compete with the
        // ring, a hot floor, and the densest ember field in the app.
        .hearthScreen(topGlow: 0.05, bottomGlow: 0.5, embers: 30, emberIntensity: 1.5)
        .onReceive(timer) { _ in
            if isRunning && !isPaused {
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
                .font(AppFont.cardTitle(15))
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
            VStack(spacing: 10) {
                Text(task.context.rawValue)
                    .contextTag(task.context)
                Text(task.title)
                    .font(AppFont.cardTitle(22))
                    .foregroundStyle(Color.loomText)
                    .multilineTextAlignment(.center)
                Text(budgetLabel)
                    .font(AppFont.monoMedium(13))
                    .foregroundStyle(isOverBudgetNow ? Color.workDisplay : Color.loomSubtle)

                // The captured opening move, shown only while idle — once the
                // timer runs the start problem is solved.
                if !isRunning, let step = task.firstStep, !step.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.brand300)
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
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.loomBorder, lineWidth: 1)
                    )
                    .padding(.top, 6)
                }
            }
            .padding(.top, 6)

            Spacer()

            VStack(spacing: 26) {
                heldFlameRing

                if let subtext = statusPillText {
                    HStack(spacing: 8) {
                        Image(systemName: "flame.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.brand300)
                        Text(subtext)
                            .font(AppFont.bodySemibold(13))
                            .foregroundStyle(Color.brand100)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.brand500.opacity(0.12), in: Capsule())
                    .overlay(Capsule().stroke(Color.brand500.opacity(0.35), lineWidth: 1))
                    .hearthGlow(.brand500, radius: 14, opacity: 0.25)
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
                }

                if isRunning, let end = blockEndTarget {
                    Text("block ends \(TimeFormatter.clock.string(from: end)) · schedule holds until then")
                        .font(AppFont.monoMedium(12))
                        .foregroundStyle(Color.loomFaint)
                }
            }

            Spacer()

            footer
        }
    }

    /// The 200pt held-flame ring: pulsing halo, conic accent arc, inner dark
    /// disc carrying the big mono timer and a breathing status label.
    private var heldFlameRing: some View {
        ZStack {
            HearthProgressRing(
                progress: ringProgress,
                size: 200,
                lineWidth: 13,
                showsHalo: isRunning && !isPaused
            )

            Circle()
                .fill(
                    // Light pools near the top of the disc (`circle at 50% 28%`).
                    RadialGradient(
                        colors: [Color(hex: 0x1E1E22), Color(hex: 0x131316)],
                        center: UnitPoint(x: 0.5, y: 0.28),
                        startRadius: 10,
                        endRadius: 130
                    )
                )
                .overlay(Circle().stroke(Color.white.opacity(0.06), lineWidth: 1))
                .frame(width: 168, height: 168)

            VStack(spacing: 8) {
                Text(timerLabel)
                    .font(AppFont.mono(38))
                    .foregroundStyle(isRunning && !isPaused ? Color.loomText : Color.loomSubtle)
                    .contentTransition(.numericText())

                HStack(spacing: 6) {
                    if isRunning && !isPaused {
                        BreathingDot(color: .brand300, size: 6)
                    }
                    Text(statusLabel)
                        .font(AppFont.caption(11))
                        .foregroundStyle(Color.brand300)
                        .kerning(2)
                }
            }
        }
        .frame(width: 244, height: 244)
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        if isRunning {
            HStack(spacing: 12) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isPaused.toggle()
                    }
                } label: {
                    Text(isPaused ? "Resume" : "Pause")
                        .font(AppFont.heading(16))
                        .foregroundStyle(Color.loomText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            RoundedRectangle(cornerRadius: LoomRadius.card, style: .continuous)
                                .fill(Color.white.opacity(0.04))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: LoomRadius.card, style: .continuous)
                                .stroke(Color.white.opacity(0.12), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .frame(maxWidth: 130)

                Button {
                    stopTapped()
                } label: {
                    Text("Stop & log progress")
                        .primaryButtonStyle()
                }
                .buttonStyle(.plain)
            }
        } else {
            VStack(spacing: 12) {
                Button {
                    startTapped()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Start working")
                    }
                    .primaryButtonStyle()
                }
                .buttonStyle(.plain)

                Button {
                    startTapped(microMinutes: 10)
                } label: {
                    Text("Just 10 minutes")
                        .font(AppFont.caption(13))
                        .foregroundStyle(Color.brand300)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .overlay(
                            Capsule().stroke(Color.brand500.opacity(0.4), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Progress prompt

    private var progressPrompt: some View {
        VStack(spacing: 16) {
            Spacer()

            Text("Nice work!")
                .font(AppFont.title(22))
                .foregroundStyle(LinearGradient.hearthTitle)
            Text("You wove for \(sessionLengthLabel).")
                .font(AppFont.body(14))
                .foregroundStyle(Color.loomSubtle)

            VStack(spacing: 10) {
                Text("How much of this task is done overall?")
                    .font(AppFont.body(13))
                    .foregroundStyle(Color.loomSubtle)
                Text("\(Int(progressValue))%")
                    .font(AppFont.mono(34))
                    .foregroundStyle(task.context.displayColor)
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
        return isOverBudgetNow
            ? "\(spent) of \(budget) budget — over"
            : "\(spent) of \(budget) budget used"
    }

    private var sessionLengthLabel: String {
        CountdownFormatter.effortString(minutes: max(1, elapsedSeconds / 60))
    }

    /// Counts down to the block end while working inside a block; otherwise
    /// counts the session up.
    private var timerLabel: String {
        if isRunning, let end = blockEndTarget {
            let remaining = Int(end.timeIntervalSinceNow)
            if remaining > 0 {
                return CountdownFormatter.timerString(seconds: remaining)
            }
        }
        return CountdownFormatter.timerString(seconds: elapsedSeconds)
    }

    private var statusLabel: String {
        if !isRunning { return "READY" }
        if isPaused { return "RESTING" }
        return "WEAVING"
    }

    /// How much of the flame is held: progress through the running block, or
    /// budget burned when the session floats outside any block.
    private var ringProgress: Double {
        if isRunning, let end = blockEndTarget {
            let remaining = max(0, end.timeIntervalSinceNow)
            let total = remaining + Double(elapsedSeconds)
            guard total > 0 else { return 0 }
            return Double(elapsedSeconds) / total
        }
        guard task.effortMinutes > 0 else { return 0 }
        return min(1, Double(spentTotalMinutes) / Double(task.effortMinutes))
    }

    /// While a micro-goal is pending it owns the pill (a countdown reads
    /// louder than any coaching); afterwards the immersion messages take over.
    private var statusPillText: String? {
        guard isRunning else { return nil }
        if let goal = microGoalSeconds, !didHitMicroGoal {
            let left = CountdownFormatter.timerString(seconds: max(0, goal - elapsedSeconds))
            return "\(left) to your ten — that's the whole ask."
        }
        if didHitMicroGoal && immersionMessage == nil {
            return "10-minute dare met · keep going?"
        }
        return immersionMessage
    }

    // MARK: - Actions

    private func startTapped(microMinutes: Int? = nil) {
        let now = Date()
        sessionStart = now
        elapsedSeconds = 0
        isPaused = false
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
            startedAt: now,
            blockEndsAt: blockEndTarget
        )
    }

    private func checkMicroGoal() {
        guard let goal = microGoalSeconds, !didHitMicroGoal, elapsedSeconds >= goal else { return }
        didHitMicroGoal = true
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation {
            immersionMessage = "10-minute dare met · keep going?"
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
            isPaused = false
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
        isPaused = false
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
