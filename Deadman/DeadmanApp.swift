import SwiftUI
import SwiftData

@main
struct DeadmanApp: App {
    var body: some Scene {
        WindowGroup {
            MainTabView()
        }
        .modelContainer(for: [
            DeadmanTask.self,
            ScheduledBlock.self,
            WorkSession.self,
            BlockedTime.self,
            UserSettings.self
        ])
    }
}

struct MainTabView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var selectedTab = 0
    @State private var showBulkEntry = false

    var body: some View {
        TabView(selection: $selectedTab) {
            TaskListView()
                .tabItem {
                    Label("Tasks", systemImage: "checklist")
                }
                .tag(0)

            ScheduleView()
                .tabItem {
                    Label("Schedule", systemImage: "calendar")
                }
                .tag(1)

            // Bulk entry opens as a sheet from tab bar
            Color.clear
                .tabItem {
                    Label("Bulk Add", systemImage: "text.badge.plus")
                }
                .tag(2)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
                .tag(3)
        }
        .onChange(of: selectedTab) { oldValue, newValue in
            if newValue == 2 {
                showBulkEntry = true
                selectedTab = oldValue
            }
        }
        .sheet(isPresented: $showBulkEntry) {
            BulkEntryView()
        }
        .tint(Color.deadmanRed)
        .onAppear {
            ensureSettingsExist()
        }
    }

    private func ensureSettingsExist() {
        let descriptor = FetchDescriptor<UserSettings>()
        let count = (try? modelContext.fetchCount(descriptor)) ?? 0
        if count == 0 {
            modelContext.insert(UserSettings())
        }
    }
}
