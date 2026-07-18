import SwiftUI
import SwiftData
import OSLog
import Accessibility

/// All automatic rewrites of existing schedule blocks share this gate. A work
/// session owns its reservation until it records attendance; imports may still
/// land while the timer runs, but catch-up and conflict repair wait their turn.
enum AutomaticPlanRefreshPolicy {
    static func canRewriteSchedule(
        activeWorkSession: WorkSessionControlState?
    ) -> Bool {
        activeWorkSession == nil
    }
}

/// A journal is recoverable only while it still names a live task and remains
/// recent enough to be an interrupted session rather than abandoned state.
enum WorkSessionRecovery: Equatable {
    case restore(WorkSessionControlState)
    case discard
    case keep

    static func evaluate(
        journal: WorkSessionControlState?,
        taskExists: Bool?,
        now: Date
    ) -> WorkSessionRecovery {
        guard let journal, journal.taskID != nil else {
            return .discard
        }
        guard let taskExists else { return .keep }
        guard taskExists,
              now.timeIntervalSince(journal.startedAt) < 12 * 3600 else {
            return .discard
        }
        return .restore(journal)
    }
}

/// Runs only when Filuma presents its UI for the first time in this process.
/// Keeping the guard outside view identity prevents a later scene rebuild from
/// reconsidering a session that started after the initial foreground bootstrap.
@MainActor
private enum WorkSessionForegroundCleanup {
    private static var didRun = false

    static func runOnce(
        journal: WorkSessionControlState?,
        taskExists: Bool?,
        now: Date = Date()
    ) -> WorkSessionRecovery? {
        guard !didRun else { return nil }
        didRun = true
        let decision = WorkSessionRecovery.evaluate(
            journal: journal,
            taskExists: taskExists,
            now: now
        )
        switch decision {
        case .discard:
            WorkSessionActivityController.endAll()
        case .keep:
            // The lookup was unavailable, not negative — nothing was consumed,
            // so a later scene bootstrap may try again with a healthy store.
            didRun = false
        case .restore:
            break
        }
        return decision
    }
}

@main
struct FilumaApp: App {
    @UIApplicationDelegateAdaptor(FilumaAppDelegate.self) private var appDelegate

    private static let persistenceLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Filuma",
        category: "Persistence"
    )
    private static let uiTestingArgument = "-ui-testing"
    private static let uiTestingSkipOnboardingArgument = "-ui-testing-skip-onboarding"

    /// Store lives in the App Group so the widget can read it (SharedStore
    /// migrates any pre-1.2 sandbox store on first launch).
    private let container: ModelContainer
    private let usedFallback: Bool
    @State private var showingPersistenceWarning: Bool

    init() {
        let setup = Self.makeContainer()
        container = setup.container
        usedFallback = setup.usedFallback
        _showingPersistenceWarning = State(initialValue: setup.usedFallback)
    }

    private static func makeContainer() -> (container: ModelContainer, usedFallback: Bool) {
        if CommandLine.arguments.contains(uiTestingArgument) {
            return makeUITestingContainer()
        }

        do {
            return (try SharedStore.makeContainer(), false)
        } catch {
            // Last resort: an in-memory store beats a crash loop, and the
            // on-disk data stays untouched for the next launch to retry.
            let persistentError = error
            persistenceLogger.error(
                "Persistent store could not be opened: \(String(describing: persistentError), privacy: .public)"
            )
            let fallback = ModelConfiguration(isStoredInMemoryOnly: true)
            do {
                return (
                    try ModelContainer(for: SharedStore.schema, configurations: [fallback]),
                    true
                )
            } catch {
                fatalError(
                    "Filuma could not create a persistent or in-memory model container. "
                    + "Persistent error: \(persistentError). In-memory error: \(error)"
                )
            }
        }
    }

    /// UI tests get a brand-new store for every process so their first-launch
    /// state cannot depend on the developer's data or another test's run.
    private static func makeUITestingContainer() -> (container: ModelContainer, usedFallback: Bool) {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        do {
            let container = try ModelContainer(
                for: SharedStore.schema,
                configurations: [configuration]
            )
            if CommandLine.arguments.contains(uiTestingSkipOnboardingArgument) {
                let context = ModelContext(container)
                let settings = UserSettings()
                settings.hasCompletedOnboarding = true
                context.insert(settings)
                try context.save()
            }
            return (container, false)
        } catch {
            fatalError("Filuma could not create its UI-testing model container: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            MainTabView(usedFallback: usedFallback)
                .alert("Your data needs a breather", isPresented: $showingPersistenceWarning) {
                    Button("Got it", role: .cancel) {}
                } message: {
                    Text("Your data could not be opened — changes made now won’t be saved. Please close and reopen Filuma to try again.")
                }
        }
        .modelContainer(container)
    }
}

struct MainTabView: View {
    private struct CatchUpRefreshTrigger: Hashable {
        let date: Date?
        let generation: Int
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query private var settingsArray: [UserSettings]
    // `endTime` is computed, so SwiftData cannot use it in a fetch sort. The
    // lightweight policy below computes the minimum from this unsorted set.
    @Query private var scheduledBlocks: [ScheduledBlock]
    let usedFallback: Bool
    @State private var selectedTab = 0
    @State private var replanSummary = CatchUpSummary()
    @State private var sessionRequestTaskId: UUID?
    @State private var showingCapture = false
    @State private var catchUpRefreshGeneration = 0
    @State private var lastReplanAnnouncement: CatchUpSummary?
    @State private var lastReplanAnnouncementDate: Date?

    private var needsOnboarding: Bool {
        settingsArray.first.map { !$0.hasCompletedOnboarding } ?? false
    }

    private var catchUpRefreshTrigger: CatchUpRefreshTrigger {
        CatchUpRefreshTrigger(
            date: SchedulerService.nextCatchUpRefreshDate(blocks: scheduledBlocks),
            generation: catchUpRefreshGeneration
        )
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
        // A single cancellable wake-up at the next block boundary keeps an
        // open app honest without battery-heavy interval polling. SwiftData
        // changes automatically cancel and re-arm this for the new plan.
        .task(id: catchUpRefreshTrigger) {
            guard let refreshDate = catchUpRefreshTrigger.date else { return }
            let delay = max(0, refreshDate.timeIntervalSinceNow) + 0.5
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard scenePhase == .active,
                  WorkSessionControlStore.load() == nil else { return }
            refreshMissedBlocksAtBoundary()
        }
        .onReceive(NotificationCenter.default.publisher(for: .filumaOpenWorkSession)) { _ in
            consumePendingSessionRequest()
        }
        .onReceive(NotificationCenter.default.publisher(for: .workSessionControlDidChange)) { _ in
            // If a session held the reservation past its block boundary, its
            // clear notification re-arms the one-shot that deliberately stood
            // aside. Pause/resume writes keep a control snapshot and are quiet.
            guard WorkSessionControlStore.load() == nil,
                  let refreshDate = catchUpRefreshTrigger.date,
                  refreshDate <= Date() else { return }
            catchUpRefreshGeneration &+= 1
        }
        .onOpenURL { url in
            handleDeepLink(url)
        }
    }

    /// Widget taps arrive here: filuma://start-session/<taskId> drops straight
    /// into the work session timer; anything else just opens the app.
    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "filuma" else { return }
        if url.host == "start-session",
           let idString = url.pathComponents.dropFirst().first,
           let taskId = UUID(uuidString: idString) {
            requestWorkSession(for: taskId)
        } else {
            selectedTab = 0
        }
    }

    /// A block-start notification was tapped: jump to Tasks and open the timer.
    private func consumePendingSessionRequest() {
        guard let taskId = FilumaAppDelegate.pendingSessionTaskId else { return }
        FilumaAppDelegate.pendingSessionTaskId = nil
        requestWorkSession(for: taskId)
    }

    private func requestWorkSession(for taskId: UUID) {
        selectedTab = 0
        sessionRequestTaskId = taskId
    }

    private func bootstrap() {
        // A LiveActivityIntent may launch Filuma's process in the background
        // without opening a UI scene. Cleanup must therefore wait until the
        // user actually opens the app; doing it from FilumaApp.init would inspect
        // the App Group journal before the Lock Screen intent finished writing
        // it. The process-wide foreground guard also keeps a later rebuild of
        // the one supported scene from touching a newly started timer.
        let journal = WorkSessionControlStore.load()
        let taskExists: Bool?
        if usedFallback {
            taskExists = nil
        } else if let taskID = journal?.taskID {
            let descriptor = FetchDescriptor<FilumaTask>(
                predicate: #Predicate { $0.id == taskID && !$0.isComplete }
            )
            do {
                taskExists = try modelContext.fetchCount(descriptor) > 0
            } catch {
                taskExists = nil
            }
        } else {
            taskExists = false
        }
        if case .restore(let journal) = WorkSessionForegroundCleanup.runOnce(
            journal: journal,
            taskExists: taskExists
        ), let taskID = journal.taskID {
            requestWorkSession(for: taskID)
        }

        let settings = UserSettings.fetchOrCreate(in: modelContext)

        // Anyone with existing tasks predates the onboarding flow — don't
        // make them sit through it after an update.
        if !settings.hasCompletedOnboarding {
            let taskCount = (try? modelContext.fetchCount(FetchDescriptor<FilumaTask>())) ?? 0
            if taskCount > 0 {
                settings.hasCompletedOnboarding = true
            }
        }

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
        // Google runs async off the same hook; when its import lands changes
        // it replans on its own, mirroring the busy-change path below.
        GoogleCalendarService.foregroundSyncIfEnabled(context: modelContext)
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
        let canRewriteSchedule = AutomaticPlanRefreshPolicy.canRewriteSchedule(
            activeWorkSession: WorkSessionControlStore.load()
        )
        // A running timer owns its linked reservation until recordSession()
        // marks attendance. Foreground activation must not let catch-up delete
        // that block while the user is actively working it.
        if canRewriteSchedule {
            let tasks = (try? modelContext.fetch(FetchDescriptor<FilumaTask>())) ?? []
            let summary = SchedulerService.catchUpMissedBlocks(
                tasks: tasks,
                allBlocks: allBlocks,
                blockedTimes: blockedTimes,
                busyEvents: busyEvents,
                settings: settings,
                context: modelContext
            )
            if summary.adjustedTasks > 0 {
                presentReplanFeedback(summary)
            }
        }
        // Apple import is synchronous, so newly added or moved events are now
        // included. Reconcile conflicts and publish the final foreground plan
        // once, after recurring-task and missed-block work has also landed.
        PlanCoordinator.replanBusyTimeConflicts(
            context: modelContext,
            interactive: false
        )
    }

    /// Lightweight in-app catch-up used at a block boundary. Calendar imports
    /// remain foreground events; this path only replans when elapsed work made
    /// the local plan stale, then immediately updates widgets and nudges.
    private func refreshMissedBlocksAtBoundary() {
        // The timer owns its linked reservation until it records attendance.
        // Its stop path reconciles the task and re-arms this one-shot from the
        // resulting SwiftData change, so catch-up must not race that write.
        guard WorkSessionControlStore.load() == nil else { return }

        let settings = UserSettings.fetchOrCreate(in: modelContext)
        let tasks = (try? modelContext.fetch(FetchDescriptor<FilumaTask>())) ?? []
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
        guard summary.adjustedTasks > 0 else { return }

        // Persist before asking extensions to reload so they never observe the
        // previous plan during this prompt boundary refresh.
        try? modelContext.save()
        withAnimation(.easeInOut(duration: 0.2)) {
            presentReplanFeedback(summary)
        }
        PlanCoordinator.publishChange(context: modelContext, interactive: false)
    }

    /// Announces only actual automatic plan changes. The short duplicate gate
    /// prevents a scene activation and boundary wake-up arriving together from
    /// speaking the same result twice, while later refreshes remain audible.
    private func presentReplanFeedback(_ summary: CatchUpSummary) {
        replanSummary = summary

        let now = Date()
        if lastReplanAnnouncement == summary,
           let lastReplanAnnouncementDate,
           now.timeIntervalSince(lastReplanAnnouncementDate) < 10 {
            return
        }

        lastReplanAnnouncement = summary
        self.lastReplanAnnouncementDate = now
        AccessibilityNotification.Announcement(
            summary.accessibilityAnnouncement
        ).post()
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
        .frame(maxWidth: FilumaLayout.tabBarMaxWidth)
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
            .foregroundStyle(isActive ? Color.brand300 : Color.filumaSubtle)
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
