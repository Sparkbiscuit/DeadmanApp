import SwiftUI
import SwiftData

// MARK: - Timeline Item (unified type for display)

private enum TimelineItem: Identifiable {
    case taskBlock(ScheduledBlock)
    case blocked(id: UUID, title: String, start: Date, end: Date)

    var id: UUID {
        switch self {
        case .taskBlock(let block): return block.id
        case .blocked(let id, _, _, _): return id
        }
    }

    var startTime: Date {
        switch self {
        case .taskBlock(let block): return block.startTime
        case .blocked(_, _, let start, _): return start
        }
    }
}

struct ScheduleView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ScheduledBlock.startTime) private var allBlocks: [ScheduledBlock]
    @Query(sort: \BlockedTime.startTime) private var allBlockedTimes: [BlockedTime]
    @State private var selectedDate = Date()

    private let calendar = Calendar.current

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                dayStrip
                Divider()
                timelineList
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Schedule")
            .navigationBarTitleDisplayMode(.large)
        }
    }

    // MARK: - Horizontal Day Strip

    private var dayStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(dayRange, id: \.self) { date in
                        DayPill(
                            date: date,
                            isSelected: calendar.isDate(date, inSameDayAs: selectedDate),
                            hasBlocks: !timelineItems(for: date).isEmpty
                        )
                        .id(date)
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                selectedDate = date
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .onAppear {
                proxy.scrollTo(calendar.startOfDay(for: Date()), anchor: .center)
            }
        }
    }

    private var dayRange: [Date] {
        let start = calendar.date(byAdding: .day, value: -3, to: Date())!
        return (0..<30).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: start))
        }
    }

    // MARK: - Timeline List

    private var timelineList: some View {
        let items = timelineItems(for: selectedDate)

        return ScrollView {
            if items.isEmpty {
                emptyState
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        switch item {
                        case .taskBlock(let block):
                            BlockCard(block: block)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 6)
                        case .blocked(_, let title, let start, let end):
                            BlockedTimeCard(title: title, start: start, end: end)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 6)
                        }
                    }
                }
                .padding(.top, 16)
                .padding(.bottom, 100)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "calendar")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Color.deadmanSubtle)
            Text("No blocks scheduled")
                .font(AppFont.body())
                .foregroundStyle(Color.deadmanSubtle)
            Text("Add tasks and they'll appear here")
                .font(AppFont.caption())
                .foregroundStyle(Color.deadmanSubtle.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    // MARK: - Helpers

    private func timelineItems(for date: Date) -> [TimelineItem] {
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!

        // Task blocks for this day
        var items: [TimelineItem] = allBlocks
            .filter { $0.startTime >= dayStart && $0.startTime < dayEnd }
            .map { .taskBlock($0) }

        // Blocked time occurrences for this day
        for blocked in allBlockedTimes {
            let occurrences = blocked.occurrences(from: dayStart, to: dayEnd)
            for occ in occurrences {
                items.append(.blocked(
                    id: UUID(),
                    title: blocked.title,
                    start: occ.start,
                    end: occ.end
                ))
            }
        }

        return items.sorted { $0.startTime < $1.startTime }
    }
}

// MARK: - Day Pill

private struct DayPill: View {
    let date: Date
    let isSelected: Bool
    let hasBlocks: Bool

    private let calendar = Calendar.current

    var body: some View {
        VStack(spacing: 4) {
            Text(dayOfWeek)
                .font(AppFont.caption(11))
                .foregroundStyle(isSelected ? .white : Color.deadmanSubtle)
            Text(dayNumber)
                .font(AppFont.heading(17))
                .foregroundStyle(isSelected ? .white : isToday ? Color.deadmanRed : .primary)
            Circle()
                .fill(hasBlocks ? (isSelected ? .white : Color.deadmanSubtle) : .clear)
                .frame(width: 5, height: 5)
        }
        .frame(width: 44, height: 64)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? Color.deadmanRed : Color.clear)
        )
    }

    private var dayOfWeek: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        return formatter.string(from: date).uppercased()
    }

    private var dayNumber: String {
        "\(calendar.component(.day, from: date))"
    }

    private var isToday: Bool {
        calendar.isDateInToday(date)
    }
}

// MARK: - Block Card (task work block)

private struct BlockCard: View {
    @Environment(\.modelContext) private var modelContext
    let block: ScheduledBlock

    var body: some View {
        HStack(spacing: 14) {
            // Time column
            VStack(alignment: .trailing, spacing: 2) {
                Text(timeString(block.startTime))
                    .font(AppFont.mono(13))
                    .foregroundStyle(.primary)
                Text(timeString(block.endTime))
                    .font(AppFont.mono(11))
                    .foregroundStyle(Color.deadmanSubtle)
            }
            .frame(width: 52, alignment: .trailing)

            // Color bar
            RoundedRectangle(cornerRadius: 2)
                .fill(contextColor)
                .frame(width: 4)

            // Content
            VStack(alignment: .leading, spacing: 4) {
                Text(block.task?.title ?? "Unknown Task")
                    .font(AppFont.body(15))
                    .fontWeight(.medium)
                    .strikethrough(block.isComplete)
                    .foregroundStyle(block.isComplete ? Color.deadmanSubtle : .primary)

                HStack(spacing: 8) {
                    if let ctx = block.task?.context {
                        Text(ctx.rawValue)
                            .font(AppFont.caption(11))
                            .foregroundStyle(ctx.color)
                    }
                    Text(CountdownFormatter.effortString(minutes: block.durationMinutes))
                        .font(AppFont.mono(11))
                        .foregroundStyle(Color.deadmanSubtle)
                    if block.isLocked {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.deadmanSubtle)
                    }
                }
            }

            Spacer()

            // Complete button
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    block.isComplete.toggle()
                }
            } label: {
                Image(systemName: block.isComplete ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(block.isComplete ? Color.green : Color.deadmanSubtle)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private var contextColor: Color {
        block.task?.context.color ?? Color.deadmanSubtle
    }

    private func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }
}

// MARK: - Blocked Time Card (calendar events / manual blocks)

private struct BlockedTimeCard: View {
    let title: String
    let start: Date
    let end: Date

    var body: some View {
        HStack(spacing: 14) {
            // Time column
            VStack(alignment: .trailing, spacing: 2) {
                Text(timeString(start))
                    .font(AppFont.mono(13))
                    .foregroundStyle(.primary)
                Text(timeString(end))
                    .font(AppFont.mono(11))
                    .foregroundStyle(Color.deadmanSubtle)
            }
            .frame(width: 52, alignment: .trailing)

            // Color bar — dashed pattern for blocked time
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.deadmanSubtle.opacity(0.4))
                .frame(width: 4)

            // Content
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(AppFont.body(15))
                    .fontWeight(.medium)
                    .foregroundStyle(Color.deadmanSubtle)

                HStack(spacing: 6) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9))
                    Text("Blocked")
                        .font(AppFont.caption(11))
                }
                .foregroundStyle(Color.deadmanSubtle.opacity(0.7))
            }

            Spacer()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground).opacity(0.6))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                        .foregroundStyle(Color.deadmanSubtle.opacity(0.3))
                )
        )
    }

    private func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }
}
