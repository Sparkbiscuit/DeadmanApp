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
    @Query private var reminders: [Reminder]
    @State private var selectedDate = Date()
    @State private var viewMode: ViewMode = .day
    @State private var weekOffset = 0
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
                    dayList
                case .week:
                    weekGrid
                }
            }
            .hearthScreen(topGlow: 0.26, bottomGlow: 0.32)
            .toolbar(.hidden, for: .navigationBar)
            .fullScreenCover(item: $celebrationTask) { task in
                TaskCompletionView(task: task) {
                    celebrationTask = nil
                } onUndo: {
                    restoreTask(task, context: modelContext)
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
            HearthTitle(text: "Schedule", size: 30)

            Spacer()

            HStack(spacing: 2) {
                ForEach(ViewMode.allCases, id: \.self) { mode in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            viewMode = mode
                            weekOffset = 0
                        }
                    } label: {
                        Text(mode.rawValue)
                            .font(AppFont.caption(13))
                            .foregroundStyle(viewMode == mode ? Color.brand300 : Color.loomSubtle)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(viewMode == mode ? Color.brand500.opacity(0.2) : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.loomBorder, lineWidth: 1))
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
                // Minute cadence so the now-line drifts and past rows dim
                // without any interaction.
                TimelineView(.periodic(from: .now, by: 60)) { timeline in
                    let now = timeline.date
                    let nowLineIndex = nowLineIndex(in: items, at: now)

                    LazyVStack(spacing: 10) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            if index == nowLineIndex {
                                NowLine(now: now)
                            }
                            timelineRow(for: item, at: now)
                        }
                        if nowLineIndex == items.count {
                            NowLine(now: now)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 110)
                }
            }
        }
    }

    /// Where the thread of light sits: after everything that has ended,
    /// before whatever is running or still to come. Only shown for today.
    private func nowLineIndex(in items: [DayItem], at now: Date) -> Int? {
        guard calendar.isDate(selectedDate, inSameDayAs: now) else { return nil }
        return items.firstIndex { $0.end > now } ?? items.count
    }

    @ViewBuilder
    private func timelineRow(for item: DayItem, at now: Date) -> some View {
        switch item {
        case .block(let block):
            BlockCard(block: block, now: now) {
                toggleBlock(block)
            }
        case .blocked(let interval, let label):
            BlockedTimeCard(interval: interval, label: label, now: now)
        case .busy(let event):
            BusyEventCard(event: event, now: now)
        case .reminder(let reminder):
            ReminderScheduleCard(reminder: reminder, now: now) {
                toggleReminder(reminder)
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
                // Week range + back-to-today
                HStack {
                    Text(weekRangeLabel)
                        .font(AppFont.caption(12))
                        .foregroundStyle(Color.loomSubtle)
                    Spacer()
                    if weekOffset != 0 {
                        Button("Today") {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                weekOffset = 0
                                selectedDate = Date()
                            }
                        }
                        .font(AppFont.caption(12))
                        .foregroundStyle(Color.brand300)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 2)

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
                                    .foregroundStyle(calendar.isDate(day, inSameDayAs: selectedDate) ? Color.brand300 : Color.loomSubtle)
                                Text("\(calendar.component(.day, from: day))")
                                    .font(AppFont.mono(13))
                                    .foregroundStyle(calendar.isDateInToday(day) ? Color.brand300 : Color.loomText)
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
        // Swipe horizontally to page between weeks.
        .simultaneousGesture(
            DragGesture(minimumDistance: 30)
                .onEnded { value in
                    guard abs(value.translation.width) > abs(value.translation.height),
                          abs(value.translation.width) > 40 else { return }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        weekOffset += value.translation.width < 0 ? 1 : -1
                    }
                }
        )
        .sensoryFeedback(.selection, trigger: weekOffset)
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
            case .reminder(let reminder):
                // Point-in-time: draw a thin tick at the due time.
                return (DateInterval(start: reminder.dueDate, duration: 5 * 60), .brand500)
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
        // Week containing the selected date, Monday first, shifted by however
        // many weeks the user has swiped.
        var cal = calendar
        cal.firstWeekday = 2
        guard let interval = cal.dateInterval(of: .weekOfYear, for: selectedDate),
              let start = cal.date(byAdding: .weekOfYear, value: weekOffset, to: interval.start) else { return [] }
        return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }

    private var weekRangeLabel: String {
        guard let first = weekDays.first, let last = weekDays.last else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return "\(formatter.string(from: first)) – \(formatter.string(from: last))"
    }

    private func jumpToDay(_ day: Date) {
        withAnimation(.easeInOut(duration: 0.2)) {
            selectedDate = day
            viewMode = .day
            weekOffset = 0
        }
    }

    // MARK: - Items

    private enum DayItem: Identifiable {
        case block(ScheduledBlock)
        case blocked(DateInterval, String)
        case busy(BusyEvent)
        case reminder(Reminder)

        var id: String {
            switch self {
            case .block(let block): return block.id.uuidString
            case .blocked(let interval, let label): return "\(label)-\(interval.start.timeIntervalSince1970)"
            case .busy(let event): return event.id.uuidString
            case .reminder(let reminder): return reminder.id.uuidString
            }
        }

        var start: Date {
            switch self {
            case .block(let block): return block.startTime
            case .blocked(let interval, _): return interval.start
            case .busy(let event): return event.startTime
            case .reminder(let reminder): return reminder.dueDate
            }
        }

        var end: Date {
            switch self {
            case .block(let block): return block.endTime
            case .blocked(let interval, _): return interval.end
            case .busy(let event): return event.endTime
            case .reminder(let reminder): return reminder.dueDate
            }
        }
    }

    private func itemsForDate(_ date: Date) -> [DayItem] {
        let start = calendar.startOfDay(for: date)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }

        // Blocks whose task is gone are data damage, not schedule — never
        // render them as "Unknown Task" rows (the foreground sweep in
        // MainTabView deletes them).
        var items: [DayItem] = allBlocks
            .filter { $0.task != nil && $0.startTime >= start && $0.startTime < end }
            .map { .block($0) }

        for blocked in blockedTimes {
            items.append(contentsOf: blocked
                .occurrences(from: start, to: end)
                .map { .blocked($0, blocked.label) })
        }

        items.append(contentsOf: busyEvents
            .filter { $0.startTime >= start && $0.startTime < end }
            .map { .busy($0) })

        items.append(contentsOf: reminders
            .filter { $0.dueDate >= start && $0.dueDate < end }
            .map { .reminder($0) })

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
        scheduleDidChange(context: modelContext)
    }

    private func toggleReminder(_ reminder: Reminder) {
        withAnimation(.easeInOut(duration: 0.2)) {
            reminder.isComplete.toggle()
        }
        if reminder.isComplete {
            NotificationService.cancel(reminder)
        } else if reminder.dueDate > Date() {
            NotificationService.schedule(for: reminder)
        }
    }

    private func completeTask(_ task: LoomTask) {
        task.isComplete = true
        task.completedAt = Date()
        for block in task.scheduledBlocks where !block.isComplete && !block.isLocked {
            modelContext.delete(block)
        }
        // Persist the released blocks immediately — unsaved deletes have
        // historically resurfaced as orphaned "Unknown Task" rows.
        try? modelContext.save()
        celebrationTask = task
        CalendarExportService.syncIfEnabled(context: modelContext)
        scheduleDidChange(context: modelContext)
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
                .font(AppFont.caption(10))
                .foregroundStyle(isSelected ? Color.brand300 : Color.loomSubtle)
                .kerning(0.5)
            Text("\(calendar.component(.day, from: date))")
                .font(AppFont.mono(16))
                .foregroundStyle(isSelected ? Color.brand100 : isToday ? Color.brand300 : Color.loomText)
            Circle()
                .fill(hasItems ? (isSelected ? Color.brand300 : Color.brand500.opacity(0.7)) : .clear)
                .frame(width: 4, height: 4)
        }
        .frame(width: 46, height: 66)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isSelected ? Color.brand500.opacity(0.16) : Color.loomSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isSelected ? Color.brand500.opacity(0.5) : Color.loomBorder, lineWidth: 1)
        )
        .shadow(color: isSelected ? Color.brand500.opacity(0.3) : .clear, radius: 10)
    }

    private var isToday: Bool {
        calendar.isDateInToday(date)
    }
}

// MARK: - Timeline time gutter

/// Mono start-time label sitting in the left gutter of the day timeline.
private struct TimeGutter: View {
    let date: Date
    var dimmed: Bool = false
    var tint: Color? = nil

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm"
        return formatter
    }()

    var body: some View {
        Text(Self.formatter.string(from: date))
            .font(AppFont.mono(12))
            .foregroundStyle(tint ?? (dimmed ? Color.loomFaint : Color.loomSubtle))
            .frame(width: 44, alignment: .trailing)
    }
}

// MARK: - Now line

/// The thread of light marking this exact minute: mono time, a breathing dot,
/// and a gradient bar fading out to the right.
private struct NowLine: View {
    let now: Date

    var body: some View {
        HStack(spacing: 14) {
            TimeGutter(date: now, tint: .brand300)

            ZStack(alignment: .leading) {
                LinearGradient(
                    colors: [Color.brand300.opacity(0.9), Color.brand500.opacity(0)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(height: 2)
                .hearthGlow(.brand500, radius: 6, opacity: 0.6)

                BreathingDot(color: .brand300, size: 10)
                    .offset(x: -4)
            }
        }
        .padding(.vertical, 2)
        .accessibilityLabel("Now, \(TimeFormatter.clock.string(from: now))")
    }
}

// MARK: - Block Card

private struct BlockCard: View {
    let block: ScheduledBlock
    let now: Date
    var onToggle: () -> Void

    private var isInSession: Bool {
        !block.isComplete && block.startTime <= now && now < block.endTime
    }

    private var isPast: Bool {
        block.isComplete || block.endTime <= now
    }

    private var hasStarted: Bool {
        block.isComplete || block.startTime <= now
    }

    private static let shortTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm"
        return formatter
    }()

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            TimeGutter(date: block.startTime, dimmed: isPast && !isInSession)

            HStack(spacing: 10) {
                if isInSession {
                    BreathingDot(color: .brand300, size: 9)
                } else if block.isComplete {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.personalDisplay)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(block.task?.title ?? "Unknown Task")
                        .font(AppFont.cardTitle(15))
                        .strikethrough(block.isComplete)
                        .foregroundStyle(block.isComplete ? Color.loomFaint : Color.loomText)
                        .lineLimit(1)

                    if isInSession {
                        Text("In session · \(minutesLeftLabel) left in block")
                            .font(AppFont.bodySemibold(12))
                            .foregroundStyle(Color.brand300)
                    } else {
                        HStack(spacing: 6) {
                            Text("\(Self.shortTime.string(from: block.startTime))–\(Self.shortTime.string(from: block.endTime)) · \(CountdownFormatter.effortString(minutes: block.durationMinutes))")
                                .font(AppFont.monoMedium(11))
                                .foregroundStyle(Color.loomSubtle)
                            if block.isLocked {
                                Image(systemName: "lock.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(Color.loomFaint)
                            }
                        }
                    }
                }

                Spacer(minLength: 6)

                if isInSession {
                    Text("\(Self.shortTime.string(from: block.startTime))-\(Self.shortTime.string(from: block.endTime))")
                        .font(AppFont.mono(12))
                        .foregroundStyle(Color.brand300)
                } else if let ctx = block.task?.context, !isPast {
                    Text(ctx.rawValue)
                        .contextTag(ctx)
                }

                // The check control only surfaces once the block has started —
                // future rows stay clean, per the design. Early birds can
                // still check off from the context menu.
                if hasStarted && !isInSession {
                    Button(action: onToggle) {
                        Image(systemName: block.isComplete ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 20, weight: .light))
                            .foregroundStyle(block.isComplete ? Color.personalColor : Color.loomFaint.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: LoomRadius.row, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: LoomRadius.row, style: .continuous)
                    .stroke(
                        isInSession ? Color.brand500.opacity(0.45) : Color.loomBorder,
                        lineWidth: 1
                    )
            )
            .shadow(color: isInSession ? Color.brand500.opacity(0.3) : .clear, radius: 16)
            .opacity(isPast && !block.isComplete ? 0.55 : 1)
            .contextMenu {
                Button(action: onToggle) {
                    Label(
                        block.isComplete ? "Mark Incomplete" : "Mark Complete",
                        systemImage: block.isComplete ? "arrow.uturn.backward" : "checkmark.circle"
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var cardBackground: some View {
        if isInSession {
            LinearGradient(
                stops: [
                    .init(color: Color.brand500.opacity(0.24), location: 0),
                    .init(color: Color(hex: 0x1A1A1E), location: 0.6)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            Color.loomSurface.opacity(block.isComplete ? 0.6 : 1)
        }
    }

    private var minutesLeftLabel: String {
        let seconds = max(0, Int(block.endTime.timeIntervalSince(now)))
        return CountdownFormatter.effortString(minutes: max(1, seconds / 60))
    }
}

// MARK: - Blocked Time Card

private struct BlockedTimeCard: View {
    let interval: DateInterval
    let label: String
    let now: Date

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            TimeGutter(date: interval.start, dimmed: interval.end <= now)

            HStack(spacing: 10) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.loomFaint)

                VStack(alignment: .leading, spacing: 3) {
                    Text(label)
                        .font(AppFont.bodySemibold(15))
                        .foregroundStyle(Color.loomSubtle)
                    Text("Blocked")
                        .font(AppFont.caption(11))
                        .foregroundStyle(Color.loomFaint)
                }

                Spacer(minLength: 6)

                Text(rangeLabel)
                    .font(AppFont.monoMedium(11))
                    .foregroundStyle(Color.loomFaint)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .overlay(
                RoundedRectangle(cornerRadius: LoomRadius.row, style: .continuous)
                    .strokeBorder(Color.loomFaint.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
            .opacity(interval.end <= now ? 0.55 : 1)
        }
    }

    private var rangeLabel: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm"
        return "\(formatter.string(from: interval.start))-\(formatter.string(from: interval.end))"
    }
}

// MARK: - Busy Event Card (imported from a calendar)

private struct BusyEventCard: View {
    let event: BusyEvent
    let now: Date

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            TimeGutter(date: event.startTime, dimmed: event.endTime <= now)

            HStack(spacing: 10) {
                Image(systemName: "clock")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.loomFaint)

                VStack(alignment: .leading, spacing: 3) {
                    Text("\(event.title) — busy from \(event.calendarName ?? "Calendar")")
                        .font(AppFont.bodySemibold(14))
                        .foregroundStyle(Color.loomSubtle)
                        .lineLimit(2)
                }

                Spacer(minLength: 6)

                Text(rangeLabel)
                    .font(AppFont.monoMedium(11))
                    .foregroundStyle(Color.loomFaint)
                    .multilineTextAlignment(.trailing)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .overlay(
                RoundedRectangle(cornerRadius: LoomRadius.row, style: .continuous)
                    .strokeBorder(Color.loomFaint.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
            .opacity(event.endTime <= now ? 0.55 : 1)
        }
    }

    private var rangeLabel: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm"
        return "\(formatter.string(from: event.startTime))-\(formatter.string(from: event.endTime))"
    }
}

// MARK: - Reminder card (point-in-time)

private struct ReminderScheduleCard: View {
    let reminder: Reminder
    let now: Date
    var onToggle: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            TimeGutter(date: reminder.dueDate, dimmed: reminder.isComplete)

            HStack(spacing: 10) {
                Image(systemName: "bell.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.brand300)

                VStack(alignment: .leading, spacing: 3) {
                    Text(reminder.title)
                        .font(AppFont.cardTitle(15))
                        .strikethrough(reminder.isComplete)
                        .foregroundStyle(reminder.isComplete ? Color.loomFaint : Color.loomText)
                        .lineLimit(1)
                    Text("Reminder")
                        .font(AppFont.caption(11))
                        .foregroundStyle(Color.brand300)
                }

                Spacer(minLength: 6)

                Button(action: onToggle) {
                    Image(systemName: reminder.isComplete ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(reminder.isComplete ? Color.personalColor : Color.loomFaint)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(Color.loomSurface.opacity(reminder.isComplete ? 0.6 : 1))
            .clipShape(RoundedRectangle(cornerRadius: LoomRadius.row, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: LoomRadius.row, style: .continuous)
                    .stroke(Color.loomBorder, lineWidth: 1)
            )
        }
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
