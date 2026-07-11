import SwiftUI
import SwiftData

// MARK: - Weave data

/// One day of the tapestry: how much thread each context contributed.
struct WeaveDay: Identifiable, Equatable {
    let date: Date
    let minutesByContext: [TaskContext: Int]
    let sessionCount: Int

    var id: Date { date }
    var totalMinutes: Int { minutesByContext.values.reduce(0, +) }
}

/// Pure aggregation for the Weave tab, kept separate from the view so the
/// math is testable.
struct WeaveBuilder {

    /// The last `daysBack` days, oldest first. Worked time follows the same
    /// convention as `timeSpentMinutes`: timed sessions plus checked-off
    /// blocks, attributed to the day they started.
    static func days(
        sessions: [WorkSession],
        blocks: [ScheduledBlock],
        daysBack: Int,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [WeaveDay] {
        let today = calendar.startOfDay(for: now)
        var result: [WeaveDay] = []
        for offset in stride(from: daysBack - 1, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            var minutes: [TaskContext: Int] = [:]
            var sessionCount = 0
            for session in sessions where calendar.isDate(session.startedAt, inSameDayAs: day) {
                guard let context = session.task?.context else { continue }
                minutes[context, default: 0] += (session.durationSeconds + 30) / 60
                sessionCount += 1
            }
            for block in blocks where block.isComplete && calendar.isDate(block.startTime, inSameDayAs: day) {
                guard let context = block.task?.context else { continue }
                minutes[context, default: 0] += block.durationMinutes
            }
            result.append(WeaveDay(date: day, minutesByContext: minutes, sessionCount: sessionCount))
        }
        return result
    }

    /// Median actual÷planned ratio over the most recent tracked completions,
    /// across all contexts — the app-wide "how hot do my estimates run"
    /// number. Nil under 3 samples.
    static func estimateHeat(tasks: [LoomTask], sampleLimit: Int = 10) -> Double? {
        let ratios = tasks
            .filter { $0.isComplete && $0.effortMinutes > 0 && $0.timeSpentMinutes > 0 }
            .sorted { ($0.completedAt ?? $0.deadline) > ($1.completedAt ?? $1.deadline) }
            .prefix(sampleLimit)
            .map { Double($0.timeSpentMinutes) / Double($0.effortMinutes) }
            .sorted()
        guard ratios.count >= 3 else { return nil }
        return ratios.count.isMultiple(of: 2)
            ? (ratios[ratios.count / 2 - 1] + ratios[ratios.count / 2]) / 2
            : ratios[ratios.count / 2]
    }
}

// MARK: - Weave view

/// The reflection surface: two weeks of showing up, rendered as woven thread.
/// ADHD brains rarely get to *see* their own accumulation — every day the
/// work evaporates behind the next deadline. The tapestry makes the fabric
/// visible: colored threads for worked time, a bare warp dot for rest days
/// (rest days hold the cloth together; they are not gaps).
struct WeaveView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var sessions: [WorkSession]
    @Query private var tasks: [LoomTask]
    @Query private var blocks: [ScheduledBlock]

    @State private var selectedDay: WeaveDay?

    // One-shot reveal state: bars grow in staggered, then a band of light
    // sweeps across the finished cloth. Plays once per visit to the tab.
    @State private var barsRevealed = false
    @State private var sweepProgress: CGFloat = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let columnHeight: CGFloat = 130

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    tapestryCard
                    statTiles
                    threadsCard
                    estimateHeatLine
                    winsSection
                }
                .padding(.bottom, 110)
            }
            .hearthScreen()
        }
        .onAppear(perform: playReveal)
    }

    /// The "just wove itself" reveal — bars rise (recent days first), then a
    /// single diagonal light pass. Reduce Motion skips straight to the woven
    /// state.
    private func playReveal() {
        guard !barsRevealed else { return }
        if reduceMotion {
            barsRevealed = true
            return
        }
        barsRevealed = true // animations hang off this via per-column delays
        withAnimation(.easeInOut(duration: 3.8).delay(1.1)) {
            sweepProgress = 1
        }
    }

    private var days: [WeaveDay] {
        WeaveBuilder.days(sessions: sessions, blocks: blocks, daysBack: 14)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Two weeks of showing up")
                .font(AppFont.caption(13))
                .foregroundStyle(Color.brand300)
            HearthTitle(text: "Your Weave", size: 30)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    // MARK: Tapestry

    private var tapestryCard: some View {
        let days = self.days
        let hasAnyThread = days.contains { $0.totalMinutes > 0 }

        return VStack(alignment: .leading, spacing: 12) {
            if hasAnyThread {
                tapestry(days: days)

                if let day = selectedDay {
                    Text(detailLine(for: day))
                        .font(AppFont.body(12))
                        .foregroundStyle(Color.loomSubtle)
                        .transition(.opacity)
                } else {
                    Text("Tap a day to read its thread. Rest days hold the cloth together.")
                        .font(AppFont.caption(11))
                        .foregroundStyle(Color.loomFaint)
                }
            } else {
                EmptyStateView(
                    icon: "square.grid.3x3.fill",
                    title: "The loom is warped and ready",
                    subtitle: "The first thread lands with your first work session. Nothing here is behind — it just hasn't started."
                )
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(Color.loomSurface)
        .clipShape(RoundedRectangle(cornerRadius: LoomRadius.hero, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: LoomRadius.hero, style: .continuous)
                .stroke(Color.loomBorder, lineWidth: 1)
        )
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }

    private func tapestry(days: [WeaveDay]) -> some View {
        let maxTotal = max(days.map(\.totalMinutes).max() ?? 0, 1)

        return VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 5) {
                ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                    dayColumn(day, index: index, count: days.count, maxTotal: maxTotal)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                selectedDay = selectedDay == day ? nil : day
                            }
                        }
                }
            }
            .background(gridLines)
            .overlay(lightSweep)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            HStack(spacing: 5) {
                ForEach(days) { day in
                    Text(weekdayLetter(day.date))
                        .font(AppFont.caption(9))
                        .foregroundStyle(
                            Calendar.current.isDateInToday(day.date)
                                ? Color.brand300
                                : Color.loomFaint
                        )
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    /// The warp behind the weft: faint grid lines the cloth hangs on.
    private var gridLines: some View {
        Canvas { context, size in
            let line = Color.white.opacity(0.045)
            let columns = 14
            let step = size.width / CGFloat(columns)
            for i in 0...columns {
                let x = CGFloat(i) * step
                context.stroke(
                    Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: size.height)) },
                    with: .color(line), lineWidth: 1
                )
            }
            var y: CGFloat = size.height
            while y > 0 {
                context.stroke(
                    Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: size.width, y: y)) },
                    with: .color(line), lineWidth: 1
                )
                y -= 22
            }
        }
    }

    /// The one-time diagonal band of light that crosses the finished cloth.
    private var lightSweep: some View {
        GeometryReader { geo in
            let travel = geo.size.width + 160
            LinearGradient(
                colors: [.clear, Color.brand300.opacity(0.16), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 120)
            .rotationEffect(.degrees(16))
            .offset(x: -140 + sweepProgress * travel)
            .blendMode(.plusLighter)
        }
        .allowsHitTesting(false)
    }

    private func dayColumn(_ day: WeaveDay, index: Int, count: Int, maxTotal: Int) -> some View {
        let isToday = Calendar.current.isDateInToday(day.date)
        // Recent days land first; the far past finishes the weave.
        let revealDelay = 0.05 + Double(count - 1 - index) * 0.06

        return VStack(spacing: 3) {
            if day.totalMinutes == 0 {
                // The bare warp: a rest day still holds the cloth together.
                Circle()
                    .fill(Color.loomSurface3)
                    .frame(width: 5, height: 5)
            } else {
                ForEach(TaskContext.allCases) { context in
                    if let minutes = day.minutesByContext[context], minutes > 0 {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(barFill(context: context, isToday: isToday))
                            .frame(height: max(
                                12,
                                CGFloat(minutes) / CGFloat(maxTotal) * Self.columnHeight
                            ))
                            .opacity(selectedDay == nil || selectedDay == day ? 1 : 0.35)
                    }
                }
            }
        }
        .frame(height: Self.columnHeight + 10, alignment: .bottom)
        .scaleEffect(y: barsRevealed ? 1 : 0.001, anchor: .bottom)
        .animation(
            reduceMotion
                ? nil
                : .spring(response: 0.55, dampingFraction: 0.62).delay(revealDelay),
            value: barsRevealed
        )
        .background(alignment: .bottom) {
            if isToday {
                // Today's column glows from within.
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.brand500.opacity(0.12))
                    .frame(height: Self.columnHeight + 10)
                    .hearthGlow(.brand500, radius: 12, opacity: 0.35)
            }
        }
    }

    private func barFill(context: TaskContext, isToday: Bool) -> AnyShapeStyle {
        if isToday {
            return AnyShapeStyle(LinearGradient.hearth)
        }
        return AnyShapeStyle(context.color)
    }

    private func weekdayLetter(_ date: Date) -> String {
        String(TimeFormatter.dayOfWeek.string(from: date).prefix(1))
    }

    private func detailLine(for day: WeaveDay) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, MMM d"
        let name = Calendar.current.isDateInToday(day.date) ? "Today" : formatter.string(from: day.date)
        guard day.totalMinutes > 0 else {
            return "\(name): a rest day. The warp holds."
        }
        let parts = TaskContext.allCases
            .compactMap { context -> String? in
                guard let minutes = day.minutesByContext[context], minutes > 0 else { return nil }
                return "\(context.rawValue) \(CountdownFormatter.effortString(minutes: minutes))"
            }
            .joined(separator: " · ")
        let starts = day.sessionCount > 0
            ? " — \(day.sessionCount == 1 ? "1 start" : "\(day.sessionCount) starts")"
            : ""
        return "\(name): \(CountdownFormatter.effortString(minutes: day.totalMinutes)) woven. \(parts)\(starts)"
    }

    // MARK: Stat tiles

    private var statTiles: some View {
        let all = days
        let totalMinutes = all.reduce(0) { $0 + $1.totalMinutes }
        let totalStarts = all.reduce(0) { $0 + $1.sessionCount }
        let streak = StreakCalculator.startStreak(startDates: sessions.map(\.startedAt))

        return HStack(spacing: 10) {
            WeaveStatTile(
                value: CountdownFormatter.effortString(minutes: totalMinutes),
                label: "woven",
                tint: .loomText
            )
            WeaveStatTile(
                value: "\(totalStarts)",
                label: totalStarts == 1 ? "session" : "sessions",
                tint: .loomText
            )
            WeaveStatTile(
                value: "\(streak)",
                label: "day streak",
                tint: .personalDisplay
            )
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }

    // MARK: - This week's threads

    /// One or two specific, true things worth saying out loud — generated
    /// from the record, never canned praise.
    @ViewBuilder
    private var threadsCard: some View {
        let lines = threadLines
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("THIS WEEK'S THREADS")
                    .font(AppFont.caption(11))
                    .foregroundStyle(Color.brand300)
                    .kerning(1.4)

                ForEach(lines, id: \.self) { line in
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color.personalDisplay)
                            .padding(.top, 2)
                        Text(line)
                            .font(AppFont.bodySemibold(14))
                            .foregroundStyle(Color.loomText)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.loomSurface)
            .clipShape(RoundedRectangle(cornerRadius: LoomRadius.group, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: LoomRadius.group, style: .continuous)
                    .stroke(Color.brand500.opacity(0.18), lineWidth: 1)
            )
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
    }

    private var threadLines: [String] {
        var lines: [String] = []
        let calendar = Calendar.current
        let now = Date()
        guard let weekAgo = calendar.date(byAdding: .day, value: -7, to: now) else { return lines }

        // Most recent task finished ahead of its deadline.
        if let earlyWin = tasks
            .filter({ $0.isComplete })
            .compactMap({ task -> (LoomTask, Date)? in
                guard let done = task.completedAt, done >= weekAgo, done < task.deadline else { return nil }
                return (task, done)
            })
            .max(by: { $0.1 < $1.1 }) {
            let lead = earlyWin.0.deadline.timeIntervalSince(earlyWin.1)
            let leadLabel: String
            if lead >= 172_800 { leadLabel = "\(Int(lead) / 86_400) days early" }
            else if lead >= 86_400 { leadLabel = "a day early" }
            else if lead >= 3600 { leadLabel = "\(Int(lead) / 3600)h early" }
            else { leadLabel = "ahead of the deadline" }
            lines.append("Finished \(earlyWin.0.title) \(leadLabel)")
        }

        // Attendance: of the last 7 days that had planned blocks, how many
        // saw you actually show up (a session started that day).
        let weekDays = (0..<7).compactMap {
            calendar.date(byAdding: .day, value: -$0, to: calendar.startOfDay(for: now))
        }
        let plannedDays = weekDays.filter { day in
            blocks.contains { calendar.isDate($0.startTime, inSameDayAs: day) }
        }
        if plannedDays.count >= 2 {
            let showedUp = plannedDays.filter { day in
                sessions.contains { calendar.isDate($0.startedAt, inSameDayAs: day) }
            }.count
            if showedUp > 0 {
                lines.append("Showed up \(showedUp) of \(plannedDays.count) planned days")
            }
        }

        return Array(lines.prefix(2))
    }

    // MARK: Estimate heat

    @ViewBuilder
    private var estimateHeatLine: some View {
        if let heat = WeaveBuilder.estimateHeat(tasks: tasks) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "thermometer.medium")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(heat >= 1.2 ? Color.workColor : Color.personalColor)
                    .padding(.top, 1)
                Text(heatLine(heat))
                    .font(AppFont.body(13))
                    .foregroundStyle(Color.loomText)
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(Color.loomSurface)
            .clipShape(RoundedRectangle(cornerRadius: LoomRadius.card, style: .continuous))
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
    }

    private func heatLine(_ heat: Double) -> String {
        if heat >= 1.2 {
            return String(format: "Your estimates have run about %.1f× hot lately. Capture already nudges them — accepting the nudge is free honesty.", heat)
        } else if heat <= 0.85 {
            return String(format: "Your estimates run cool (%.1f×) — you finish faster than you plan. You've earned some slack.", heat)
        }
        return "Your estimates have been honest lately. That's rare, and it makes every plan below trustworthy."
    }

    // MARK: Wins

    @ViewBuilder
    private var winsSection: some View {
        let calendar = Calendar.current
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        let wins = tasks
            .filter { $0.isComplete && ($0.completedAt ?? .distantPast) >= weekAgo }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }

        if !wins.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.personalColor)
                    Text("Finished this week")
                        .font(AppFont.heading(15))
                        .foregroundStyle(Color.loomText)
                    Text("\(wins.count)")
                        .font(AppFont.caption(12))
                        .foregroundStyle(Color.loomFaint)
                    Spacer()
                }

                ForEach(wins) { task in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(task.context.color)
                            .frame(width: 7, height: 7)
                        Text(task.title)
                            .font(AppFont.bodySemibold(14))
                            .foregroundStyle(Color.loomText)
                            .lineLimit(1)
                        Spacer()
                        if task.timeSpentMinutes > 0 {
                            Text(CountdownFormatter.effortString(minutes: task.timeSpentMinutes))
                                .font(AppFont.monoMedium(11))
                                .foregroundStyle(Color.loomSubtle)
                        }
                    }
                }
            }
            .padding(16)
            .background(Color.loomSurface)
            .clipShape(RoundedRectangle(cornerRadius: LoomRadius.card, style: .continuous))
            .padding(.horizontal, 20)
        }
    }
}

// MARK: - Stat tile

private struct WeaveStatTile: View {
    let value: String
    let label: String
    let tint: Color

    var body: some View {
        VStack(spacing: 3) {
            Text(value)
                .font(AppFont.mono(20))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(AppFont.caption(11))
                .foregroundStyle(Color.loomSubtle)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(Color.loomSurface)
        .clipShape(RoundedRectangle(cornerRadius: LoomRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: LoomRadius.card, style: .continuous)
                .stroke(Color.loomBorder, lineWidth: 1)
        )
    }
}
