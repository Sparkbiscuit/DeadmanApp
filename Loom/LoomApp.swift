import SwiftUI
import SwiftData

@main
struct LoomApp: App {
    @UIApplicationDelegateAdaptor(LoomAppDelegate.self) private var appDelegate

    /// Store lives in the App Group so the widget can read it (SharedStore
    /// migrates any pre-1.2 sandbox store on first launch).
    private let container: ModelContainer = {
        do {
            return try SharedStore.makeContainer()
        } catch {
            // Last resort: an in-memory store beats a crash loop, and the
            // on-disk data stays untouched for the next launch to retry.
            let fallback = ModelConfiguration(isStoredInMemoryOnly: true)
            return try! ModelContainer(for: SharedStore.schema, configurations: [fallback])
        }
    }()

    var body: some Scene {
        WindowGroup {
            MainTabView()
        }
        .modelContainer(container)
    }
}

struct MainTabView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query private var settingsArray: [UserSettings]
    @State private var selectedTab = 0
    @State private var replanSummary = CatchUpSummary()
    @State private var sessionRequestTaskId: UUID?

    private var needsOnboarding: Bool {
        settingsArray.first.map { !$0.hasCompletedOnboarding } ?? false
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            TaskListView(replanSummary: $replanSummary, sessionRequestTaskId: $sessionRequestTaskId)
                .tabItem {
                    Label("Tasks", systemImage: "checklist")
                }
                .tag(0)

            ScheduleView()
                .tabItem {
                    Label("Schedule", systemImage: "calendar")
                }
                .tag(1)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
                .tag(2)
        }
        .tint(Color.brand500)
        .fullScreenCover(isPresented: Binding(
            get: { needsOnboarding },
            set: { _ in } // dismissal only happens by completing the flow
        )) {
            if let settings = settingsArray.first {
                OnboardingView(settings: settings)
            }
        }
        .onAppear {
            bootstrap()
            consumePendingSessionRequest()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                refreshSchedule()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .loomOpenWorkSession)) { _ in
            consumePendingSessionRequest()
        }
        .onOpenURL { url in
            handleDeepLink(url)
        }
    }

    /// Widget taps arrive here: loom://start-session/<taskId> drops straight
    /// into the work session timer; anything else just opens the app.
    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "loom" else { return }
        selectedTab = 0
        if url.host == "start-session",
           let idString = url.pathComponents.dropFirst().first,
           let taskId = UUID(uuidString: idString) {
            sessionRequestTaskId = taskId
        }
    }

    /// A block-start notification was tapped: jump to Tasks and open the timer.
    private func consumePendingSessionRequest() {
        guard let taskId = LoomAppDelegate.pendingSessionTaskId else { return }
        LoomAppDelegate.pendingSessionTaskId = nil
        selectedTab = 0
        sessionRequestTaskId = taskId
    }

    private func bootstrap() {
        let settings = UserSettings.fetchOrCreate(in: modelContext)

        // Anyone with existing tasks predates the onboarding flow — don't
        // make them sit through it after an update.
        if !settings.hasCompletedOnboarding {
            let taskCount = (try? modelContext.fetchCount(FetchDescriptor<LoomTask>())) ?? 0
            if taskCount > 0 {
                settings.hasCompletedOnboarding = true
            }
        }

        // Sessions don't survive the app dying; clear any orphaned
        // Live Activity left on the Lock Screen.
        WorkSessionActivityController.endAll()
        refreshSchedule()
    }

    /// Foreground refresh: pull fresh calendar busy times, stamp out any due
    /// recurring tasks, replan missed blocks around everything, then mirror
    /// the result back out.
    private func refreshSchedule() {
        CalendarImportService.syncIfEnabled(context: modelContext)

        let settings = UserSettings.fetchOrCreate(in: modelContext)
        let templates = (try? modelContext.fetch(FetchDescriptor<TaskTemplate>())) ?? []
        var allBlocks = (try? modelContext.fetch(FetchDescriptor<ScheduledBlock>())) ?? []
        let blockedTimes = (try? modelContext.fetch(FetchDescriptor<BlockedTime>())) ?? []
        let busyEvents = (try? modelContext.fetch(FetchDescriptor<BusyEvent>())) ?? []

        let created = SchedulerService.materializeRecurringTasks(
            templates: templates,
            allBlocks: allBlocks,
            blockedTimes: blockedTimes,
            busyEvents: busyEvents,
            settings: settings,
            context: modelContext
        )
        if created > 0 {
            allBlocks = (try? modelContext.fetch(FetchDescriptor<ScheduledBlock>())) ?? []
        }
        let tasks = (try? modelContext.fetch(FetchDescriptor<LoomTask>())) ?? []

        let summary = SchedulerService.catchUpMissedBlocks(
            tasks: tasks,
            allBlocks: allBlocks,
            blockedTimes: blockedTimes,
            busyEvents: busyEvents,
            settings: settings,
            context: modelContext
        )
        if summary.replannedTasks > 0 {
            replanSummary = summary
        }
        CalendarExportService.syncIfEnabled(context: modelContext)
        // Not user-initiated: never trigger the permission prompt from here.
        scheduleDidChange(context: modelContext, interactive: false)
    }
}
