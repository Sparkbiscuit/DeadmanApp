import WidgetKit
import SwiftUI
import SwiftData

// MARK: - Timeline

struct TodayEntry: TimelineEntry {
    let date: Date
    let doneBlocks: Int
    let totalBlocks: Int
    let nextTitle: String?
    let nextStart: Date?
    let nextTaskId: UUID?
    let streakDays: Int

    var allDone: Bool { totalBlocks > 0 && doneBlocks >= totalBlocks }
}

struct TodayProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodayEntry {
        TodayEntry(
            date: Date(),
            doneBlocks: 1,
            totalBlocks: 3,
            nextTitle: "Finish lab report",
            nextStart: Date().addingTimeInterval(3600),
            nextTaskId: nil,
            streakDays: 4
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (TodayEntry) -> Void) {
        completion(fetchEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayEntry>) -> Void) {
        let entry = fetchEntry()
        let now = entry.date
        var boundaries: [Date] = []
        if let start = entry.nextStart, start > now { boundaries.append(start) }
        let fallback = now.addingTimeInterval(30 * 60)
        let refresh = boundaries.min().map { min($0, fallback) } ?? fallback
        completion(Timeline(entries: [entry], policy: .after(refresh)))
    }

    private func fetchEntry() -> TodayEntry {
        let now = Date()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        guard let container = try? SharedStore.makeContainer(),
              let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else {
            return TodayEntry(
                date: now, doneBlocks: 0, totalBlocks: 0,
                nextTitle: nil, nextStart: nil, nextTaskId: nil, streakDays: 0
            )
        }
        let context = ModelContext(container)

        // Today's work: checked blocks stay countable even after their task
        // completes (the work happened); unchecked blocks of completed tasks
        // don't linger — they're removed on completion.
        let todayBlocks = ((try? context.fetch(FetchDescriptor<ScheduledBlock>())) ?? [])
            .filter { block in
                guard let task = block.task,
                      block.startTime >= today, block.startTime < tomorrow else { return false }
                return block.isComplete || !task.isComplete
            }
        let done = todayBlocks.filter(\.isComplete).count

        let next = todayBlocks
            .filter { block in
                guard let task = block.task else { return false }
                return !block.isComplete && !task.isComplete && block.endTime > now
            }
            .min { $0.startTime < $1.startTime }

        let sessions = (try? context.fetch(FetchDescriptor<WorkSession>())) ?? []
        let streak = StreakCalculator.startStreak(startDates: sessions.map(\.startedAt), now: now)

        return TodayEntry(
            date: now,
            doneBlocks: done,
            totalBlocks: todayBlocks.count,
            nextTitle: next?.task?.title,
            nextStart: next?.startTime,
            nextTaskId: next?.task?.id,
            streakDays: streak
        )
    }
}

// MARK: - Widget

/// Today at a glance: blocks done vs planned, the next one up, and the start
/// streak — the day's shape without opening anything. The Lock Screen ring is
/// the anti-time-blindness dial.
struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TodayWidget", provider: TodayProvider()) { entry in
            TodayWidgetView(entry: entry)
        }
        .configurationDisplayName("Today")
        .description("Blocks done today, what's next, and your start streak.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryInline])
    }
}

// MARK: - Views

private struct TodayWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TodayEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            circularView
        case .accessoryInline:
            inlineView
        default:
            smallView
        }
    }

    private var deepLink: URL {
        if let taskId = entry.nextTaskId {
            return URL(string: "loom://start-session/\(taskId.uuidString)")
                ?? URL(string: "loom://open")!
        }
        return URL(string: "loom://open")!
    }

    // MARK: Lock Screen

    private var circularView: some View {
        Group {
            if entry.totalBlocks > 0 {
                Gauge(
                    value: Double(entry.doneBlocks),
                    in: 0...Double(entry.totalBlocks)
                ) {
                    Image(systemName: "circle.hexagongrid.fill")
                } currentValueLabel: {
                    Text("\(entry.doneBlocks)/\(entry.totalBlocks)")
                        .font(AppFont.heading(15))
                }
                .gaugeStyle(.accessoryCircularCapacity)
            } else {
                ZStack {
                    AccessoryWidgetBackground()
                    VStack(spacing: 1) {
                        Image(systemName: "flame.fill")
                            .font(.system(size: 14, weight: .semibold))
                        Text("\(entry.streakDays)")
                            .font(AppFont.heading(15))
                    }
                }
            }
        }
        .widgetURL(deepLink)
        .containerBackground(.clear, for: .widget)
    }

    private var inlineView: some View {
        Group {
            if entry.allDone {
                Text("Loom: today all woven")
            } else if entry.totalBlocks > 0 {
                Text("Loom: \(entry.doneBlocks)/\(entry.totalBlocks) blocks done")
            } else {
                Text("Loom: nothing scheduled")
            }
        }
        .widgetURL(deepLink)
        .containerBackground(.clear, for: .widget)
    }

    // MARK: Home Screen

    private var smallView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                // Mini flame ring: blocks done vs planned.
                ZStack {
                    HearthProgressRing(
                        progress: entry.totalBlocks > 0
                            ? Double(entry.doneBlocks) / Double(entry.totalBlocks)
                            : 0,
                        size: 44,
                        lineWidth: 5
                    )
                    Text("\(entry.doneBlocks)/\(entry.totalBlocks)")
                        .font(AppFont.mono(11))
                        .foregroundStyle(Color.loomText)
                        .minimumScaleFactor(0.7)
                }
                .frame(width: 48, height: 48)

                Spacer()

                if entry.streakDays >= 2 {
                    HStack(spacing: 3) {
                        Image(systemName: "flame.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color.brand300)
                        Text("\(entry.streakDays)")
                            .font(AppFont.mono(11))
                            .foregroundStyle(Color.brand100)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.brand500.opacity(0.14), in: Capsule())
                    .overlay(Capsule().stroke(Color.brand500.opacity(0.35), lineWidth: 1))
                }
            }

            Spacer(minLength: 4)

            if entry.allDone {
                Text("All woven for today.")
                    .font(AppFont.cardTitle(13))
                    .foregroundStyle(Color.personalDisplay)
            } else if let title = entry.nextTitle, let start = entry.nextStart {
                VStack(alignment: .leading, spacing: 1) {
                    Text("NEXT · \(TimeFormatter.clock.string(from: start))")
                        .font(AppFont.caption(9))
                        .foregroundStyle(Color.brand300)
                        .kerning(0.5)
                    Text(title)
                        .font(AppFont.cardTitle(13))
                        .foregroundStyle(Color.loomText)
                        .lineLimit(2)
                    let left = entry.totalBlocks - entry.doneBlocks
                    Text(left == 1 ? "1 block left today" : "\(left) blocks left today")
                        .font(AppFont.caption(10))
                        .foregroundStyle(Color.loomSubtle)
                }
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Nothing scheduled")
                        .font(AppFont.cardTitle(13))
                        .foregroundStyle(Color.loomText)
                    Text("A clear day is a valid plan.")
                        .font(AppFont.caption(10))
                        .foregroundStyle(Color.loomSubtle)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.colorScheme, .dark)
        .widgetURL(deepLink)
        .containerBackground(for: .widget) {
            HearthWidgetBackground()
        }
    }
}

// MARK: - Widget backdrop

/// Dark hearth surface with a faint accent glow — the widget-sized version of
/// the app's ambient background. Widgets always render the dark look; the
/// dark environment override upstream keeps adaptive text legible on it.
struct HearthWidgetBackground: View {
    var body: some View {
        ZStack {
            Color(hex: 0x19191D)
            RadialGradient(
                colors: [Color.brand500.opacity(0.16), .clear],
                center: UnitPoint(x: 0.85, y: -0.1),
                startRadius: 0,
                endRadius: 220
            )
        }
    }
}
