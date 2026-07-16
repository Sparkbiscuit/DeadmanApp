import SwiftUI
import SwiftData
import UIKit

/// Chooses the reservation a newly started timer should fulfill. Corrupt stores
/// can contain overlapping blocks, so selection must not depend on SwiftData's
/// relationship ordering: prefer the earliest start, then earliest end, then a
/// stable identifier tie-breaker.
enum WorkSessionBlockSelector {
    static func currentIncompleteBlock(
        in blocks: [ScheduledBlock],
        at date: Date
    ) -> ScheduledBlock? {
        blocks
            .filter {
                !$0.isComplete
                    && $0.startTime <= date
                    && date < $0.endTime
            }
            .min { lhs, rhs in
                if lhs.startTime != rhs.startTime {
                    return lhs.startTime < rhs.startTime
                }
                if lhs.endTime != rhs.endTime {
                    return lhs.endTime < rhs.endTime
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }
}

/// The held flame: a full-height focus timer for a single task. Start/pause/
/// stop a session around the glowing ring, then self-report overall progress.
/// Saving at 100% completes the task.
struct WorkSessionView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    let task: LoomTask
    /// Called with `true` when the user reported the task finished.
    var onFinish: (Bool) -> Void

    @State private var isRunning = false
    @State private var isPaused = false
    @State private var elapsedSeconds = 0
    @State private var showProgressPrompt = false
    @State private var progressValue: Double = 0
    @State private var sessionStart: Date?
    /// Matches the App Group control snapshot and Live Activity attributes.
    /// A delayed intent for an older activity cannot affect a newer timer.
    @State private var activeSessionID: UUID?
    /// Retained only when SwiftData rejects the attendance durability boundary.
    /// A later Stop retries this same row instead of inserting a duplicate.
    @State private var pendingAttendanceRecord: WorkSession?
    @State private var pendingAttendanceCompletedLinkedBlock = false
    /// Captured when the timer starts so stopping after the block boundary still
    /// links the work log to the reservation it fulfilled.
    @State private var scheduledBlockId: UUID?

    // Pause bookkeeping: worked time is derived from the wall clock
    // (sessionStart → now, minus time spent paused), never from counting
    // timer ticks — ticks stop when the app leaves the foreground, which is
    // exactly when the ring used to snap back to zero.
    @State private var pausedAccumSeconds = 0
    @State private var pauseBegan: Date?

    // Immersion: the end of the currently running scheduled block, if the
    // session started inside one. Bounds the hyperfocus spurt from both sides.
    @State private var blockEndTarget: Date?
    /// The ring's anchor and denominator, shared verbatim with the Live
    /// Activity ring. Inside a block the window is the block's own span, so
    /// joining late starts the ring partway around and a restarted session
    /// picks up where the block's clock is now. Outside a block it's the full
    /// effort budget, backdated by time already spent — earlier sessions stay
    /// on the ring.
    @State private var ringStartTime: Date?
    @State private var ringWindowSeconds: Int?
    @State private var didWarnNearEnd = false
    @State private var didMarkBlockEnd = false
    @State private var immersionMessage: String?

    // Micro-start: a deliberately tiny commitment. "Work on the essay" is
    // unstartable; "ten minutes" is a dare you can take.
    @State private var microGoalSeconds: Int?
    @State private var didHitMicroGoal = false

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// The wall clock the ring reads. A plain `Date()` in `body` would freeze
    /// during a pause (nothing else invalidates the view then), making the
    /// ring jump on resume; ticking it here keeps ring and Live Activity on
    /// the same schedule clock through pauses.
    @State private var now = Date()

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
        .onAppear {
            rehydrateIfNeeded()
        }
        .onReceive(timer) { tick in
            guard isRunning else { return }
            // The ring carries the schedule, not the session: it keeps
            // ticking through a pause (only the count-up freezes).
            now = tick
            syncSharedControl(at: tick)
            if !isPaused {
                checkBlockBoundary()
                checkMicroGoal()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .workSessionControlDidChange)) {
            notification in
            guard isRunning,
                  let changedID = notification.object as? UUID,
                  changedID == activeSessionID else { return }
            let date = Date()
            now = date
            syncSharedControl(at: date)
        }
        // Coming back from the background: the timer publisher slept, so the
        // ring and label catch up to the wall clock immediately instead of
        // resuming from wherever the last tick left them.
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active {
                UIApplication.shared.isIdleTimerDisabled = false
            } else if isRunning {
                UIApplication.shared.isIdleTimerDisabled = true
            }
            if newPhase == .active && isRunning {
                now = Date()
                syncSharedControl(at: now)
            }
        }
        .onDisappear {
            // A running sheet can still disappear without Stop. Record through
            // the same durable path; after Stop, elapsedSeconds is already zero
            // so this remains idempotent.
            recordSession()
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
                    onFinish(false)
                }
            }
            .font(AppFont.caption(14))
            .foregroundStyle(Color.loomSubtle)
            .contentShape(Rectangle().inset(by: -14))

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
                            .accessibilityHidden(true)
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
                    .accessibilityElement(children: .combine)
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
                            .accessibilityHidden(true)
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
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)

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
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(statusLabel.capitalized)
            .accessibilityValue(timerLabel)
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
                        togglePause()
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
                            .accessibilityHidden(true)
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
                .contentShape(Rectangle().inset(by: -6))
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

    /// How much of the flame is held: the wall-clock fraction of the ring
    /// window (the block's own span, or the backdated budget outside a block)
    /// — the same interval the Live Activity ring renders, so the two never
    /// disagree. Starting mid-block picks the ring up partway around, and
    /// restarting a session on the same block resumes it instead of resetting
    /// to zero. May exceed 1: it loops a second lap over itself rather than
    /// clamping. Idle (pre-start) it shows budget burned. Like the Live
    /// Activity ring, it keeps advancing through a pause (the count-up label
    /// carries the pause; the ring carries the schedule).
    private var ringProgress: Double {
        if isRunning, let start = ringStartTime,
           let window = ringWindowSeconds, window > 0 {
            return max(0, now.timeIntervalSince(start)) / Double(window)
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
        if let journalTaskID = WorkSessionControlStore.load()?.taskID,
           journalTaskID != task.id {
            // Loom has one active timer. Never overwrite another task's
            // recovery journal just because this screen was presented.
            return
        }
        let now = Date()
        let sessionID = UUID()
        self.now = now // the ring's clock starts at the same instant
        sessionStart = now
        activeSessionID = sessionID
        elapsedSeconds = 0
        pausedAccumSeconds = 0
        pauseBegan = nil
        isPaused = false
        withAnimation { isRunning = true }

        // Immersion: the screen stays awake for the whole session, and the
        // running block's end becomes the gentle boundary chime.
        UIApplication.shared.isIdleTimerDisabled = true
        let runningBlock = WorkSessionBlockSelector.currentIncompleteBlock(
            in: task.scheduledBlocks,
            at: now
        )
        scheduledBlockId = runningBlock?.id
        blockEndTarget = runningBlock?.endTime
        let ringStart: Date
        let window: Int
        if let block = runningBlock {
            // The ring is the block's own clock: empty at the block's start,
            // full at its end, regardless of when this session joined it.
            ringStart = block.startTime
            window = max(block.durationMinutes, 1) * 60
        } else {
            // Floating session: the full budget, backdated by work already
            // logged, so the ring resumes rather than resetting each session.
            // An over-budget task starts past 1 and loops — the banked lap
            // stays honest instead of stretching the denominator to hide it.
            let spentSeconds = task.timeSpentMinutes * 60
            ringStart = now.addingTimeInterval(TimeInterval(-spentSeconds))
            window = max(task.effortMinutes, 1) * 60
        }
        ringStartTime = ringStart
        ringWindowSeconds = window
        didWarnNearEnd = false
        didMarkBlockEnd = false
        immersionMessage = nil
        microGoalSeconds = microMinutes.map { $0 * 60 }
        didHitMicroGoal = false

        WorkSessionControlStore.save(
            WorkSessionControlState(
                sessionID: sessionID,
                startedAt: now,
                taskID: task.id,
                scheduledBlockID: runningBlock?.id,
                blockEndsAt: blockEndTarget,
                ringStartsAt: ringStart,
                ringEndsAt: ringStart.addingTimeInterval(TimeInterval(window))
            )
        )
        WorkSessionActivityController.start(
            sessionID: sessionID,
            taskID: task.id,
            taskTitle: task.title,
            contextName: task.context.rawValue,
            effortMinutes: task.effortMinutes,
            startedAt: now,
            blockEndsAt: blockEndTarget,
            ringStartsAt: ringStart,
            ringEndsAt: ringStart.addingTimeInterval(TimeInterval(window))
        )
    }

    /// Rebuilds the foreground timer from the App Group journal after iOS has
    /// terminated Loom in the background. The journal's wall clock remains the
    /// source of truth; presenting this view must not restart the session.
    private func rehydrateIfNeeded() {
        guard !isRunning,
              let journal = WorkSessionControlStore.load(),
              journal.taskID == task.id else { return }

        let date = Date()
        let fallbackRingStart = journal.startedAt.addingTimeInterval(
            TimeInterval(-task.timeSpentMinutes * 60)
        )
        let ringStart: Date
        let ringWindow: Int
        if let journalStart = journal.ringStartsAt,
           let journalEnd = journal.ringEndsAt,
           journalEnd > journalStart {
            ringStart = journalStart
            ringWindow = max(1, Int(journalEnd.timeIntervalSince(journalStart)))
        } else {
            ringStart = fallbackRingStart
            ringWindow = max(task.effortMinutes, 1) * 60
        }

        now = date
        activeSessionID = journal.sessionID
        sessionStart = journal.startedAt
        scheduledBlockId = journal.scheduledBlockID
        blockEndTarget = journal.blockEndsAt
        ringStartTime = ringStart
        ringWindowSeconds = ringWindow
        if let blockEnd = journal.blockEndsAt {
            didWarnNearEnd = date >= blockEnd.addingTimeInterval(-10 * 60)
            didMarkBlockEnd = date >= blockEnd
        }
        syncSharedControl(at: date)
        isRunning = true
        UIApplication.shared.isIdleTimerDisabled = true
        // Recovery deserves a word: the app just came back from a process
        // death with the timer intact, and saying so out loud is what turns
        // an invisible save into trust.
        immersionMessage = "Picked the thread right back up — nothing lost."

        if WorkSessionActivityController.isActive(sessionID: journal.sessionID) {
            WorkSessionActivityController.updateSoon(journal, at: date)
        } else {
            WorkSessionActivityController.start(
                sessionID: journal.sessionID,
                taskID: task.id,
                taskTitle: task.title,
                contextName: task.context.rawValue,
                effortMinutes: task.effortMinutes,
                startedAt: journal.startedAt,
                blockEndsAt: journal.blockEndsAt,
                ringStartsAt: ringStart,
                ringEndsAt: ringStart.addingTimeInterval(TimeInterval(ringWindow))
            )
        }
    }

    /// Worked time from the wall clock: start → now, minus paused stretches.
    private func syncElapsed(now: Date = Date()) {
        guard let start = sessionStart else { return }
        let paused = pausedAccumSeconds
            + (pauseBegan.map { Int(now.timeIntervalSince($0)) } ?? 0)
        elapsedSeconds = max(0, Int(now.timeIntervalSince(start)) - paused)
    }

    /// Pulls pause bookkeeping written by either the in-app control or the
    /// system-run Live Activity intent. The wall clock remains authoritative,
    /// so resuming the app never depends on timer publisher ticks that were
    /// skipped while it was suspended.
    private func syncSharedControl(at date: Date) {
        guard let activeSessionID,
              let control = WorkSessionControlStore.load(sessionID: activeSessionID) else {
            if !isPaused { syncElapsed(now: date) }
            return
        }

        pausedAccumSeconds = control.accumulatedPausedSeconds
        pauseBegan = control.pauseBeganAt
        elapsedSeconds = control.elapsedWorkedSeconds(at: date)
        if isPaused != control.isPaused {
            withAnimation { isPaused = control.isPaused }
        }
    }

    private func togglePause() {
        let now = Date()
        if let activeSessionID,
           var control = WorkSessionControlStore.load(sessionID: activeSessionID) {
            control.togglePause(at: now)
            WorkSessionControlStore.save(control)
            syncSharedControl(at: now)
            WorkSessionActivityController.updateSoon(control, at: now)
            return
        }

        // Defensive fallback for a damaged/missing shared snapshot. The local
        // control remains usable even when App Group persistence is unavailable.
        if isPaused {
            if let began = pauseBegan {
                pausedAccumSeconds += max(0, Int(now.timeIntervalSince(began)))
            }
            pauseBegan = nil
            isPaused = false
            syncElapsed(now: now)
        } else {
            syncElapsed(now: now)
            pauseBegan = now
            isPaused = true
        }
        if let activeSessionID, let sessionStart {
            let recovered = WorkSessionControlState(
                sessionID: activeSessionID,
                startedAt: sessionStart,
                accumulatedPausedSeconds: pausedAccumSeconds,
                pauseBeganAt: pauseBegan,
                taskID: task.id,
                scheduledBlockID: scheduledBlockId,
                blockEndsAt: blockEndTarget,
                ringStartsAt: ringStartTime,
                ringEndsAt: ringStartTime.flatMap { start in
                    ringWindowSeconds.map {
                        start.addingTimeInterval(TimeInterval($0))
                    }
                }
            )
            WorkSessionControlStore.save(recovered)
            WorkSessionActivityController.updateSoon(recovered, at: now)
        }
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
        // Commit the work log and attendance before the progress prompt. The
        // app may be backgrounded or terminated while that prompt is visible.
        guard recordSession() else { return }
        withAnimation {
            isRunning = false
            isPaused = false
            progressValue = Double(task.progressPercent)
            showProgressPrompt = true
        }
    }

    @discardableResult
    private func recordSession() -> Bool {
        if isRunning {
            syncSharedControl(at: Date())
        }
        guard elapsedSeconds > 0 else {
            finishRecordedSession()
            // A sub-second start/stop has no attendance to persist, so it is
            // already safe to finish any calendar repair that waited for the
            // timer's ownership to clear.
            PlanCoordinator.resumeDeferredBusyTimeConflictReplan(
                context: modelContext
            )
            try? modelContext.save()
            return true
        }
        let session: WorkSession
        let didCompleteLinkedBlock: Bool
        if let pendingAttendanceRecord {
            session = pendingAttendanceRecord
            session.durationSeconds = elapsedSeconds
            didCompleteLinkedBlock = pendingAttendanceCompletedLinkedBlock
        } else {
            guard let attendanceID = activeSessionID else { return false }
            let descriptor = FetchDescriptor<WorkSession>(
                predicate: #Predicate { $0.id == attendanceID }
            )
            do {
                if let existing = try modelContext.fetch(descriptor).first {
                    session = existing
                    session.task = task
                    session.startedAt = sessionStart
                        ?? Date().addingTimeInterval(-Double(elapsedSeconds))
                    session.durationSeconds = elapsedSeconds
                    session.scheduledBlockId = scheduledBlockId
                    didCompleteLinkedBlock = session.scheduledBlockId != nil
                } else {
                    session = WorkSession(
                        id: attendanceID,
                        task: task,
                        startedAt: sessionStart
                            ?? Date().addingTimeInterval(-Double(elapsedSeconds)),
                        durationSeconds: elapsedSeconds,
                        scheduledBlockId: scheduledBlockId
                    )
                    modelContext.insert(session)
                    if let scheduledBlockId,
                       let block = task.scheduledBlocks.first(where: { $0.id == scheduledBlockId }) {
                        didCompleteLinkedBlock = !block.isComplete
                        block.isComplete = true
                    } else {
                        didCompleteLinkedBlock = false
                    }
                }
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                return false
            }
            // The first step's whole job is getting the first session started;
            // once that's happened it would just be stale noise.
            task.firstStep = nil
            pendingAttendanceRecord = session
            pendingAttendanceCompletedLinkedBlock = didCompleteLinkedBlock
        }
        // Stop is a durability boundary: the session and attendance must exist
        // on disk before the optional progress step begins.
        do {
            try modelContext.save()
        } catch {
            do {
                try modelContext.save()
            } catch {
                // Keep the recovery journal, Live Activity, and foreground
                // timer intact. A later Stop can retry the pending context.
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                return false
            }
        }
        pendingAttendanceRecord = nil
        pendingAttendanceCompletedLinkedBlock = false
        finishRecordedSession()
        if didCompleteLinkedBlock {
            // Attendance consumed one reservation without changing self-
            // reported progress. Restore coverage for the unchanged remainder;
            // saving progress later may legitimately reconcile once more.
            PlanCoordinator.reconcileTaskAfterProgress(task, context: modelContext)
            try? modelContext.save()
        } else {
            PlanCoordinator.publishChange(context: modelContext)
        }
        // Google import can finish while this timer still owns its scheduled
        // block. Repair those conflicts only after the session and attendance
        // above are durable, then persist the resulting plan before returning.
        PlanCoordinator.resumeDeferredBusyTimeConflictReplan(
            context: modelContext
        )
        try? modelContext.save()
        return true
    }

    /// Shared teardown is deliberately separate from attendance mutation so a
    /// failed SwiftData save cannot erase the only recoverable session state.
    private func finishRecordedSession() {
        WorkSessionActivityController.end()
        UIApplication.shared.isIdleTimerDisabled = false
        isRunning = false
        isPaused = false
        elapsedSeconds = 0
        sessionStart = nil
        pausedAccumSeconds = 0
        pauseBegan = nil
        activeSessionID = nil
        scheduledBlockId = nil
        blockEndTarget = nil
        ringStartTime = nil
        ringWindowSeconds = nil
        microGoalSeconds = nil
    }

    private func saveProgress() {
        let reported = Int(progressValue)
        task.manualProgressPercent = max(task.manualProgressPercent, reported)
        if reported < 100 {
            PlanCoordinator.reconcileTaskAfterProgress(task, context: modelContext)
        }
        onFinish(reported >= 100)
    }
}
