import Foundation
import EventKit
import OSLog
import SwiftData

/// One-way export of scheduled work blocks into a dedicated "Loom" calendar in
/// Apple Calendar. Loom owns that calendar outright: events are created, moved,
/// and removed to mirror the current schedule. Nothing is ever read back.
@MainActor
enum CalendarExportService {

    private static let store = EKEventStore()
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Loom",
        category: "CalendarExport"
    )

    private enum ExportError: Error {
        case noCalendarSource
    }

    /// How far ahead exported events are maintained (Google export shares it).
    nonisolated static let horizonDays = 60

    static func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    /// Reconcile the Loom calendar with the store, if export is enabled.
    /// Safe to call after any scheduling change; does nothing when disabled
    /// or when access is missing.
    static func syncIfEnabled(context: ModelContext) {
        let settings = UserSettings.fetchOrCreate(in: context)
        guard settings.exportToAppleCalendar else { return }
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return }
        do {
            try syncNow(context: context, settings: settings)
        } catch {
            logger.error("Calendar export failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Unconditional one-time push, regardless of the ongoing-export toggle —
    /// caller has verified access.
    static func syncNow(context: ModelContext, settings: UserSettings) throws {
        let calendar = try loomCalendar(settings: settings)

        let blockDescriptor = FetchDescriptor<ScheduledBlock>()
        let allBlocks = try context.fetch(blockDescriptor)

        let now = Date()
        let horizon = Calendar.current.date(byAdding: .day, value: horizonDays, to: now) ?? now

        // Blocks that should exist as events: active-task work that is
        // incomplete, upcoming, and inside the horizon.
        let exportable = allBlocks.filter {
            !$0.isComplete
                && $0.task?.isComplete == false
                && $0.endTime > now
                && $0.startTime < horizon
        }

        // Existing Loom-owned events within the horizon.
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-86400), end: horizon, calendars: [calendar]
        )
        let existingEvents = store.events(matching: predicate)
        var eventsById = Dictionary(
            existingEvents.compactMap { event in event.eventIdentifier.map { ($0, event) } },
            uniquingKeysWith: { first, _ in first }
        )

        var createdEvents: [(block: ScheduledBlock, event: EKEvent)] = []

        do {
            for block in exportable {
                let title = block.task?.title ?? "Loom block"
                let eventId = block.appleCalendarEventId
                let storedEvent = eventId.flatMap { eventsById[$0] ?? store.event(withIdentifier: $0) }
                let matchingEvent = storedEvent.flatMap { event in
                    event.calendar.calendarIdentifier == calendar.calendarIdentifier ? event : nil
                }

                if let eventId, let event = matchingEvent {
                    if event.title != title || event.startDate != block.startTime || event.endDate != block.endTime {
                        event.title = title
                        event.startDate = block.startTime
                        event.endDate = block.endTime
                        try store.save(event, span: .thisEvent, commit: false)
                    }
                    eventsById.removeValue(forKey: eventId)
                } else {
                    let event = EKEvent(eventStore: store)
                    event.calendar = calendar
                    event.title = title
                    event.startDate = block.startTime
                    event.endDate = block.endTime
                    event.notes = "Scheduled by Loom"
                    try store.save(event, span: .thisEvent, commit: false)
                    createdEvents.append((block, event))
                }
            }

            // Whatever is left in the calendar no longer matches a block — remove it.
            for (_, orphan) in eventsById {
                try store.remove(orphan, span: .thisEvent, commit: false)
            }

            try store.commit()
        } catch {
            // Drop any uncommitted EventKit changes before the next reconciliation.
            store.reset()
            throw error
        }

        // Event identifiers are only trustworthy after the batch commit succeeds.
        for (block, event) in createdEvents {
            block.appleCalendarEventId = event.eventIdentifier
        }
    }

    /// Remove the Loom calendar entirely (export switched off).
    static func removeExportedEvents(context: ModelContext) {
        let settings = UserSettings.fetchOrCreate(in: context)
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return }
        if let identifier = settings.loomCalendarIdentifier,
           let calendar = store.calendar(withIdentifier: identifier) {
            do {
                try store.removeCalendar(calendar, commit: true)
            } catch {
                logger.error("Calendar removal failed: \(String(describing: error), privacy: .public)")
                return
            }
        }
        settings.loomCalendarIdentifier = nil

        do {
            let blockDescriptor = FetchDescriptor<ScheduledBlock>()
            for block in try context.fetch(blockDescriptor) {
                block.appleCalendarEventId = nil
            }
        } catch {
            logger.error("Calendar identifier cleanup failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Internals

    private static func loomCalendar(settings: UserSettings) throws -> EKCalendar {
        if let identifier = settings.loomCalendarIdentifier,
           let existing = store.calendar(withIdentifier: identifier) {
            return existing
        }

        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = "Loom"
        calendar.cgColor = CGColor(red: 0xC1 / 255.0, green: 0x57 / 255.0, blue: 0x1F / 255.0, alpha: 1)
        calendar.source = store.defaultCalendarForNewEvents?.source
            ?? store.sources.first { $0.sourceType == .local }
        guard calendar.source != nil else { throw ExportError.noCalendarSource }

        try store.saveCalendar(calendar, commit: true)
        settings.loomCalendarIdentifier = calendar.calendarIdentifier
        return calendar
    }
}
