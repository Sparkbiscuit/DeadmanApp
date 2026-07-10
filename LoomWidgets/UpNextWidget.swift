import WidgetKit
import SwiftUI
import SwiftData

// MARK: - Timeline

struct UpNextEntry: TimelineEntry {
    /// A row on the widget: a scheduled work block or a point-in-time reminder,
    /// merged into one chronological stream.
    struct ItemInfo: Identifiable {
        enum Kind {
            case block
            case reminder
        }

        let id: UUID
        let kind: Kind
        let title: String
        let contextName: String
        let start: Date
        let end: Date
        var taskId: UUID? = nil

        func isActive(at date: Date) -> Bool {
            kind == .block && start <= date && date < end
        }

        /// Tap target: blocks jump straight into the work session timer for
        /// their task; reminders just open the app.
        var deepLink: URL {
            if kind == .block, let taskId {
                return URL(string: "loom://start-session/\(taskId.uuidString)")
                    ?? URL(string: "loom://open")!
            }
            return URL(string: "loom://open")!
        }
    }

    let date: Date
    let items: [ItemInfo]
}

struct UpNextProvider: TimelineProvider {
    func placeholder(in context: Context) -> UpNextEntry {
        UpNextEntry(date: Date(), items: [
            .init(id: UUID(), kind: .block, title: "Finish lab report", contextName: "School",
                  start: Date().addingTimeInterval(3600), end: Date().addingTimeInterval(5400))
        ])
    }

    func getSnapshot(in context: Context, completion: @escaping (UpNextEntry) -> Void) {
        completion(fetchEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UpNextEntry>) -> Void) {
        let entry = fetchEntry()

        // Wake at the next block/reminder boundary so "Now" flips without polling.
        let now = entry.date
        var boundaries: [Date] = []
        for item in entry.items {
            if item.start > now { boundaries.append(item.start) }
            if item.end > now { boundaries.append(item.end) }
        }
        let fallback = now.addingTimeInterval(30 * 60)
        let refresh = boundaries.min().map { min($0, fallback) } ?? fallback

        completion(Timeline(entries: [entry], policy: .after(refresh)))
    }

    private func fetchEntry() -> UpNextEntry {
        let now = Date()
        guard let container = try? SharedStore.makeContainer() else {
            return UpNextEntry(date: now, items: [])
        }
        let context = ModelContext(container)

        let blockDescriptor = FetchDescriptor<ScheduledBlock>(
            sortBy: [SortDescriptor(\ScheduledBlock.startTime)]
        )
        let blocks = ((try? context.fetch(blockDescriptor)) ?? [])
            .filter { block in
                guard !block.isComplete, block.endTime > now else { return false }
                guard let task = block.task, !task.isComplete else { return false }
                return true
            }
            .map { block in
                UpNextEntry.ItemInfo(
                    id: block.id,
                    kind: .block,
                    title: block.task?.title ?? "Task",
                    contextName: block.task?.context.rawValue ?? "",
                    start: block.startTime,
                    end: block.endTime,
                    taskId: block.task?.id
                )
            }

        let reminderDescriptor = FetchDescriptor<Reminder>(
            sortBy: [SortDescriptor(\Reminder.dueDate)]
        )
        let reminders = ((try? context.fetch(reminderDescriptor)) ?? [])
            .filter { !$0.isComplete && $0.dueDate > now }
            .map { reminder in
                UpNextEntry.ItemInfo(
                    id: reminder.id,
                    kind: .reminder,
                    title: reminder.title,
                    contextName: "",
                    start: reminder.dueDate,
                    end: reminder.dueDate
                )
            }

        let items = (blocks + reminders)
            .sorted { $0.start < $1.start }
            .prefix(4)

        return UpNextEntry(date: now, items: Array(items))
    }
}

// MARK: - Widget

/// Home Screen / Lock Screen glance at the next scheduled blocks. Styled with
/// the app's own palette and type so it reads as Loom, and adapts to
/// light/dark like a native widget.
struct UpNextWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "UpNextWidget", provider: UpNextProvider()) { entry in
            UpNextWidgetView(entry: entry)
        }
        .configurationDisplayName("Up Next")
        .description("Your next work blocks and reminders at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}

// MARK: - Views

private func widgetContextColor(_ name: String) -> Color {
    TaskContext(rawValue: name)?.color ?? .brand500
}

private struct UpNextWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UpNextEntry

    var body: some View {
        switch family {
        case .accessoryInline:
            inlineView
        case .accessoryRectangular:
            rectangularView
        case .systemMedium:
            mediumView
        default:
            smallView
        }
    }

    private var next: UpNextEntry.ItemInfo? { entry.items.first }

    private func timeLabel(_ item: UpNextEntry.ItemInfo) -> String {
        if item.kind == .reminder {
            return TimeFormatter.clock.string(from: item.start)
        }
        return "\(TimeFormatter.clock.string(from: item.start)) – \(TimeFormatter.clock.string(from: item.end))"
    }

    private func itemColor(_ item: UpNextEntry.ItemInfo) -> Color {
        item.kind == .reminder ? .brand500 : widgetContextColor(item.contextName)
    }

    private func itemLabel(_ item: UpNextEntry.ItemInfo) -> String {
        if item.kind == .reminder { return "REMINDER" }
        return item.isActive(at: entry.date) ? "NOW" : "UP NEXT"
    }

    // MARK: Home Screen

    private var smallView: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let item = next {
                let color = itemColor(item)

                HStack(spacing: 5) {
                    if item.kind == .reminder {
                        Image(systemName: "bell.fill")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(color)
                    } else {
                        Circle()
                            .fill(color)
                            .frame(width: 7, height: 7)
                    }
                    Text(itemLabel(item))
                        .font(AppFont.caption(10))
                        .foregroundStyle(color)
                        .kerning(0.5)
                }
                .padding(.bottom, 6)

                Text(item.title)
                    .font(AppFont.heading(15))
                    .foregroundStyle(Color.loomText)
                    .lineLimit(2)
                    .padding(.bottom, 3)

                Text(timeLabel(item))
                    .font(AppFont.monoMedium(11))
                    .foregroundStyle(Color.loomSubtle)

                Spacer(minLength: 0)

                HStack(spacing: 4) {
                    if item.kind == .block {
                        // One tap from Home Screen to a running timer.
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(color)
                        Text("Start")
                            .font(AppFont.caption(11))
                            .foregroundStyle(color)
                    }
                    Spacer(minLength: 0)
                    if entry.items.count > 1 {
                        Text("+\(entry.items.count - 1) more")
                            .font(AppFont.caption(10))
                            .foregroundStyle(Color.loomFaint)
                    }
                }
            } else {
                emptyView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(next?.deepLink)
        .containerBackground(Color.loomSurface, for: .widget)
    }

    private var mediumView: some View {
        VStack(alignment: .leading, spacing: 9) {
            if entry.items.isEmpty {
                emptyView
            } else {
                ForEach(entry.items.prefix(3)) { item in
                    let color = itemColor(item)
                    Link(destination: item.deepLink) {
                        HStack(spacing: 10) {
                            Text(TimeFormatter.clock.string(from: item.start))
                                .font(AppFont.monoMedium(11))
                                .foregroundStyle(Color.loomSubtle)
                                .frame(width: 62, alignment: .trailing)

                            RoundedRectangle(cornerRadius: 2)
                                .fill(color)
                                .frame(width: 3, height: 26)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.title)
                                    .font(AppFont.heading(13))
                                    .foregroundStyle(Color.loomText)
                                    .lineLimit(1)
                                if item.kind == .reminder {
                                    HStack(spacing: 3) {
                                        Image(systemName: "bell.fill")
                                            .font(.system(size: 7, weight: .semibold))
                                        Text("Reminder")
                                            .font(AppFont.caption(10))
                                    }
                                    .foregroundStyle(color)
                                } else {
                                    Text(item.contextName)
                                        .font(AppFont.caption(10))
                                        .foregroundStyle(color)
                                }
                            }

                            Spacer(minLength: 0)

                            if item.isActive(at: entry.date) {
                                Text("NOW")
                                    .font(AppFont.caption(9))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(color, in: Capsule())
                            }
                            if item.kind == .block {
                                Image(systemName: "play.circle.fill")
                                    .font(.system(size: 17))
                                    .foregroundStyle(color)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(Color.loomSurface, for: .widget)
    }

    private var emptyView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ALL CLEAR")
                .font(AppFont.caption(10))
                .foregroundStyle(Color.loomFaint)
                .kerning(0.5)
            Text("Nothing scheduled")
                .font(AppFont.heading(14))
                .foregroundStyle(Color.loomText)
            Spacer(minLength: 0)
        }
    }

    // MARK: Lock Screen

    private var rectangularView: some View {
        Group {
            if let item = next {
                VStack(alignment: .leading, spacing: 1) {
                    Text(itemLabel(item))
                        .font(AppFont.caption(10))
                        .widgetAccentable()
                    Text(item.title)
                        .font(AppFont.heading(14))
                        .lineLimit(1)
                    Text(timeLabel(item))
                        .font(AppFont.monoMedium(11))
                        .opacity(0.7)
                }
            } else {
                Text("Loom: nothing scheduled")
                    .font(AppFont.bodySemibold(13))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(next?.deepLink)
        .containerBackground(.clear, for: .widget)
    }

    private var inlineView: some View {
        Group {
            if let item = next {
                Text("\(item.isActive(at: entry.date) ? "Now" : TimeFormatter.clock.string(from: item.start)): \(item.title)")
            } else {
                Text("Loom: all clear")
            }
        }
        .widgetURL(next?.deepLink)
        .containerBackground(.clear, for: .widget)
    }
}
