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

    private static let columnHeight: CGFloat = 110

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    tapestryCard
                    statTiles
                    estimateHeatLine
                    winsSection
                }
                .padding(.bottom, 40)
            }
            .background(Color.loomBackground)
        }
    }

    private var days: [WeaveDay] {
        WeaveBuilder.days(sessions: sessions, blocks: blocks, daysBack: 14)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Two weeks of showing up")
                .font(AppFont.caption(12))
                .foregroundStyle(Color.loomSubtle)
            Text("Your Weave")
                .font(AppFont.title(26))
                .foregroundStyle(Color.loomText)
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
                    Text("Tap a day to read its thread.")
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
        .clipShape(RoundedRectangle(cornerRadius: LoomRadius.card, style: .continuous))
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }

    private func tapestry(days: [WeaveDay]) -> some View {
        let maxTotal = max(days.map(\.totalMinutes).max() ?? 0, 1)

        return VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 5) {
                ForEach(days) { day in
                    dayColumn(day, maxTotal: maxTotal)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                selectedDay = selectedDay == day ? nil : day
                            }
                        }
                }
            }
            HStack(spacing: 5) {
                ForEach(days) { day in
                    Text(weekdayLetter(day.date))
                        .font(AppFont.caption(9))
                        .foregroundStyle(
                            Calendar.current.isDateInToday(day.date)
                                ? Color.brand500
                                : Color.loomFaint
                        )
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func dayColumn(_ day: WeaveDay, maxTotal: Int) -> some View {
        VStack(spacing: 2) {
            if day.totalMinutes == 0 {
                // The bare warp: a rest day still holds the cloth together.
                Circle()
                    .fill(Color.loomSurface3)
                    .frame(width: 5, height: 5)
            } else {
                ForEach(TaskContext.allCases) { context in
                    if let minutes = day.minutesByContext[context], minutes > 0 {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(context.color.opacity(selectedDay == nil || selectedDay == day ? 1 : 0.35))
                            .frame(height: max(
                                6,
                                CGFloat(minutes) / CGFloat(maxTotal) * Self.columnHeight
                            ))
                    }
                }
            }
        }
        .frame(height: Self.columnHeight + 10, alignment: .bottom)
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
        let week = Array(days.suffix(7))
        let weekMinutes = week.reduce(0) { $0 + $1.totalMinutes }
        let weekStarts = week.reduce(0) { $0 + $1.sessionCount }
        let streak = StreakCalculator.startStreak(startDates: sessions.map(\.startedAt))

        return HStack(spacing: 10) {
            WeaveStatTile(
                value: CountdownFormatter.effortString(minutes: weekMinutes),
                label: "woven this week",
                icon: "clock.fill",
                tint: .schoolColor
            )
            WeaveStatTile(
                value: "\(weekStarts)",
                label: weekStarts == 1 ? "start this week" : "starts this week",
                icon: "play.fill",
                tint: .personalColor
            )
            WeaveStatTile(
                value: "\(streak)",
                label: streak == 1 ? "day streak" : "days streak",
                icon: "flame.fill",
                tint: .brand500
            )
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
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
    let icon: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
            Text(value)
                .font(AppFont.heading(17))
                .foregroundStyle(Color.loomText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(AppFont.caption(10))
                .foregroundStyle(Color.loomSubtle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.loomSurface)
        .clipShape(RoundedRectangle(cornerRadius: LoomRadius.card, style: .continuous))
    }
}
