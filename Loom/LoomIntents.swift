import AppIntents
import Foundation
import SwiftData

// MARK: - Capture from anywhere

/// Capture a task without opening the app: Siri, Shortcuts, Spotlight, the
/// Action button. Capture friction is the core ADHD failure mode — the thought
/// "I should write that down" has a half-life of seconds, so the path from
/// thought to scheduled plan has to survive a pocket.
struct CaptureTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "Capture a Task"
    static var description = IntentDescription(
        "Add a task to Loom. It gets an hour's estimate, a deadline, and real time blocks on your schedule — refine it in the app later if you want.",
        categoryName: "Capture"
    )

    @Parameter(title: "Task", requestValueDialog: "What needs to get done?")
    var taskTitle: String

    @Parameter(title: "Due in (days)", default: 3, inclusiveRange: (1, 60))
    var daysUntilDue: Int

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let trimmed = taskTitle.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return .result(dialog: "Nothing captured — the task needs a name.")
        }

        let container = try SharedStore.makeContainer()
        let context = ModelContext(container)
        let settings = UserSettings.fetchOrCreate(in: context)

        let deadline = Date().addingTimeInterval(Double(daysUntilDue) * 86_400)
        let task = LoomTask(
            title: trimmed,
            context: .personal,
            deadline: deadline,
            effortMinutes: 60
        )
        context.insert(task)

        let allBlocks = (try? context.fetch(FetchDescriptor<ScheduledBlock>())) ?? []
        let blockedTimes = (try? context.fetch(FetchDescriptor<BlockedTime>())) ?? []
        let busyEvents = (try? context.fetch(FetchDescriptor<BusyEvent>())) ?? []

        let result = SchedulerService.schedule(
            task: task,
            allBlocks: allBlocks,
            blockedTimes: blockedTimes,
            busyEvents: busyEvents,
            settings: settings,
            from: Date().addingTimeInterval(TimeInterval(settings.startBufferMinutes * 60))
        )
        SchedulerService.insert(result: result, into: context)
        try context.save()
        scheduleDidChange(context: context, interactive: false)

        switch result {
        case .success(let blocks), .partialFit(let blocks, _):
            if let first = blocks.min(by: { $0.startTime < $1.startTime }) {
                return .result(dialog: "Captured. First block \(Self.relative(first.startTime)).")
            }
            return .result(dialog: "Captured and scheduled.")
        case .noSlots:
            return .result(dialog: "Captured, but nothing fits before the deadline — open Loom to make room.")
        }
    }

    private static func relative(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = TimeFormatter.clock.string(from: date)
        if calendar.isDateInToday(date) { return "today at \(time)" }
        if calendar.isDateInTomorrow(date) { return "tomorrow at \(time)" }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        return "\(formatter.string(from: date)) at \(time)"
    }
}

// MARK: - App Shortcuts

/// Zero-setup phrases: these work with Siri and appear in the Shortcuts app
/// (and on the Action button) without the user configuring anything.
struct LoomShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CaptureTaskIntent(),
            phrases: [
                "Capture a task in \(.applicationName)",
                "Add a task to \(.applicationName)",
                "Capture in \(.applicationName)"
            ],
            shortTitle: "Capture Task",
            systemImageName: "plus.circle.fill"
        )
    }
}
