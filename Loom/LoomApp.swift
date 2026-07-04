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
            UserSettings.self
        ])
    }
}

struct MainTabView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab = 0
    @State private var replannedCount = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            TaskListView(replannedCount: $replannedCount)
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
        .onAppear {
            _ = UserSettings.fetchOrCreate(in: modelContext)
            catchUp()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                catchUp()
            }
        }
    }

    /// Replan blocks that were missed while the app was away, then mirror
    /// the fresh schedule to Apple Calendar if export is on.
    private func catchUp() {
        let settings = UserSettings.fetchOrCreate(in: modelContext)
        let tasks = (try? modelContext.fetch(FetchDescriptor<LoomTask>())) ?? []
        let allBlocks = (try? modelContext.fetch(FetchDescriptor<ScheduledBlock>())) ?? []
        let blockedTimes = (try? modelContext.fetch(FetchDescriptor<BlockedTime>())) ?? []

        let replanned = SchedulerService.catchUpMissedBlocks(
            tasks: tasks,
            allBlocks: allBlocks,
            blockedTimes: blockedTimes,
            settings: settings,
            context: modelContext
        )
        if replanned > 0 {
            replannedCount = replanned
        }
        CalendarExportService.syncIfEnabled(context: modelContext)
    }
}
