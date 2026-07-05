import SwiftUI
import SwiftData

struct ScheduleView: View {
    private enum ViewMode: String, CaseIterable {
        case day = "Day"
        case week = "Week"
    }

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ScheduledBlock.startTime) private var allBlocks: [ScheduledBlock]
    @Query private var blockedTimes: [BlockedTime]
    @Query private var busyEvents: [BusyEvent]
    @State private var selectedDate = Date()
    @State private var viewMode: ViewMode = .day
    @State private var celebrationTask: LoomTask?
    @State private var progressPromptBlock: ScheduledBlock?

    private let calendar = Calendar.current

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header

                switch viewMode {
                case .day:
                    dayStrip
                    Divider().overlay(Color.loomBorder)
                    dayList
                case .week:
                    weekGrid
                }
            }
            .background(Color.loomBackground)
            .toolbar(.hidden, for: .navigationBar)
            .fullScreenCover(item: $celebrationTask) { task in
                TaskCompletionView(task: task) {
                    celebrationTask = nil
                }
            }
            .sheet(item: $progressPromptBlock) { block in
                if let task = block.task {
                    BlockProgressPrompt(task: task, workedMinutes: block.durationMinutes) { finished in
                        progressPromptBlock = nil
                        if finished {
                            // Let the sheet dismiss before presenting the cover.
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                completeTask(task)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Header (title + Day/Week toggle)

    private var header: some View {
        HStack {
            Text("Schedule")
                .font(AppFont.title(26))
                .foregroundStyle(Color.loomText)

            Spacer()

            HStack(spacing: 2) {
                ForEach(ViewMode.allCases, id: \.self) { mode in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            viewMode = mode
                        }
                    } label: {
                        Text(mode.rawValue)
                            .font(AppFont.caption(12))
                            .foregroundStyle(viewMode == mode ? Color.loomText : Color.loomSubtle)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: LoomRadius.sm, style: .continuous)
                                    .fill(viewMode == mode ? Color.loomSurface : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.loomSurface2)
            )
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 8)
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
                            hasItems: !itemsForDate(date).isEmpty
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
                proxy.scrollTo(calendar.startOfDay(for: selectedDate), anchor: .center)
            }
        }
    }

    private var dayRange: [Date] {
        guard let start = calendar.date(byAdding: .day, value: -3, to: Date()) else { return [] }
        return (0..<30).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: start))
        }
    }

    // MARK: - Day list

    private var dayList: some View {
        let items = itemsForDate(selectedDate)

        return ScrollView {
            if items.isEmpty {
                EmptyStateView(
                    icon: "calendar",
                    title: "No blocks scheduled",
                    subtitle: "Add tasks and they'll appear here."
                )
                .padding(.top, 40)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(items) { item in
                        switch item {
                        case .block(let block):
                            BlockCard(block: block) {
                                toggleBlock(block)
                            }
                        case .blocked(let interval, let label):
                            BlockedTimeCard(interval: interval, label: label)
                        case .busy(let event):
                            BusyEventCard(event: event)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 100)
            }
        }
    }

    // MARK: - Week grid

    private var weekGrid: some View {
        let week = weekDays
        let startHour = 7
        let endHour = 22
        let pointsPerHour: CGFloat = 22
        let gridHeight = CGFloat(endHour - startHour) * pointsPerHour
        let labelHours = [7, 10, 13, 16, 19, 22]

        return ScrollView {
            VStack(spacing: 6) {
                // Day headers
                HStack(spacing: 0) {
                    Color.clear.frame(width: 28)
                    ForEach(week, id: \.self) { day in
                        Button {
                            jumpToDay(day)
                        } label: {
                            VStack(spacing: 1) {
                                Text(TimeFormatter.dayOfWeek.string(from: day).uppercased())
                                    .font(AppFont.caption(9))
                                    .foregroundStyle(calendar.isDate(day, inSameDayAs: selectedDate) ? Color.loomRed : Color.loomSubtle)
                                Text("\(calendar.component(.day, from: day))")
                                    .font(AppFont.heading(13))
                                    .foregroundStyle(calendar.isDateInToday(day) ? Color.loomRed : Color.loomText)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Time grid
                HStack(alignment: .top, spacing: 0) {
                    // Hour labels
                    ZStack(alignment: .topLeading) {
                        Color.clear
                        ForEach(labelHours, id: \.self) { hour in
                            Text(hourLabel(hour))
                                .font(AppFont.monoMedium(8))
                                .foregroundStyle(Color.loomFaint)
                                .offset(y: CGFloat(hour - startHour) * pointsPerHour - 5)
                        }
                    }
                    .frame(width: 28, height: gridHeight)

                    // Columns
                    ZStack(alignment: .topLeading) {
                        // Hour lines
                        ForEach(labelHours, id: \.self) { hour in
                            Rectangle()
                                .fill(Color.loomBorder)
                                .frame(height: 1)
                                .offset(y: CGFloat(hour - startHour) * pointsPerHour)
                        }

                        HStack(spacing: 0) {
                            ForEach(week, id: \.self) { day in
                                ZStack(alignment: .topLeading) {
                                    Color.clear

                                    ForEach(itemsForDate(day)) { item in
                                        weekItemView(
                                            item: item,
                                            day: day,
                                            startHour: startHour,
                                            pointsPerHour: pointsPerHour,
                                            gridHeight: gridHeight
                                        )
                                    }
                                }
                                .frame(maxWidth: .infinity)
                                .frame(height: gridHeight)
                                .overlay(alignment: .trailing) {
                                    Rectangle()
                                        .fill(Color.loomBorder)
                                        .frame(width: 1)
                                }
                            }
                        }
                    }
                    .frame(height: gridHeight)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(Color.loomBorder)
                            .frame(width: 1)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 30)
        }
    }

    /// Solid, unlabeled block in the week grid — tapping jumps to that day.
    private func weekItemView(
        item: DayItem,
        day: Date,
        startHour: Int,
        pointsPerHour: CGFloat,
        gridHeight: CGFloat
    ) -> some View {
        let (interval, color): (DateInterval, Color) = {
            switch item {
            case .block(let block):
                return (
                    DateInterval(start: block.startTime, end: block.endTime),
                    block.task?.context.color ?? .loomFaint
                )
            case .blocked(let interval, _):
                return (interval, .loomSurface3)
            case .busy(let event):
                return (DateInterval(start: event.startTime, end: event.endTime), .loomSurface3)
            }
        }()

        let dayStart = calendar.startOfDay(for: day)
        let startMinutes = interval.start.timeIntervalSince(dayStart) / 60
        let top = max(0, (startMinutes / 60 - Double(startHour)) * pointsPerHour)
        let height = max(6, interval.duration / 3600 * pointsPerHour)

        return RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(color)
            .frame(height: min(height, gridHeight - top))
            .padding(.horizontal, 2)
            .offset(y: top)
            .onTapGesture {
                jumpToDay(day)
            }
    }

    private func hourLabel(_ hour: Int) -> String {
        if hour == 12 { return "12p" }
        return hour > 12 ? "\(hour - 12)p" : "\(hour)a"
    }

    private var weekDays: [Date] {
        // Week containing the selected date, Monday first (matches the handoff).
        var cal = calendar
        cal.firstWeekday = 2
        guard let interval = cal.dateInterval(of: .weekOfYear, for: selectedDate) else { return [] }
        return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: interval.start) }
    }

    private func jumpToDay(_ day: Date) {
        withAnimation(.easeInOut(duration: 0.2)) {
            selectedDate = day
            viewMode = .day
        }
    }

    // MARK: - Items

    private enum DayItem: Identifiable {
        case block(ScheduledBlock)
        case blocked(DateInterval, String)
        case busy(BusyEvent)

        var id: String {
            switch self {
            case .block(let block): return block.id.uuidString
            case .blocked(let interval, let label): return "\(label)-\(interval.start.timeIntervalSince1970)"
            case .busy(let event): return event.id.uuidString
            }
        }

        var start: Date {
            switch self {
            case .block(let block): return block.startTime
            case .blocked(let interval, _): return interval.start
            case .busy(let event): return event.startTime
            }
        }
    }

    private func itemsForDate(_ date: Date) -> [DayItem] {
        let start = calendar.startOfDay(for: date)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }

        var items: [DayItem] = allBlocks
            .filter { $0.startTime >= start && $0.startTime < end }
            .map { .block($0) }

        for blocked in blockedTimes {
            items.append(contentsOf: blocked
                .occurrences(from: start, to: end)
                .map { .blocked($0, blocked.label) })
        }

        items.append(contentsOf: busyEvents
            .filter { $0.startTime >= start && $0.startTime < end }
            .map { .busy($0) })

        return items.sorted { $0.start < $1.start }
    }

    // MARK: - Completion

    private func toggleBlock(_ block: ScheduledBlock) {
        withAnimation(.easeInOut(duration: 0.2)) {
            block.isComplete.toggle()
        }

        // Checking a block records worked time only — progress is whatever the
        // user says it is, so ask (they can skip).
        if block.isComplete, let task = block.task, !task.isComplete {
            progressPromptBlock = block
        }

        CalendarExportService.syncIfEnabled(context: modelContext)
    }

    private func completeTask(_ task: LoomTask) {
        task.isComplete = true
        task.manualProgressPercent = 100
        for block in task.scheduledBlocks where !block.isComplete && !block.isLocked {
            modelContext.delete(block)
        }
        celebrationTask = task
        CalendarExportService.syncIfEnabled(context: modelContext)
    }
}

// MARK: - Day Pill

private struct DayPill: View {
    let date: Date
    let isSelected: Bool
    let hasItems: Bool

    private let calendar = Calendar.current

    var body: some View {
        VStack(spacing: 4) {
            Text(TimeFormatter.dayOfWeek.string(from: date).uppercased())
                .font(AppFont.caption(11))
                .foregroundStyle(isSelected ? .white : Color.loomSubtle)
            Text("\(calendar.component(.day, from: date))")
                .font(AppFont.heading(17))
                .foregroundStyle(isSelected ? .white : isToday ? Color.loomRed : Color.loomText)
            Circle()
                .fill(hasItems ? (isSelected ? .white : Color.loomSubtle) : .clear)
                .frame(width: 5, height: 5)
        }
        .frame(width: 44, height: 64)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? Color.loomRed : Color.clear)
        )
    }

    private var isToday: Bool {
        calendar.isDateInToday(date)
    }
}

// MARK: - Block Card

private struct BlockCard: View {
    let block: ScheduledBlock
    var onToggle: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            // Time column
            VStack(alignment: .trailing, spacing: 2) {
                Text(TimeFormatter.clock.string(from: block.startTime))
                    .font(AppFont.mono(13))
                    .foregroundStyle(Color.loomText)
                Text(TimeFormatter.clock.string(from: block.endTime))
                    .font(AppFont.monoMedium(11))
                    .foregroundStyle(Color.loomSubtle)
            }
            .frame(width: 56, alignment: .trailing)

            // Color bar
            RoundedRectangle(cornerRadius: 2)
                .fill(contextColor)
                .frame(width: 4)

            // Content
            VStack(alignment: .leading, spacing: 4) {
                Text(block.task?.title ?? "Unknown Task")
                    .font(AppFont.bodySemibold(15))
                    .strikethrough(block.isComplete)
                    .foregroundStyle(block.isComplete ? Color.loomSubtle : Color.loomText)

                HStack(spacing: 8) {
                    if let ctx = block.task?.context {
                        Text(ctx.rawValue)
                            .font(AppFont.caption(11))
                            .foregroundStyle(ctx.color)
                    }
                    Text(CountdownFormatter.effortString(minutes: block.durationMinutes))
                        .font(AppFont.monoMedium(11))
                        .foregroundStyle(Color.loomSubtle)
                    if block.isLocked {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.loomSubtle)
                    }
                }
            }

            Spacer()

            // Complete button
            Button(action: onToggle) {
                Image(systemName: block.isComplete ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(block.isComplete ? Color.personalColor : Color.loomFaint)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.loomSurface2)
        )
    }

    private var contextColor: Color {
        block.task?.context.color ?? Color.loomFaint
    }
}

// MARK: - Blocked Time Card

private struct BlockedTimeCard: View {
    let interval: DateInterval
    let label: String

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(TimeFormatter.clock.string(from: interval.start))
                    .font(AppFont.mono(13))
                    .foregroundStyle(Color.loomText)
                Text(TimeFormatter.clock.string(from: interval.end))
                    .font(AppFont.monoMedium(11))
                    .foregroundStyle(Color.loomSubtle)
            }
            .frame(width: 56, alignment: .trailing)

            RoundedRectangle(cornerRadius: 2)
                .fill(Color.loomFaint)
                .frame(width: 4)

            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(AppFont.bodySemibold(15))
                    .foregroundStyle(Color.loomSubtle)
                HStack(spacing: 5) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9))
                    Text("Blocked")
                        .font(AppFont.caption(11))
                }
                .foregroundStyle(Color.loomFaint)
            }

            Spacer()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.loomSurface2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.loomFaint, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
    }
}

// MARK: - Busy Event Card (imported from a calendar)

private struct BusyEventCard: View {
    let event: BusyEvent

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(TimeFormatter.clock.string(from: event.startTime))
                    .font(AppFont.mono(13))
                    .foregroundStyle(Color.loomText)
                Text(TimeFormatter.clock.string(from: event.endTime))
                    .font(AppFont.monoMedium(11))
                    .foregroundStyle(Color.loomSubtle)
            }
            .frame(width: 56, alignment: .trailing)

            RoundedRectangle(cornerRadius: 2)
                .fill(Color.loomFaint)
                .frame(width: 4)

            VStack(alignment: .leading, spacing: 4) {
                Text(event.title)
                    .font(AppFont.bodySemibold(15))
                    .foregroundStyle(Color.loomSubtle)
                HStack(spacing: 5) {
                    Image(systemName: "calendar")
                        .font(.system(size: 9))
                    Text(event.calendarName ?? "Calendar")
                        .font(AppFont.caption(11))
                }
                .foregroundStyle(Color.loomFaint)
            }

            Spacer()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.loomSurface2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.loomBorder, lineWidth: 1)
        )
    }
}

// MARK: - Block progress prompt

/// After checking off a block: the time is logged, but only the user knows how
/// far the task actually moved. Saving 100% completes the task; skipping keeps
/// progress untouched.
private struct BlockProgressPrompt: View {
    let task: LoomTask
    let workedMinutes: Int
    /// Called with `true` when the user reported the task finished.
    var onDismiss: (Bool) -> Void

    @State private var progressValue: Double = 0

    var body: some View {
        VStack(spacing: 16) {
            Text("Time logged")
                .font(AppFont.display(20))
                .foregroundStyle(Color.loomText)
                .padding(.top, 28)
            Text("\(CountdownFormatter.effortString(minutes: workedMinutes)) on \u{201C}\(task.title)\u{201D}")
                .font(AppFont.body(14))
                .foregroundStyle(Color.loomSubtle)
                .multilineTextAlignment(.center)

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
            .padding(.top, 6)

            Button {
                task.manualProgressPercent = max(task.manualProgressPercent, Int(progressValue))
                onDismiss(Int(progressValue) >= 100)
            } label: {
                Text("Save Progress")
                    .primaryButtonStyle(fill: task.context.color)
            }

            Button("Skip") {
                onDismiss(false)
            }
            .font(AppFont.caption(14))
            .foregroundStyle(Color.loomSubtle)
            .padding(.bottom, 16)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.loomBackground)
        .presentationDetents([.fraction(0.5)])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(LoomRadius.sheet)
        .onAppear {
            progressValue = Double(task.progressPercent)
        }
    }

    private var sliderRange: ClosedRange<Double> {
        let minimum = Double(min(task.progressPercent, 95))
        return minimum...100
    }
}
