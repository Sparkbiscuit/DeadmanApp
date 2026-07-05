import SwiftUI
import SwiftData

@main
struct LoomApp: App {
    var body: some Scene {
        WindowGroup {
            MainTabView()
        }
        .modelContainer(for: [
            LoomTask.self,
            ScheduledBlock.self,
            WorkSession.self,
            BlockedTime.self,
            BusyEvent.self,
            UserSettings.self
        ])
    }
}

struct MainTabView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query private var settingsArray: [UserSettings]
    @State private var selectedTab = 0
    @State private var replanSummary = CatchUpSummary()

    private var needsOnboarding: Bool {
        settingsArray.first.map { !$0.hasCompletedOnboarding } ?? false
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            TaskListView(replanSummary: $replanSummary)
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
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                refreshSchedule()
            }
        }
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

    /// Foreground refresh: pull fresh calendar busy times, replan missed
    /// blocks around them, then mirror the result back out.
    private func refreshSchedule() {
        CalendarImportService.syncIfEnabled(context: modelContext)

        let settings = UserSettings.fetchOrCreate(in: modelContext)
        let tasks = (try? modelContext.fetch(FetchDescriptor<LoomTask>())) ?? []
        let allBlocks = (try? modelContext.fetch(FetchDescriptor<ScheduledBlock>())) ?? []
        let blockedTimes = (try? modelContext.fetch(FetchDescriptor<BlockedTime>())) ?? []
        let busyEvents = (try? modelContext.fetch(FetchDescriptor<BusyEvent>())) ?? []

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
    }
}
