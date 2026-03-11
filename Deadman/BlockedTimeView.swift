import SwiftUI
import SwiftData
import EventKit

struct BlockedTimeView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \BlockedTime.startTime) private var blockedTimes: [BlockedTime]

    @State private var showAddSheet = false
    @State private var showCalendarImport = false
    @State private var calendarPermissionDenied = false

    var body: some View {
        NavigationStack {
            List {
                calendarImportSection
                manualEventsSection
            }
            .navigationTitle("Blocked Times")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAddSheet) {
                AddBlockedTimeView()
            }
            .sheet(isPresented: $showCalendarImport) {
                CalendarImportView()
            }
            .alert("Calendar Access Denied", isPresented: $calendarPermissionDenied) {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Loom needs calendar access to import your events as blocked time. Enable it in Settings > Privacy > Calendars.")
            }
        }
    }

    // MARK: - Calendar Import

    private var calendarImportSection: some View {
        Section {
            Button {
                requestCalendarAccess()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "calendar.badge.plus")
                        .font(.system(size: 18))
                        .foregroundStyle(Color.schoolColor)
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Import from Apple Calendar")
                            .font(AppFont.body(15))
                            .foregroundStyle(.primary)
                        Text("Pull in existing events as blocked time")
                            .font(AppFont.caption(12))
                            .foregroundStyle(Color.loomSubtle)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.loomSubtle)
                }
            }
            .buttonStyle(.plain)
        } header: {
            Text("Apple Calendar")
        } footer: {
            Text("Imported events block scheduling but aren't modified. One-way read-only.")
        }
    }

    // MARK: - Manual Events

    private var manualEventsSection: some View {
        Section {
            if blockedTimes.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "clock.badge.xmark")
                            .font(.system(size: 28, weight: .light))
                            .foregroundStyle(Color.loomSubtle)
                        Text("No blocked times yet")
                            .font(AppFont.caption())
                            .foregroundStyle(Color.loomSubtle)
                    }
                    .padding(.vertical, 20)
                    Spacer()
                }
            } else {
                ForEach(blockedTimes) { blocked in
                    BlockedTimeRow(blockedTime: blocked)
                }
                .onDelete(perform: deleteBlockedTimes)
            }
        } header: {
            Text("Manual Events")
        } footer: {
            Text("Add recurring commitments (classes, meetings, gym) so tasks aren't scheduled during them.")
        }
    }

    private func deleteBlockedTimes(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(blockedTimes[index])
        }
    }

    private func requestCalendarAccess() {
        let store = EKEventStore()
        let status = EKEventStore.authorizationStatus(for: .event)

        switch status {
        case .authorized, .fullAccess:
            showCalendarImport = true
            return
        case .denied, .restricted:
            calendarPermissionDenied = true
            return
        case .notDetermined, .writeOnly:
            break
        @unknown default:
            break
        }

        if #available(iOS 17.0, *) {
            store.requestFullAccessToEvents { granted, _ in
                DispatchQueue.main.async {
                    if granted { showCalendarImport = true }
                    else { calendarPermissionDenied = true }
                }
            }
        } else {
            store.requestAccess(to: .event) { granted, _ in
                DispatchQueue.main.async {
                    if granted { showCalendarImport = true }
                    else { calendarPermissionDenied = true }
                }
            }
        }
    }
}

// MARK: - Blocked Time Row

private struct BlockedTimeRow: View {
    let blockedTime: BlockedTime

    var body: some View {
        HStack(spacing: 12) {
            // Color indicator
            RoundedRectangle(cornerRadius: 2)
                .fill(blockedTime.appleCalendarEventId != nil ? Color.schoolColor : Color.workColor)
                .frame(width: 4, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(blockedTime.title)
                    .font(AppFont.body(15))
                    .fontWeight(.medium)

                HStack(spacing: 6) {
                    Text(timeRangeString)
                        .font(AppFont.mono(12))
                        .foregroundStyle(Color.loomSubtle)
                    if blockedTime.recurrence != .none {
                        Text("·")
                            .foregroundStyle(Color.loomSubtle)
                        Text(blockedTime.recurrence.rawValue)
                            .font(AppFont.caption(11))
                            .foregroundStyle(Color.workColor)
                    }
                }
            }

            Spacer()

            if blockedTime.appleCalendarEventId != nil {
                Image(systemName: "calendar")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.loomSubtle)
            }
        }
    }

    private var timeRangeString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        let start = formatter.string(from: blockedTime.startTime)
        let end = formatter.string(from: blockedTime.endTime)
        return "\(start) – \(end)"
    }
}

// MARK: - Add Blocked Time

struct AddBlockedTimeView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var startTime = Date()
    @State private var durationMinutes = 60
    @State private var recurrence: RecurrenceRule = .none
    @State private var hasEndDate = false
    @State private var endDate = Calendar.current.date(byAdding: .month, value: 3, to: Date())!

    private let durationOptions = [30, 60, 90, 120, 180, 240]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("e.g. CS 101 Lecture, Team standup", text: $title)
                        .font(AppFont.body(15))
                }

                Section {
                    DatePicker("Start", selection: $startTime, displayedComponents: [.date, .hourAndMinute])

                    Picker("Duration", selection: $durationMinutes) {
                        ForEach(durationOptions, id: \.self) { mins in
                            Text(CountdownFormatter.effortString(minutes: mins)).tag(mins)
                        }
                    }
                }

                Section {
                    Picker("Repeats", selection: $recurrence) {
                        ForEach(RecurrenceRule.allCases) { rule in
                            Text(rule.rawValue).tag(rule)
                        }
                    }

                    if recurrence != .none {
                        Toggle("Set end date", isOn: $hasEndDate)
                        if hasEndDate {
                            DatePicker("Until", selection: $endDate, displayedComponents: .date)
                        }
                    }
                } footer: {
                    if recurrence != .none {
                        Text("Recurring events will block the same time slot on each occurrence.")
                    }
                }
            }
            .navigationTitle("Block Time")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        save()
                    }
                    .fontWeight(.semibold)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func save() {
        let blocked = BlockedTime(
            title: title.trimmingCharacters(in: .whitespaces),
            startTime: startTime,
            durationMinutes: durationMinutes,
            recurrence: recurrence
        )
        if hasEndDate && recurrence != .none {
            blocked.recurrenceEndDate = endDate
        }
        modelContext.insert(blocked)
        dismiss()
    }
}

// MARK: - Calendar Import View

struct CalendarImportView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var calendars: [EKCalendar] = []
    @State private var selectedCalendarIds: Set<String> = []
    @State private var importCount = 0
    @State private var didImport = false

    private let store = EKEventStore()

    var body: some View {
        NavigationStack {
            List {
                if calendars.isEmpty {
                    Section {
                        Text("No calendars found.")
                            .font(AppFont.body())
                            .foregroundStyle(Color.loomSubtle)
                    }
                } else {
                    Section {
                        ForEach(calendars, id: \.calendarIdentifier) { cal in
                            Button {
                                toggleCalendar(cal.calendarIdentifier)
                            } label: {
                                HStack {
                                    Circle()
                                        .fill(Color(cgColor: cal.cgColor))
                                        .frame(width: 12, height: 12)
                                    Text(cal.title)
                                        .font(AppFont.body(15))
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if selectedCalendarIds.contains(cal.calendarIdentifier) {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Color.loomRed)
                                            .fontWeight(.semibold)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text("Select Calendars")
                    } footer: {
                        Text("Events from the next 30 days will be imported as blocked time slots.")
                    }
                }

                if didImport {
                    Section {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Imported \(importCount) events")
                                .font(AppFont.body(15))
                        }
                    }
                }
            }
            .navigationTitle("Import Calendar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        importEvents()
                    }
                    .fontWeight(.semibold)
                    .disabled(selectedCalendarIds.isEmpty)
                }
            }
            .onAppear { loadCalendars() }
        }
    }

    private func toggleCalendar(_ id: String) {
        if selectedCalendarIds.contains(id) {
            selectedCalendarIds.remove(id)
        } else {
            selectedCalendarIds.insert(id)
        }
    }

    private func loadCalendars() {
        calendars = store.calendars(for: .event)
            .filter { $0.allowsContentModifications || true }
            .sorted { $0.title < $1.title }
    }

    private func importEvents() {
        let now = Date()
        let end = Calendar.current.date(byAdding: .day, value: 30, to: now)!

        let selectedCalendars = calendars.filter { selectedCalendarIds.contains($0.calendarIdentifier) }
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: selectedCalendars)
        let events = store.events(matching: predicate)

        // Fetch existing imported event IDs to avoid duplicates
        let existingDescriptor = FetchDescriptor<BlockedTime>()
        let existingBlocked = (try? modelContext.fetch(existingDescriptor)) ?? []
        let existingEventIds = Set(existingBlocked.compactMap { $0.appleCalendarEventId })

        var count = 0
        for event in events {
            guard !event.isAllDay else { continue }
            guard !existingEventIds.contains(event.eventIdentifier) else { continue }

            let duration = Int(event.endDate.timeIntervalSince(event.startDate) / 60)
            guard duration > 0 else { continue }

            let blocked = BlockedTime(
                title: event.title ?? "Calendar Event",
                startTime: event.startDate,
                durationMinutes: duration
            )
            blocked.appleCalendarEventId = event.eventIdentifier
            modelContext.insert(blocked)
            count += 1
        }

        importCount = count
        didImport = true
    }
}
