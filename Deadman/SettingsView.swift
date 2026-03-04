import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var settingsArray: [UserSettings]

    private var settings: UserSettings {
        if let existing = settingsArray.first {
            return existing
        }
        let new = UserSettings()
        modelContext.insert(new)
        return new
    }

    var body: some View {
        NavigationStack {
            List {
                scheduleSection
                blockSizeSection
                bufferSection
                calendarSection
                aboutSection
            }
            .navigationTitle("Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            #endif
        }
    }

    // MARK: - Schedule Section

    private var scheduleSection: some View {
        Section {
            timePicker(
                label: "Wake time",
                icon: "sunrise.fill",
                color: .orange,
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
                color: .indigo,
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
            Text("Tasks will be scheduled between these hours. You'll be asked before scheduling overnight.")
        }
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
            Spacer()
            DatePicker("", selection: date, displayedComponents: .hourAndMinute)
                .labelsHidden()
        }
    }

    // MARK: - Block Size Section

    private var blockSizeSection: some View {
        Section {
            Stepper(value: Binding(
                get: { settings.minBlockMinutes },
                set: { settings.minBlockMinutes = $0 }
            ), in: 15...60, step: 15) {
                HStack {
                    Label("Minimum block", systemImage: "rectangle.compress.vertical")
                    Spacer()
                    Text(CountdownFormatter.effortString(minutes: settings.minBlockMinutes))
                        .font(AppFont.mono(14))
                        .foregroundStyle(Color.deadmanSubtle)
                }
            }

            Stepper(value: Binding(
                get: { settings.maxBlockMinutes },
                set: { settings.maxBlockMinutes = $0 }
            ), in: 60...180, step: 30) {
                HStack {
                    Label("Maximum block", systemImage: "rectangle.expand.vertical")
                    Spacer()
                    Text(CountdownFormatter.effortString(minutes: settings.maxBlockMinutes))
                        .font(AppFont.mono(14))
                        .foregroundStyle(Color.deadmanSubtle)
                }
            }
        } header: {
            Text("Block Size")
        } footer: {
            Text("Tasks are split into blocks within this range.")
        }
    }

    // MARK: - Buffer Section

    private var bufferSection: some View {
        Section {
            Stepper(value: Binding(
                get: { settings.deadlineBufferMinutes },
                set: { settings.deadlineBufferMinutes = $0 }
            ), in: 0...480, step: 30) {
                HStack {
                    Label("Deadline buffer", systemImage: "shield.fill")
                    Spacer()
                    Text(CountdownFormatter.effortString(minutes: settings.deadlineBufferMinutes))
                        .font(AppFont.mono(14))
                        .foregroundStyle(Color.deadmanSubtle)
                }
            }
        } header: {
            Text("Safety Buffer")
        } footer: {
            Text("Work blocks will be scheduled to finish this long before the actual deadline.")
        }
    }

    // MARK: - Calendar Section

    private var calendarSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { settings.exportToAppleCalendar },
                set: { settings.exportToAppleCalendar = $0 }
            )) {
                Label("Export to Apple Calendar", systemImage: "calendar")
            }
        } header: {
            Text("Calendar")
        } footer: {
            Text("One-way export only. Deadman manages all scheduling internally.")
        }
    }

    // MARK: - About Section

    private var aboutSection: some View {
        Section {
            HStack {
                Text("Version")
                Spacer()
                Text("1.0.0")
                    .foregroundStyle(Color.deadmanSubtle)
            }
        } header: {
            Text("About")
        }
    }
}
