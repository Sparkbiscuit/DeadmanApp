import Foundation
import EventKit
import SwiftData

/// One-way import of Apple Calendar events as `BusyEvent`s — busy windows the
/// scheduler works around. Events never become tasks. Re-import upserts on the
/// event identifier, so repeated syncs update rather than duplicate.
@MainActor
enum CalendarImportService {

    private static let store = EKEventStore()

    /// How far ahead imported events are mirrored (Google import shares it).
    nonisolated static let horizonDays = 30

    /// Mirror Apple Calendar into BusyEvents, if import is enabled and access
    /// was granted. Safe to call on every foreground.
    static func syncIfEnabled(context: ModelContext) {
        let settings = UserSettings.fetchOrCreate(in: context)
        guard settings.importFromAppleCalendar else { return }
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return }
        syncNow(context: context, settings: settings)
    }

    /// Unconditional sync — caller has verified access.
    static func syncNow(context: ModelContext, settings: UserSettings) {
        let now = Date()
        guard let horizon = Calendar.current.date(byAdding: .day, value: horizonDays, to: now) else { return }

        // Every calendar except Loom's own export calendar (feedback-loop guard)
        // and any calendar the user excluded.
        let excluded = Set(settings.excludedCalendarIds)
        let calendars = store.calendars(for: .event).filter { calendar in
            calendar.calendarIdentifier != settings.loomCalendarIdentifier
                && calendar.title != "Loom"
                && !excluded.contains(calendar.calendarIdentifier)
        }

        let descriptor = FetchDescriptor<BusyEvent>()
        let existing = ((try? context.fetch(descriptor)) ?? [])
            .filter { $0.source == .appleCalendar }

        guard !calendars.isEmpty else {
            // Everything excluded: clear whatever was imported before.
            for event in existing { context.delete(event) }
            return
        }

        let predicate = store.predicateForEvents(withStart: now, end: horizon, calendars: calendars)
        let events = store.events(matching: predicate).filter { !$0.isAllDay }

        var existingById = Dictionary(
            existing.map { ($0.sourceId, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        for event in events {
            guard let identifier = event.eventIdentifier,
                  let start = event.startDate,
                  let end = event.endDate,
                  end > start else { continue }
            // Recurring events share an identifier across occurrences; key on
            // identifier + start so each occurrence is its own busy window.
            let key = "\(identifier)#\(start.timeIntervalSinceReferenceDate)"
            let title = event.title ?? "Busy"

            if let match = existingById.removeValue(forKey: key) {
                match.title = title
                match.startTime = start
                match.endTime = end
                match.calendarName = event.calendar?.title
            } else {
                context.insert(BusyEvent(
                    source: .appleCalendar,
                    sourceId: key,
                    title: title,
                    startTime: start,
                    endTime: end,
                    calendarName: event.calendar?.title
                ))
            }
        }

        // Whatever wasn't matched no longer exists (or fell out of the horizon).
        for (_, orphan) in existingById {
            context.delete(orphan)
        }
    }

    /// Calendars available for import (excluding Loom's own export calendar),
    /// for the selection UI. Requires calendar access.
    static func availableCalendars(settings: UserSettings) -> [EKCalendar] {
        store.calendars(for: .event)
            .filter {
                $0.calendarIdentifier != settings.loomCalendarIdentifier
                    && $0.title != "Loom"
            }
            .sorted {
                ($0.source?.title ?? "", $0.title) < ($1.source?.title ?? "", $1.title)
            }
    }

    /// Drop all imported Apple Calendar busy events (import switched off).
    static func removeImportedEvents(context: ModelContext) {
        let descriptor = FetchDescriptor<BusyEvent>()
        for event in (try? context.fetch(descriptor)) ?? [] where event.source == .appleCalendar {
            context.delete(event)
        }
    }
}
