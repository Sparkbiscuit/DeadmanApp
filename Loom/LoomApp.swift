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
    @State private var showingCapture = false

    private var needsOnboarding: Bool {
        settingsArray.first.map { !$0.hasCompletedOnboarding } ?? false
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Custom shell (not TabView): the Hearthlight bar is a floating
            // blurred capsule with a proud FAB, which the system bar can't do.
            Group {
                switch selectedTab {
                case 0:
                    TaskListView(replanSummary: $replanSummary, sessionRequestTaskId: $sessionRequestTaskId)
                case 1:
                    ScheduleView()
                case 2:
                    WeaveView()
                default:
                    SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HearthTabBar(selectedTab: $selectedTab) {
                showingCapture = true
            }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .preferredColorScheme(.dark)
        .tint(Color.brand500)
        .sheet(isPresented: $showingCapture) {
            CaptureSheetView()
        }
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

    /// Blocks and sessions whose task is gone are damage left behind by
    /// SwiftData cascade deletes that didn't finish the job — they used to
    /// surface as "Unknown Task" rows scattered across the Schedule. Delete
    /// them on every foreground refresh so old damage heals itself too.
    private func sweepOrphans() {
        let blocks = (try? modelContext.fetch(FetchDescriptor<ScheduledBlock>())) ?? []
        let sessions = (try? modelContext.fetch(FetchDescriptor<WorkSession>())) ?? []
        var swept = 0
        for block in blocks where block.task == nil {
            modelContext.delete(block)
            swept += 1
        }
        for session in sessions where session.task == nil {
            modelContext.delete(session)
            swept += 1
        }
        if swept > 0 {
            try? modelContext.save()
        }
    }

    /// Foreground refresh: pull fresh calendar busy times, stamp out any due
    /// recurring tasks, replan missed blocks around everything, then mirror
    /// the result back out.
    private func refreshSchedule() {
        CalendarImportService.syncIfEnabled(context: modelContext)
        sweepOrphans()

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

// MARK: - Hearthlight tab bar

/// The floating hearth bar: a blurred capsule inset from the screen edges,
/// with an accent pill behind the active tab, a glowing dot beneath it, and
/// the capture FAB sitting slightly proud at the trailing end.
private struct HearthTabBar: View {
    @Binding var selectedTab: Int
    var onCapture: () -> Void

    private struct TabSpec {
        let index: Int
        let label: String
        let icon: String
    }

    private let tabs: [TabSpec] = [
        .init(index: 0, label: "Tasks", icon: "line.3.horizontal"),
        .init(index: 1, label: "Schedule", icon: "calendar"),
        .init(index: 2, label: "Weave", icon: "squareshape.split.3x3"),
        .init(index: 3, label: "Settings", icon: "gearshape")
    ]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tabs, id: \.index) { tab in
                tabButton(tab)
            }

            fab
                .padding(.leading, 4)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(Capsule().fill(Color(hex: 0x19191D).opacity(0.82)))
        )
        .overlay(Capsule().stroke(Color.white.opacity(0.09), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
        .padding(.horizontal, 20)
        .padding(.bottom, 4)
    }

    private func tabButton(_ tab: TabSpec) -> some View {
        let isActive = selectedTab == tab.index

        return Button {
            guard selectedTab != tab.index else { return }
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                selectedTab = tab.index
            }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: tab.icon)
                    .font(.system(size: 17, weight: .semibold))
                Text(tab.label)
                    .font(AppFont.caption(9))
            }
            .foregroundStyle(isActive ? Color.brand300 : Color.loomSubtle)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(isActive ? Color.brand500.opacity(0.16) : .clear)
            )
            .overlay(alignment: .bottom) {
                if isActive {
                    // A smudge of banked light under the active tab, not a dot.
                    Capsule()
                        .fill(Color.brand300)
                        .frame(width: 22, height: 4)
                        .blur(radius: 3)
                        .offset(y: 7)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.label)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }

    private var fab: some View {
        Button(action: onCapture) {
            Image(systemName: "plus")
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(LinearGradient.hearth, in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.14), lineWidth: 1))
                .shadow(color: Color.brand500.opacity(0.5), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .offset(y: -2)
        .accessibilityLabel("Capture a task")
    }
}
