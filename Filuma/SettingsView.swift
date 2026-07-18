import SwiftUI
import SwiftData
import EventKit

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query private var settingsArray: [UserSettings]
    @State private var showCalendarDeniedAlert = false
    @State private var showNotificationsDeniedAlert = false
    @State private var didPushNow = false
    @State private var showPushNowError = false
    @State private var exportFileURL: URL?
    @State private var isConnectingGoogle = false
    @State private var showGoogleConnectFailed = false
    @State private var confirmGoogleDisconnect = false
    @State private var planningPreferencesDirty = false
    @State private var planningRebuildTask: Task<Void, Never>?

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
            .toolbar(.hidden, for: .navigationBar)
        }
        .onDisappear(perform: flushPlanningRebuild)
        .onChange(of: scenePhase) { oldPhase, newPhase in
            guard oldPhase == .active, newPhase != .active else { return }
            flushPlanningRebuild()
        }
    }

    private func settingsList(_ settings: UserSettings) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HearthTitle(text: "Settings", size: 28)
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 18)

                hearthSection
                dailyScheduleSection(settings)
                planningSection(settings)
                nudgeSection(settings)
                calendarSection(settings)
                googleCalendarSection(settings)
                aboutSection

                Text("Filuma \(appVersion) · woven with care")
                    .font(AppFont.monoMedium(11))
                    .foregroundStyle(Color.filumaFaint)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
            }
            .padding(.bottom, 110)
            .frame(maxWidth: FilumaLayout.readableContentMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .hearthScreen(topGlow: 0.18, bottomGlow: 0.24)
        .alert("Calendar access needed", isPresented: $showCalendarDeniedAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Enable calendar access for Filuma in Settings to export your work blocks.")
        }
        .alert("Notifications are off", isPresented: $showNotificationsDeniedAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Enable notifications for Filuma in Settings to get block start nudges.")
        }
        .alert("Couldn't connect Google", isPresented: $showGoogleConnectFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Something went wrong signing in to Google. Check your connection and try again.")
        }
    }

    // MARK: - Hearth (accent hue)

    /// The hearth itself: which color the flame burns. Every glow, ring,
    /// ember, and gradient in the app follows this choice live.
    private var hearthSection: some View {
        SettingsGroup(title: "Hearth", footer: "The color your hearth burns. Everything warm follows it.") {
            SettingsRow(icon: "flame.fill", tint: .brand500, label: "Flame") {
                HStack(spacing: 2) {
                    ForEach(HearthAccent.allCases) { accent in
                        AccentSwatch(
                            accent: accent,
                            isSelected: HearthTheme.shared.accent == accent
                        ) {
                            withAnimation(.easeInOut(duration: 0.35)) {
                                HearthTheme.shared.accent = accent
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Daily Schedule

    private func dailyScheduleSection(_ settings: UserSettings) -> some View {
        SettingsGroup(
            title: "Daily Schedule",
            footer: "Tasks are scheduled between these hours. A sleep time past midnight is fine; Filuma treats it as the next day."
        ) {
            SettingsRow(icon: "sunrise.fill", tint: .workDisplay, label: "Wake time") {
                timePicker(
                    hour: planningPreferenceBinding(
                        get: { settings.wakeHour },
                        set: { settings.wakeHour = $0 }
                    ),
                    minute: planningPreferenceBinding(
                        get: { settings.wakeMinute },
                        set: { settings.wakeMinute = $0 }
                    )
                )
                .accessibilityLabel("Wake time")
            }
            SettingsRow(icon: "moon.fill", tint: .schoolDisplay, label: "Sleep time") {
                timePicker(
                    hour: planningPreferenceBinding(
                        get: { settings.sleepHour },
                        set: { settings.sleepHour = $0 }
                    ),
                    minute: planningPreferenceBinding(
                        get: { settings.sleepMinute },
                        set: { settings.sleepMinute = $0 }
                    )
                )
                .accessibilityLabel("Sleep time")
            }
        }
    }

    private func timePicker(hour: Binding<Int>, minute: Binding<Int>) -> some View {
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

        return DatePicker("", selection: date, displayedComponents: .hourAndMinute)
            .labelsHidden()
    }

    // MARK: - Planning

    private func planningSection(_ settings: UserSettings) -> some View {
        SettingsGroup(
            title: "Planning",
            footer: "Tasks are split into blocks within the size range. The focus limit caps how much work lands on any single day; buffers keep plans honest around deadlines and fresh starts."
        ) {
            stepperRow(
                icon: "gauge.with.needle", tint: .brand300, label: "Daily focus limit",
                value: planningPreferenceBinding(
                    get: { settings.dailyFocusMinutes },
                    set: { settings.dailyFocusMinutes = $0 }
                ),
                range: 0...720, step: 30,
                display: settings.dailyFocusMinutes == 0
                    ? "Off"
                    : CountdownFormatter.effortString(minutes: settings.dailyFocusMinutes)
            )
            stepperRow(
                icon: "rectangle.compress.vertical", tint: .schoolDisplay, label: "Minimum block",
                value: planningPreferenceBinding(
                    get: { settings.minBlockMinutes },
                    set: { settings.minBlockMinutes = $0 }
                ),
                range: 15...60, step: 15,
                display: CountdownFormatter.effortString(minutes: settings.minBlockMinutes)
            )
            stepperRow(
                icon: "rectangle.expand.vertical", tint: .schoolDisplay, label: "Maximum block",
                value: planningPreferenceBinding(
                    get: { settings.maxBlockMinutes },
                    set: { settings.maxBlockMinutes = $0 }
                ),
                range: 60...180, step: 30,
                display: CountdownFormatter.effortString(minutes: settings.maxBlockMinutes)
            )
            stepperRow(
                icon: "shield.fill", tint: .personalDisplay, label: "Deadline buffer",
                value: planningPreferenceBinding(
                    get: { settings.deadlineBufferMinutes },
                    set: { settings.deadlineBufferMinutes = $0 }
                ),
                range: 0...480, step: 30,
                display: CountdownFormatter.effortString(minutes: settings.deadlineBufferMinutes)
            )
            stepperRow(
                icon: "hourglass.bottomhalf.filled", tint: .personalDisplay, label: "Start buffer",
                value: planningPreferenceBinding(
                    get: { settings.startBufferMinutes },
                    set: { settings.startBufferMinutes = $0 }
                ),
                range: 0...60, step: 5,
                display: settings.startBufferMinutes == 0
                    ? "None"
                    : CountdownFormatter.effortString(minutes: settings.startBufferMinutes)
            )
        }
    }

    private func stepperRow(
        icon: String,
        tint: Color,
        label: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        step: Int,
        display: String
    ) -> some View {
        SettingsRow(icon: icon, tint: tint, label: label) {
            HStack(spacing: 10) {
                Text(display)
                    .font(AppFont.mono(13))
                    .foregroundStyle(Color.filumaSubtle)
                    .accessibilityHidden(true)
                Stepper("", value: value, in: range, step: step)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel(label)
                    .accessibilityValue(display)
            }
        }
    }

    /// Planning controls can emit several values while a wheel or stepper is
    /// moving. A single trailing rebuild keeps those edits responsive while
    /// still committing the final preference promptly.
    private func planningPreferenceBinding(
        get: @escaping () -> Int,
        set: @escaping (Int) -> Void
    ) -> Binding<Int> {
        Binding(
            get: get,
            set: { newValue in
                guard newValue != get() else { return }
                set(newValue)
                queuePlanningRebuild()
            }
        )
    }

    private func queuePlanningRebuild() {
        planningPreferencesDirty = true
        planningRebuildTask?.cancel()
        planningRebuildTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(650))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            planningRebuildTask = nil
            guard planningPreferencesDirty else { return }
            planningPreferencesDirty = false
            PlanCoordinator.rebuildAfterPlanningPreferencesChange(context: modelContext)
        }
    }

    private func flushPlanningRebuild() {
        planningRebuildTask?.cancel()
        planningRebuildTask = nil
        guard planningPreferencesDirty else { return }
        planningPreferencesDirty = false
        PlanCoordinator.rebuildAfterPlanningPreferencesChange(context: modelContext)
    }

    // MARK: - Nudges

    private func nudgeSection(_ settings: UserSettings) -> some View {
        SettingsGroup(
            title: "Nudges",
            footer: "Block nudges fire when each work block begins, so the plan interrupts the scroll instead of waiting politely inside the app. The morning preview (30 minutes after wake time) pre-loads the day's shape; the evening wrap-up closes it out and names tomorrow's first block."
        ) {
            SettingsRow(icon: "bell.badge.fill", tint: .brand300, label: "Block start nudges") {
                Toggle("Block start nudges", isOn: Binding(
                    get: { settings.blockRemindersEnabled },
                    set: { enabled in setBlockReminders(enabled, settings: settings) }
                ))
                .labelsHidden()
                .toggleStyle(HearthToggleStyle())
            }

            if settings.blockRemindersEnabled {
                stepperRow(
                    icon: "clock.badge", tint: .brand300, label: "Early heads-up",
                    value: Binding(
                        get: { settings.blockReminderLeadMinutes },
                        set: {
                            settings.blockReminderLeadMinutes = $0
                            BlockNotificationService.resync(context: modelContext)
                        }
                    ),
                    range: 0...15, step: 5,
                    display: settings.blockReminderLeadMinutes == 0
                        ? "Off"
                        : "\(settings.blockReminderLeadMinutes) min"
                )
            }

            SettingsRow(icon: "sun.horizon.fill", tint: .workDisplay, label: "Morning preview") {
                Toggle("Morning preview", isOn: notificationToggleBinding(
                    get: { settings.morningPreviewEnabled },
                    set: { settings.morningPreviewEnabled = $0 }
                ))
                .labelsHidden()
                .toggleStyle(HearthToggleStyle())
            }

            SettingsRow(icon: "moon.stars.fill", tint: .schoolDisplay, label: "Evening wrap-up") {
                Toggle("Evening wrap-up", isOn: notificationToggleBinding(
                    get: { settings.eveningReviewEnabled },
                    set: { settings.eveningReviewEnabled = $0 }
                ))
                .labelsHidden()
                .toggleStyle(HearthToggleStyle())
            }

            if settings.eveningReviewEnabled {
                SettingsRow(icon: "clock.fill", tint: .filumaSubtle, label: "Wrap-up time") {
                    timePicker(
                        hour: Binding(
                            get: { settings.eveningReviewHour },
                            set: {
                                settings.eveningReviewHour = $0
                                BlockNotificationService.resync(context: modelContext)
                            }
                        ),
                        minute: Binding(
                            get: { settings.eveningReviewMinute },
                            set: {
                                settings.eveningReviewMinute = $0
                                BlockNotificationService.resync(context: modelContext)
                            }
                        )
                    )
                    .accessibilityLabel("Wrap-up time")
                }
            }
        }
    }

    /// A notification-backed toggle: turning it on asks for permission first
    /// and re-syncs; turning it off just re-syncs.
    private func notificationToggleBinding(
        get: @escaping () -> Bool,
        set: @escaping (Bool) -> Void
    ) -> Binding<Bool> {
        Binding(
            get: get,
            set: { enabled in
                if enabled {
                    Task { @MainActor in
                        let granted = await NotificationService.requestAuthorization()
                        if granted {
                            set(true)
                            BlockNotificationService.resync(context: modelContext)
                        } else {
                            set(false)
                            showNotificationsDeniedAlert = true
                        }
                    }
                } else {
                    set(false)
                    BlockNotificationService.resync(context: modelContext)
                }
            }
        )
    }

    private func setBlockReminders(_ enabled: Bool, settings: UserSettings) {
        if enabled {
            Task { @MainActor in
                let granted = await NotificationService.requestAuthorization()
                if granted {
                    settings.blockRemindersEnabled = true
                    BlockNotificationService.resync(context: modelContext)
                } else {
                    settings.blockRemindersEnabled = false
                    showNotificationsDeniedAlert = true
                }
            }
        } else {
            settings.blockRemindersEnabled = false
            BlockNotificationService.resync(context: modelContext)
        }
    }

    // MARK: - Calendar

    private func calendarSection(_ settings: UserSettings) -> some View {
        SettingsGroup(
            title: "Calendar",
            footer: "Blocked times are recurring windows (classes, meetings, commutes) Filuma schedules around. Export mirrors your blocks into a dedicated \u{201C}Filuma\u{201D} calendar; import treats other calendars' events as busy time. They never become tasks."
        ) {
            NavigationLink {
                BlockedTimeView()
            } label: {
                SettingsRow(icon: "lock.fill", tint: .filumaSubtle, label: "Blocked Times") {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.filumaFaint)
                }
            }
            .buttonStyle(.plain)

            SettingsRow(icon: "calendar.badge.clock", tint: .schoolDisplay, label: "Import busy times") {
                Toggle("Import busy times from Apple Calendar", isOn: Binding(
                    get: { settings.importFromAppleCalendar },
                    set: { enabled in setCalendarImport(enabled, settings: settings) }
                ))
                .labelsHidden()
                .toggleStyle(HearthToggleStyle())
            }

            if settings.importFromAppleCalendar {
                NavigationLink {
                    CalendarPickerView(settings: settings)
                } label: {
                    SettingsRow(icon: "list.bullet", tint: .schoolDisplay, label: "Calendars") {
                        HStack(spacing: 8) {
                            Text(includedCalendarsLabel(settings))
                                .font(AppFont.mono(13))
                                .foregroundStyle(Color.filumaSubtle)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.filumaFaint)
                        }
                    }
                }
                .buttonStyle(.plain)
            }

            SettingsRow(icon: "arrow.up", tint: .schoolDisplay, label: "Export blocks to Calendar") {
                Toggle("Export blocks to Apple Calendar", isOn: Binding(
                    get: { settings.exportToAppleCalendar },
                    set: { enabled in setCalendarExport(enabled, settings: settings) }
                ))
                .labelsHidden()
                .toggleStyle(HearthToggleStyle())
            }

            Button {
                pushBlocksNow(settings: settings)
            } label: {
                SettingsRow(icon: "arrow.up.circle", tint: .brand300, label: "Push blocks to Calendar now", labelTint: .brand300) {
                    if didPushNow {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.personalDisplay)
                    } else if showPushNowError {
                        Text("Couldn't reach Calendar")
                            .font(AppFont.caption(12))
                            .foregroundStyle(Color.filumaRed)
                    }
                }
            }
            .buttonStyle(.plain)
        }
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
        withAnimation {
            didPushNow = false
            showPushNowError = false
        }
        Task { @MainActor in
            let granted = await CalendarExportService.requestAccess()
            if granted {
                do {
                    try CalendarExportService.syncNow(context: modelContext, settings: settings)
                    withAnimation {
                        showPushNowError = false
                        didPushNow = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        withAnimation { didPushNow = false }
                    }
                } catch {
                    withAnimation {
                        didPushNow = false
                        showPushNowError = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        withAnimation { showPushNowError = false }
                    }
                }
            } else {
                showCalendarDeniedAlert = true
            }
        }
    }

    // MARK: - Google Calendar

    /// Google Calendar, treated the same as the Apple pair: one connect
    /// button, then the identical import/export toggles. Connection state
    /// lives in the Keychain; `googleAccountEmail` mirrors it for display.
    private func googleCalendarSection(_ settings: UserSettings) -> some View {
        SettingsGroup(
            title: "Google Calendar",
            footer: settings.googleAccountEmail == nil
                ? "Sign in once and Google Calendar joins the filuma: its events become busy time Filuma schedules around, and export mirrors your blocks into your primary Google calendar. Events never become tasks."
                : "Import treats Google events as busy time; export mirrors your blocks into your primary Google calendar, marked so they're never re-imported."
        ) {
            if let email = settings.googleAccountEmail {
                SettingsRow(icon: "person.crop.circle.fill", tint: .personalDisplay, label: email) {
                    Button("Disconnect") {
                        confirmGoogleDisconnect = true
                    }
                    .font(AppFont.caption(13))
                    .foregroundStyle(Color.filumaRed)
                    .buttonStyle(.plain)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel("Disconnect Google Calendar")
                }
                .confirmationDialog("Disconnect Google Calendar?", isPresented: $confirmGoogleDisconnect, titleVisibility: .visible) {
                    Button("Disconnect", role: .destructive) {
                        disconnectGoogle()
                    }
                    Button("Stay connected", role: .cancel) {}
                } message: {
                    Text("Imported Google events are removed and your schedule replans around the time they free up.")
                }

                if settings.googleNeedsReconnect {
                    Button {
                        connectGoogle(settings)
                    } label: {
                        SettingsRow(
                            icon: "exclamationmark.arrow.circlepath",
                            tint: .filumaRed,
                            label: "Reconnect Google",
                            labelTint: .filumaRed
                        ) {
                            if isConnectingGoogle {
                                ProgressView()
                            } else {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color.filumaFaint)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isConnectingGoogle)
                }

                SettingsRow(icon: "calendar.badge.clock", tint: .workDisplay, label: "Import busy times") {
                    Toggle("Import busy times from Google Calendar", isOn: Binding(
                        get: { settings.importFromGoogleCalendar },
                        set: { enabled in setGoogleImport(enabled, settings: settings) }
                    ))
                    .labelsHidden()
                    .toggleStyle(HearthToggleStyle())
                }

                SettingsRow(icon: "arrow.up", tint: .workDisplay, label: "Export blocks to Google") {
                    Toggle("Export blocks to Google Calendar", isOn: Binding(
                        get: { settings.exportToGoogleCalendar },
                        set: { enabled in setGoogleExport(enabled, settings: settings) }
                    ))
                    .labelsHidden()
                    .toggleStyle(HearthToggleStyle())
                }
            } else {
                Button {
                    connectGoogle(settings)
                } label: {
                    SettingsRow(
                        icon: "link",
                        tint: .brand300,
                        label: "Connect Google Calendar",
                        labelTint: .brand300
                    ) {
                        if isConnectingGoogle {
                            ProgressView()
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(isConnectingGoogle)
            }
        }
    }

    private func connectGoogle(_ settings: UserSettings) {
        guard !isConnectingGoogle else { return }
        isConnectingGoogle = true
        Task { @MainActor in
            defer { isConnectingGoogle = false }
            do {
                let tokens = try await GoogleOAuth.shared.connect()
                settings.googleAccountEmail = tokens.email ?? "Google account"
                settings.googleNeedsReconnect = false
                settings.googleSyncToken = nil
                // Connecting is the ask to import; export stays opt-in.
                settings.importFromGoogleCalendar = true
                await GoogleCalendarService.importNow(context: modelContext, settings: settings)
            } catch GoogleAuthError.cancelled {
                // The user backed out of the consent screen — not an error.
            } catch {
                showGoogleConnectFailed = true
            }
        }
    }

    private func disconnectGoogle() {
        GoogleCalendarService.disconnect(context: modelContext)
    }

    private func setGoogleImport(_ enabled: Bool, settings: UserSettings) {
        settings.importFromGoogleCalendar = enabled
        // Either direction invalidates the incremental cursor: re-enabling
        // must start from a full window fetch.
        settings.googleSyncToken = nil
        if enabled {
            Task { @MainActor in
                await GoogleCalendarService.importNow(context: modelContext, settings: settings)
            }
        } else {
            GoogleCalendarService.removeImportedEvents(context: modelContext)
            replanAfterBusyChange(context: modelContext)
        }
    }

    private func setGoogleExport(_ enabled: Bool, settings: UserSettings) {
        settings.exportToGoogleCalendar = enabled
        if enabled {
            Task { @MainActor in
                await GoogleCalendarService.exportNow(context: modelContext, settings: settings)
            }
        } else {
            GoogleCalendarService.removeExportedEvents(context: modelContext)
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        SettingsGroup(
            title: "About",
            footer: "Export writes everything Filuma knows — tasks, blocks, sessions, reminders, history — to a plain JSON file. Your data is yours."
        ) {
            SettingsRow(icon: "info.circle", tint: .filumaSubtle, label: "Version") {
                Text(appVersion)
                    .font(AppFont.monoMedium(13))
                    .foregroundStyle(Color.filumaSubtle)
            }

            if let url = exportFileURL {
                ShareLink(item: url) {
                    SettingsRow(icon: "square.and.arrow.up", tint: .brand300, label: "Share the export", labelTint: .brand300) {
                        EmptyView()
                    }
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    exportFileURL = try? DataExporter.writeExportFile(context: modelContext)
                } label: {
                    SettingsRow(icon: "shippingbox", tint: .brand300, label: "Export my data", labelTint: .brand300) {
                        EmptyView()
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var appVersion: String {
        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0"
        let build = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "1"
        return "\(version) (\(build))"
    }
}

// MARK: - Group container

/// A Hearthlight settings section: caption header, 18pt rounded container,
/// hairline dividers between rows, quiet footer.
private struct SettingsGroup<Content: View>: View {
    let title: String
    var footer: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(AppFont.settingsSectionHeader())
                .foregroundStyle(Color.filumaSubtle)
                .kerning(1.2)
                .padding(.leading, 4)

            VStack(spacing: 0) {
                Group(subviews: content) { subviews in
                    ForEach(Array(subviews.enumerated()), id: \.offset) { index, subview in
                        if index > 0 {
                            Divider()
                                .overlay(Color.white.opacity(0.05))
                                .padding(.leading, 56)
                        }
                        subview
                    }
                }
            }
            .background(Color.filumaSurface)
            .clipShape(RoundedRectangle(cornerRadius: FilumaRadius.group, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: FilumaRadius.group, style: .continuous)
                    .stroke(Color.filumaBorder, lineWidth: 1)
            )

            if let footer {
                Text(footer)
                    .font(AppFont.body(12))
                    .foregroundStyle(Color.filumaFaint)
                    .padding(.horizontal, 4)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 22)
    }
}

// MARK: - Row

/// Icon tile + label + trailing control, the Hearthlight settings row.
private struct SettingsRow<Trailing: View>: View {
    let icon: String
    let tint: Color
    let label: String
    var labelTint: Color = .filumaText
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tint.opacity(0.14))
                    .frame(width: 30, height: 30)
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(tint)
            }
            .accessibilityHidden(true)

            Text(label)
                .font(AppFont.settingsRowLabel())
                .foregroundStyle(labelTint)

            Spacer(minLength: 8)

            trailing
        }
        .padding(.horizontal, 14)
        // Controls may be visually smaller, but every row remains at least a
        // comfortable 44pt target without making the existing cards taller.
        .padding(.vertical, 5)
        .frame(minHeight: 54)
        .contentShape(Rectangle())
    }
}

// MARK: - Accent swatch

private struct AccentSwatch: View {
    let accent: HearthAccent
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [accent.soft, accent.color],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 24, height: 24)
                .overlay(
                    Circle()
                        .stroke(isSelected ? accent.hi : Color.white.opacity(0.1), lineWidth: 2)
                )
                .shadow(color: isSelected ? accent.color.opacity(0.6) : .clear, radius: 8)
        }
        .buttonStyle(.plain)
        .frame(width: 44, height: 44)
        .contentShape(Circle())
        .accessibilityLabel("\(accent.displayName) flame")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
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
                                    .font(AppFont.settingsRowLabel())
                                    .foregroundStyle(Color.filumaText)
                            }
                        }
                        .toggleStyle(HearthToggleStyle())
                    }
                } header: {
                    Text(group.source.uppercased())
                        .font(AppFont.settingsSectionHeader())
                        .foregroundStyle(Color.filumaSubtle)
                        .kerning(1.2)
                }
                .listRowBackground(Color.filumaSurface)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.filumaBackground)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Calendars")
                    .font(AppFont.heading(16))
                    .foregroundStyle(Color.filumaText)
            }
        }
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
        return .filumaFaint
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
