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

/// Home Screen / Lock Screen glance at the next scheduled blocks.
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

private func contextColor(_ name: String) -> Color {
    switch name {
    case "School": return Color(red: 0x5A / 255, green: 0x78 / 255, blue: 0xE0 / 255)
    case "Work": return Color(red: 0xE0 / 255, green: 0xA0 / 255, blue: 0x20 / 255)
    case "Personal": return Color(red: 0x3F / 255, green: 0xA3 / 255, blue: 0x72 / 255)
    default: return Color(red: 0xC1 / 255, green: 0x57 / 255, blue: 0x1F / 255)
    }
}

private let widgetBackground = Color(red: 0.11, green: 0.11, blue: 0.12)

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
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return "\(formatter.string(from: block.start)) – \(formatter.string(from: block.end))"
    }

    private func statusLabel(_ block: UpNextEntry.BlockInfo) -> String {
        block.isActive(at: entry.date) ? "Now" : "Up next"
    }

    // MARK: Home Screen

    private var smallView: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let block = next {
                Text(statusLabel(block).uppercased())
                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                    .foregroundStyle(contextColor(block.contextName))
                Text(block.title)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Text(timeRange(block))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer(minLength: 0)
                if entry.blocks.count > 1 {
                    Text("+\(entry.blocks.count - 1) more today")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.45))
                }
            } else {
                emptyView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(widgetBackground, for: .widget)
    }

    private var mediumView: some View {
        VStack(alignment: .leading, spacing: 8) {
            if entry.blocks.isEmpty {
                emptyView
            } else {
                ForEach(entry.blocks.prefix(3)) { block in
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(contextColor(block.contextName))
                            .frame(width: 3, height: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(block.title)
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text(timeRange(block))
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                        Spacer()
                        if block.isActive(at: entry.date) {
                            Text("NOW")
                                .font(.system(size: 9, weight: .heavy, design: .rounded))
                                .foregroundStyle(contextColor(block.contextName))
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(widgetBackground, for: .widget)
    }

    private var emptyView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ALL CLEAR")
                .font(.system(size: 10, weight: .heavy, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))
            Text("Nothing scheduled")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Spacer(minLength: 0)
        }
    }

    // MARK: Lock Screen

    private var rectangularView: some View {
        Group {
            if let block = next {
                VStack(alignment: .leading, spacing: 1) {
                    Text(statusLabel(block).uppercased())
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                        .widgetAccentable()
                    Text(block.title)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .lineLimit(1)
                    Text(timeRange(block))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .opacity(0.7)
                }
            } else {
                Text("Loom: nothing scheduled")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .containerBackground(.clear, for: .widget)
    }

    private var inlineView: some View {
        Group {
            if let block = next {
                Text("\(block.isActive(at: entry.date) ? "Now" : timeShort(block.start)): \(block.title)")
            } else {
                Text("Loom: all clear")
            }
        }
        .containerBackground(.clear, for: .widget)
    }

    private func timeShort(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }
}
