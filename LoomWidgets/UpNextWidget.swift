import WidgetKit
import SwiftUI
import SwiftData

// MARK: - Timeline

struct UpNextEntry: TimelineEntry {
    struct BlockInfo: Identifiable {
        let id: UUID
        let title: String
        let contextName: String
        let start: Date
        let end: Date

        func isActive(at date: Date) -> Bool {
            start <= date && date < end
        }
    }

    let date: Date
    let blocks: [BlockInfo]
}

struct UpNextProvider: TimelineProvider {
    func placeholder(in context: Context) -> UpNextEntry {
        UpNextEntry(date: Date(), blocks: [
            .init(id: UUID(), title: "Finish lab report", contextName: "School",
                  start: Date().addingTimeInterval(3600), end: Date().addingTimeInterval(5400))
        ])
    }

    func getSnapshot(in context: Context, completion: @escaping (UpNextEntry) -> Void) {
        completion(fetchEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UpNextEntry>) -> Void) {
        let entry = fetchEntry()

        // Wake at the next block boundary so "Now" flips without polling.
        let now = entry.date
        var boundaries: [Date] = []
        for block in entry.blocks {
            if block.start > now { boundaries.append(block.start) }
            if block.end > now { boundaries.append(block.end) }
        }
        let fallback = now.addingTimeInterval(30 * 60)
        let refresh = boundaries.min().map { min($0, fallback) } ?? fallback

        completion(Timeline(entries: [entry], policy: .after(refresh)))
    }

    private func fetchEntry() -> UpNextEntry {
        let now = Date()
        guard let container = try? SharedStore.makeContainer() else {
            return UpNextEntry(date: now, blocks: [])
        }
        let context = ModelContext(container)

        let descriptor = FetchDescriptor<ScheduledBlock>(
            sortBy: [SortDescriptor(\ScheduledBlock.startTime)]
        )
        let blocks = ((try? context.fetch(descriptor)) ?? [])
            .filter { block in
                guard !block.isComplete, block.endTime > now else { return false }
                guard let task = block.task, !task.isComplete else { return false }
                return true
            }
            .prefix(4)
            .map { block in
                UpNextEntry.BlockInfo(
                    id: block.id,
                    title: block.task?.title ?? "Task",
                    contextName: block.task?.context.rawValue ?? "",
                    start: block.startTime,
                    end: block.endTime
                )
            }

        return UpNextEntry(date: now, blocks: Array(blocks))
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
        .description("Your next scheduled work blocks at a glance.")
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

    private var next: UpNextEntry.BlockInfo? { entry.blocks.first }

    private func timeRange(_ block: UpNextEntry.BlockInfo) -> String {
        "\(TimeFormatter.clock.string(from: block.start)) – \(TimeFormatter.clock.string(from: block.end))"
    }

    // MARK: Home Screen

    private var smallView: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let block = next {
                let color = widgetContextColor(block.contextName)
                let active = block.isActive(at: entry.date)

                HStack(spacing: 5) {
                    Circle()
                        .fill(color)
                        .frame(width: 7, height: 7)
                    Text(active ? "NOW" : "UP NEXT")
                        .font(AppFont.caption(10))
                        .foregroundStyle(color)
                        .kerning(0.5)
                }
                .padding(.bottom, 6)

                Text(block.title)
                    .font(AppFont.heading(15))
                    .foregroundStyle(Color.loomText)
                    .lineLimit(2)
                    .padding(.bottom, 3)

                Text(timeRange(block))
                    .font(AppFont.monoMedium(11))
                    .foregroundStyle(Color.loomSubtle)

                Spacer(minLength: 0)

                if entry.blocks.count > 1 {
                    Text("+\(entry.blocks.count - 1) more coming up")
                        .font(AppFont.caption(10))
                        .foregroundStyle(Color.loomFaint)
                }
            } else {
                emptyView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(Color.loomSurface, for: .widget)
    }

    private var mediumView: some View {
        VStack(alignment: .leading, spacing: 9) {
            if entry.blocks.isEmpty {
                emptyView
            } else {
                ForEach(entry.blocks.prefix(3)) { block in
                    let color = widgetContextColor(block.contextName)
                    HStack(spacing: 10) {
                        Text(TimeFormatter.clock.string(from: block.start))
                            .font(AppFont.monoMedium(11))
                            .foregroundStyle(Color.loomSubtle)
                            .frame(width: 62, alignment: .trailing)

                        RoundedRectangle(cornerRadius: 2)
                            .fill(color)
                            .frame(width: 3, height: 26)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(block.title)
                                .font(AppFont.heading(13))
                                .foregroundStyle(Color.loomText)
                                .lineLimit(1)
                            Text(block.contextName)
                                .font(AppFont.caption(10))
                                .foregroundStyle(color)
                        }

                        Spacer(minLength: 0)

                        if block.isActive(at: entry.date) {
                            Text("NOW")
                                .font(AppFont.caption(9))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(color, in: Capsule())
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
            if let block = next {
                VStack(alignment: .leading, spacing: 1) {
                    Text(block.isActive(at: entry.date) ? "NOW" : "UP NEXT")
                        .font(AppFont.caption(10))
                        .widgetAccentable()
                    Text(block.title)
                        .font(AppFont.heading(14))
                        .lineLimit(1)
                    Text(timeRange(block))
                        .font(AppFont.monoMedium(11))
                        .opacity(0.7)
                }
            } else {
                Text("Loom: nothing scheduled")
                    .font(AppFont.bodySemibold(13))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .containerBackground(.clear, for: .widget)
    }

    private var inlineView: some View {
        Group {
            if let block = next {
                Text("\(block.isActive(at: entry.date) ? "Now" : TimeFormatter.clock.string(from: block.start)): \(block.title)")
            } else {
                Text("Loom: all clear")
            }
        }
        .containerBackground(.clear, for: .widget)
    }
}
