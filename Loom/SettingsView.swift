import SwiftUI
import SwiftData
import EventKit

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var settingsArray: [UserSettings]
    @State private var showCalendarDeniedAlert = false

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
            Text("Tasks are scheduled between these hours. A sleep time past midnight is fine — Loom treats it as the next day.")
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
            Text("Recurring events — classes, meetings, commutes — that Loom schedules around.")
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
        } header: {
            Text("Safety Buffer")
        } footer: {
            Text("Work blocks are scheduled to finish this long before the actual deadline.")
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
                Label("Export to Apple Calendar", systemImage: "calendar")
                    .font(AppFont.body(15))
            }
            .tint(Color.brand500)
        } header: {
            Text("Calendar")
        } footer: {
            Text("One-way export into a dedicated \u{201C}Loom\u{201D} calendar. Loom manages all scheduling internally.")
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

    // MARK: - About

    private var aboutSection: some View {
        Section {
            HStack {
                Text("Version")
                    .font(AppFont.body(15))
                Spacer()
                Text("1.0.0")
                    .font(AppFont.body(14))
                    .foregroundStyle(Color.loomSubtle)
            }
        } header: {
            Text("About")
        }
        .listRowBackground(Color.loomSurface)
    }
}
