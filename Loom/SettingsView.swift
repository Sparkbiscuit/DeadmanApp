import SwiftUI
import SwiftData
import EventKit

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var settingsArray: [UserSettings]
    @State private var showCalendarDeniedAlert = false
    @State private var didPushNow = false

    var body: some View {
        NavigationStack {
            Group {
                if let settings = settingsArray.first {
                    settingsList(settings)
                } else {
                    // MainTabView creates the row on appear; this is a one-frame fallback.
                    ProgressView()
                        .onAppear { _ = UserSettings.fetchOrCreate(in: modelContext) }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
        }
    }

    private func settingsList(_ settings: UserSettings) -> some View {
        List {
            scheduleSection(settings)
            blockedTimesSection
            focusSection(settings)
            blockSizeSection(settings)
            bufferSection(settings)
            calendarSection(settings)
            aboutSection
        }
        .scrollContentBackground(.hidden)
        .background(Color.loomBackground)
        .alert("Calendar access needed", isPresented: $showCalendarDeniedAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Enable calendar access for Loom in Settings to export your work blocks.")
        }
    }

    // MARK: - Daily Schedule

    private func scheduleSection(_ settings: UserSettings) -> some View {
        Section {
            timePicker(
                label: "Wake time",
                icon: "sunrise.fill",
                color: .workColor,
                hour: Binding(
                    get: { settings.wakeHour },
                    set: { settings.wakeHour = $0 }
                ),
                minute: Binding(
                    get: { settings.wakeMinute },
                    set: { settings.wakeMinute = $0 }
                )
            )
            timePicker(
                label: "Sleep time",
                icon: "moon.fill",
                color: .schoolColor,
                hour: Binding(
                    get: { settings.sleepHour },
                    set: { settings.sleepHour = $0 }
                ),
                minute: Binding(
                    get: { settings.sleepMinute },
                    set: { settings.sleepMinute = $0 }
                )
            )
        } header: {
            Text("Daily Schedule")
        } footer: {
            Text("Tasks are scheduled between these hours. A sleep time past midnight is fine; Loom treats it as the next day.")
        }
        .listRowBackground(Color.loomSurface)
    }

    private func timePicker(
        label: String,
        icon: String,
        color: Color,
        hour: Binding<Int>,
        minute: Binding<Int>
    ) -> some View {
        let date = Binding<Date>(
            get: {
                var components = DateComponents()
                components.hour = hour.wrappedValue
                components.minute = minute.wrappedValue
                return Calendar.current.date(from: components) ?? Date()
            },
            set: { newDate in
                let comps = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                hour.wrappedValue = comps.hour ?? 8
                minute.wrappedValue = comps.minute ?? 0
            }
        )

        return HStack {
            Label(label, systemImage: icon)
                .foregroundStyle(color)
                .font(AppFont.body(15))
            Spacer()
            DatePicker("", selection: date, displayedComponents: .hourAndMinute)
                .labelsHidden()
        }
    }

    // MARK: - Blocked Times

    private var blockedTimesSection: some View {
        Section {
            NavigationLink {
                BlockedTimeView()
            } label: {
                Label("Blocked Times", systemImage: "lock.fill")
                    .font(AppFont.body(15))
            }
        } header: {
            Text("Calendar Blocking")
        } footer: {
            Text("Recurring events like classes, meetings, and commutes that Loom schedules around.")
        }
        .listRowBackground(Color.loomSurface)
    }

    // MARK: - Daily Focus

    private func focusSection(_ settings: UserSettings) -> some View {
        Section {
            Stepper(value: Binding(
                get: { settings.dailyFocusMinutes },
                set: { settings.dailyFocusMinutes = $0 }
            ), in: 0...720, step: 30) {
                HStack {
                    Label("Daily focus limit", systemImage: "gauge.with.needle")
                        .font(AppFont.body(15))
                    Spacer()
                    Text(settings.dailyFocusMinutes == 0
                         ? "Off"
                         : CountdownFormatter.effortString(minutes: settings.dailyFocusMinutes))
                        .font(AppFont.mono(14))
                        .foregroundStyle(Color.loomSubtle)
                }
            }
        } header: {
            Text("Daily Focus")
        } footer: {
            Text("Caps how much task work Loom books on any single day, so one bad deadline can't flood your week.")
        }
        .listRowBackground(Color.loomSurface)
    }

    // MARK: - Block Size

    private func blockSizeSection(_ settings: UserSettings) -> some View {
        Section {
            Stepper(value: Binding(
                get: { settings.minBlockMinutes },
                set: { settings.minBlockMinutes = $0 }
            ), in: 15...60, step: 15) {
                HStack {
                    Label("Minimum block", systemImage: "rectangle.compress.vertical")
                        .font(AppFont.body(15))
                    Spacer()
                    Text(CountdownFormatter.effortString(minutes: settings.minBlockMinutes))
                        .font(AppFont.mono(14))
                        .foregroundStyle(Color.loomSubtle)
                }
            }

            Stepper(value: Binding(
                get: { settings.maxBlockMinutes },
                set: { settings.maxBlockMinutes = $0 }
            ), in: 60...180, step: 30) {
                HStack {
                    Label("Maximum block", systemImage: "rectangle.expand.vertical")
                        .font(AppFont.body(15))
                    Spacer()
                    Text(CountdownFormatter.effortString(minutes: settings.maxBlockMinutes))
                        .font(AppFont.mono(14))
                        .foregroundStyle(Color.loomSubtle)
                }
            }
        } header: {
            Text("Block Size")
        } footer: {
            Text("Tasks are split into blocks within this range.")
        }
        .listRowBackground(Color.loomSurface)
    }

    // MARK: - Buffer

    private func bufferSection(_ settings: UserSettings) -> some View {
        Section {
            Stepper(value: Binding(
                get: { settings.deadlineBufferMinutes },
                set: { settings.deadlineBufferMinutes = $0 }
            ), in: 0...480, step: 30) {
                HStack {
                    Label("Deadline buffer", systemImage: "shield.fill")
                        .font(AppFont.body(15))
                    Spacer()
                    Text(CountdownFormatter.effortString(minutes: settings.deadlineBufferMinutes))
                        .font(AppFont.mono(14))
                        .foregroundStyle(Color.loomSubtle)
                }
            }
            Stepper(value: Binding(
                get: { settings.startBufferMinutes },
                set: { settings.startBufferMinutes = $0 }
            ), in: 0...60, step: 5) {
                HStack {
                    Label("Start buffer", systemImage: "hourglass.bottomhalf.filled")
                        .font(AppFont.body(15))
                    Spacer()
                    Text(settings.startBufferMinutes == 0
                         ? "None"
                         : CountdownFormatter.effortString(minutes: settings.startBufferMinutes))
                        .font(AppFont.mono(14))
                        .foregroundStyle(Color.loomSubtle)
                }
            }
        } header: {
            Text("Safety Buffer")
        } footer: {
            Text("Work blocks finish at least the deadline buffer before the due time, and newly scheduled work starts no sooner than the start buffer from now.")
        }
        .listRowBackground(Color.loomSurface)
    }

    // MARK: - Calendar export

    private func calendarSection(_ settings: UserSettings) -> some View {
        Section {
            Toggle(isOn: Binding(
                get: { settings.exportToAppleCalendar },
                set: { enabled in
                    setCalendarExport(enabled, settings: settings)
                }
            )) {
                Label("Export to Apple Calendar", systemImage: "calendar.badge.plus")
                    .font(AppFont.body(15))
            }
            .tint(Color.brand500)

            Toggle(isOn: Binding(
                get: { settings.importFromAppleCalendar },
                set: { enabled in
                    setCalendarImport(enabled, settings: settings)
                }
            )) {
                Label("Import busy times", systemImage: "calendar.badge.clock")
                    .font(AppFont.body(15))
            }
            .tint(Color.brand500)

            if settings.importFromAppleCalendar {
                NavigationLink {
                    CalendarPickerView(settings: settings)
                } label: {
                    HStack {
                        Label("Calendars", systemImage: "list.bullet")
                            .font(AppFont.body(15))
                        Spacer()
                        Text(includedCalendarsLabel(settings))
                            .font(AppFont.body(13))
                            .foregroundStyle(Color.loomSubtle)
                    }
                }
            }

            Button {
                pushBlocksNow(settings: settings)
            } label: {
                HStack {
                    Label("Push blocks to Calendar now", systemImage: "arrow.up.circle")
                        .font(AppFont.body(15))
                        .foregroundStyle(Color.brand500)
                    Spacer()
                    if didPushNow {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.personalColor)
                    }
                }
            }
        } header: {
            Text("Apple Calendar")
        } footer: {
            Text("Export mirrors your blocks into a dedicated \u{201C}Loom\u{201D} calendar. Import treats your other calendars' events as busy time the scheduler works around. They never become tasks.")
        }
        .listRowBackground(Color.loomSurface)
    }

    private func setCalendarExport(_ enabled: Bool, settings: UserSettings) {
        if enabled {
            Task { @MainActor in
                let granted = await CalendarExportService.requestAccess()
                if granted {
                    settings.exportToAppleCalendar = true
                    CalendarExportService.syncIfEnabled(context: modelContext)
                } else {
                    settings.exportToAppleCalendar = false
                    showCalendarDeniedAlert = true
                }
            }
        } else {
            settings.exportToAppleCalendar = false
            CalendarExportService.removeExportedEvents(context: modelContext)
        }
    }

    private func setCalendarImport(_ enabled: Bool, settings: UserSettings) {
        if enabled {
            Task { @MainActor in
                let granted = await CalendarExportService.requestAccess()
                if granted {
                    settings.importFromAppleCalendar = true
                    CalendarImportService.syncNow(context: modelContext, settings: settings)
                    // Scheduled work moves out of the way of the imported events.
                    replanAfterBusyChange(context: modelContext)
                } else {
                    settings.importFromAppleCalendar = false
                    showCalendarDeniedAlert = true
                }
            }
        } else {
            settings.importFromAppleCalendar = false
            CalendarImportService.removeImportedEvents(context: modelContext)
        }
    }

    private func includedCalendarsLabel(_ settings: UserSettings) -> String {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return "" }
        let total = CalendarImportService.availableCalendars(settings: settings).count
        let excluded = Set(settings.excludedCalendarIds)
        let included = CalendarImportService.availableCalendars(settings: settings)
            .filter { !excluded.contains($0.calendarIdentifier) }
            .count
        return included == total ? "All" : "\(included) of \(total)"
    }

    private func pushBlocksNow(settings: UserSettings) {
        Task { @MainActor in
            let granted = await CalendarExportService.requestAccess()
            if granted {
                CalendarExportService.syncNow(context: modelContext, settings: settings)
                withAnimation { didPushNow = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    withAnimation { didPushNow = false }
                }
            } else {
                showCalendarDeniedAlert = true
            }
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section {
            HStack {
                Text("Version")
                    .font(AppFont.body(15))
                Spacer()
                Text(appVersion)
                    .font(AppFont.body(14))
                    .foregroundStyle(Color.loomSubtle)
            }
        } header: {
            Text("About")
        }
        .listRowBackground(Color.loomSurface)
    }

    private var appVersion: String {
        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0"
        let build = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "1"
        return "\(version) (\(build))"
    }
}

// MARK: - Calendar picker

/// Per-calendar include/exclude for Apple Calendar import. Toggling off a
/// calendar (say, a family calendar full of events that shouldn't block work
/// time) removes its imported events and frees those slots.
private struct CalendarPickerView: View {
    @Environment(\.modelContext) private var modelContext
    let settings: UserSettings

    @State private var calendarsBySource: [(source: String, calendars: [EKCalendar])] = []

    var body: some View {
        List {
            ForEach(calendarsBySource, id: \.source) { group in
                Section {
                    ForEach(group.calendars, id: \.calendarIdentifier) { calendar in
                        Toggle(isOn: inclusionBinding(for: calendar)) {
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(calendarDotColor(calendar))
                                    .frame(width: 10, height: 10)
                                Text(calendar.title)
                                    .font(AppFont.body(15))
                                    .foregroundStyle(Color.loomText)
                            }
                        }
                        .tint(Color.brand500)
                    }
                } header: {
                    Text(group.source)
                }
                .listRowBackground(Color.loomSurface)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.loomBackground)
        .navigationTitle("Calendars")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadCalendars)
        .onDisappear {
            // One re-sync when leaving, instead of one per toggle flip.
            CalendarImportService.syncNow(context: modelContext, settings: settings)
            replanAfterBusyChange(context: modelContext)
        }
    }

    private func calendarDotColor(_ calendar: EKCalendar) -> Color {
        if let cgColor = calendar.cgColor {
            return Color(cgColor: cgColor)
        }
        return .loomFaint
    }

    private func loadCalendars() {
        let all = CalendarImportService.availableCalendars(settings: settings)
        let grouped = Dictionary(grouping: all) { $0.source?.title ?? "Other" }
        calendarsBySource = grouped
            .map { (source: $0.key, calendars: $0.value) }
            .sorted { $0.source < $1.source }
    }

    private func inclusionBinding(for calendar: EKCalendar) -> Binding<Bool> {
        Binding(
            get: { !settings.excludedCalendarIds.contains(calendar.calendarIdentifier) },
            set: { included in
                if included {
                    settings.excludedCalendarIds.removeAll { $0 == calendar.calendarIdentifier }
                } else if !settings.excludedCalendarIds.contains(calendar.calendarIdentifier) {
                    settings.excludedCalendarIds.append(calendar.calendarIdentifier)
                }
            }
        )
    }
}
