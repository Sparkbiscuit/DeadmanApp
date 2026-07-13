import Foundation
import SwiftData

/// Google Calendar treated exactly like the Apple pair: import mirrors the
/// primary calendar's events into `BusyEvent(source: .googleCalendar)` — busy
/// windows the scheduler works around, never tasks — and the opt-in export
/// mirrors ScheduledBlocks into the primary calendar. Incremental imports ride
/// `syncToken` (full window fetch on 410); exported events carry a private
/// `loom=1` extended property so import can never re-ingest Loom's own blocks.
@MainActor
enum GoogleCalendarService {

    private static let eventsURL = URL(
        string: "https://www.googleapis.com/calendar/v3/calendars/primary/events"
    )!
    /// Same horizons as the Apple import/export — shared so the two mirrors
    /// can never drift apart.
    nonisolated private static let importHorizonDays = CalendarImportService.horizonDays
    nonisolated private static let exportHorizonDays = CalendarExportService.horizonDays

    /// Loop guard marker on exported events. Nonisolated: read from the
    /// nonisolated GEvent wire type and the test target.
    nonisolated static let loomMarkerKey = "loom"
    nonisolated static let loomMarkerValue = "1"

    /// Injection point for the URLProtocol-mocked test session.
    static var urlSession: URLSession = .shared

    private static var isImporting = false
    private static var isExporting = false
    private static var importGeneration: UInt = 0
    private static var exportGeneration: UInt = 0
    private static var cleanupGeneration: UInt = 0
    private static var foregroundSyncTask: Task<Void, Never>?
    private static var foregroundSyncTaskId: UUID?
    private static var exportCleanupTask: Task<Void, Never>?
    /// The pending debounced export, so a burst of scheduling changes (bulk
    /// entry, a replan) coalesces into one network reconcile instead of one
    /// per change — unlike the Apple export, this one leaves the device.
    private static var pendingExport: Task<Void, Never>?

    enum GoogleCalendarError: Error {
        case syncTokenExpired // HTTP 410: fall back to a full window fetch
        case http(Int)
    }

    // MARK: - Wire model

    struct GEventTime: Codable, Equatable {
        var dateTime: Date?
        /// All-day events carry a bare `date` instead — skipped, like the
        /// Apple import skips `isAllDay`.
        var date: String?
    }

    struct GExtendedProperties: Codable, Equatable {
        var `private`: [String: String]?
    }

    struct GEvent: Codable, Equatable {
        var id: String
        var status: String?
        var summary: String?
        var start: GEventTime?
        var end: GEventTime?
        var extendedProperties: GExtendedProperties?

        var isLoomExport: Bool {
            extendedProperties?.`private`?[loomMarkerKey] == loomMarkerValue
        }
    }

    struct GEventsPage: Codable {
        var items: [GEvent]?
        var nextPageToken: String?
        var nextSyncToken: String?
    }

    // MARK: - Entry points

    /// Foreground poll — the same hook as the Apple import. Fire-and-forget;
    /// network errors fail silently and the next poll retries.
    static func foregroundSyncIfEnabled(context: ModelContext) {
        let settings = UserSettings.fetchOrCreate(in: context)
        guard settings.googleAccountEmail != nil,
              settings.importFromGoogleCalendar || settings.exportToGoogleCalendar else { return }
        guard foregroundSyncTask == nil else { return }
        let taskId = UUID()
        foregroundSyncTaskId = taskId
        foregroundSyncTask = Task {
            defer {
                if foregroundSyncTaskId == taskId {
                    foregroundSyncTask = nil
                    foregroundSyncTaskId = nil
                }
            }
            if settings.importFromGoogleCalendar {
                await importNow(context: context, settings: settings)
            }
            if !Task.isCancelled, settings.exportToGoogleCalendar {
                // Debounced, so this coalesces with the export the import's
                // replan may have already queued.
                scheduleExport(context: context, settings: settings)
            }
        }
    }

    /// Mirror of `CalendarExportService.syncIfEnabled` — called from the same
    /// scheduling-change call sites, does nothing unless export is on.
    static func exportIfEnabled(context: ModelContext) {
        let settings = UserSettings.fetchOrCreate(in: context)
        guard settings.exportToGoogleCalendar, settings.googleAccountEmail != nil else { return }
        scheduleExport(context: context, settings: settings)
    }

    /// Trailing debounce: each call cancels the previous pending export and
    /// arms a fresh one two seconds out, so the last change in a burst wins.
    private static func scheduleExport(context: ModelContext, settings: UserSettings) {
        cancelExportCleanup()
        pendingExport?.cancel()
        pendingExport = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled,
                  settings.exportToGoogleCalendar,
                  settings.googleAccountEmail != nil else { return }
            await exportNow(context: context, settings: settings)
        }
    }

    // MARK: - Import (Google → Loom)

    static func importNow(context: ModelContext, settings: UserSettings) async {
        let generation = importGeneration
        guard settings.importFromGoogleCalendar, settings.googleAccountEmail != nil else { return }
        guard !isImporting else { return }
        isImporting = true
        defer { isImporting = false }

        do {
            let accessToken = try await GoogleOAuth.validAccessToken(urlSession: urlSession)
            try ensureImportIsCurrent(generation, settings: settings)
            settings.googleNeedsReconnect = false

            var fullSync = settings.googleSyncToken == nil
            var page: (events: [GEvent], nextSyncToken: String?)
            do {
                page = try await fetchEvents(
                    accessToken: accessToken,
                    syncToken: settings.googleSyncToken
                )
                try ensureImportIsCurrent(generation, settings: settings)
            } catch GoogleCalendarError.syncTokenExpired {
                fullSync = true
                page = try await fetchEvents(accessToken: accessToken, syncToken: nil)
                try ensureImportIsCurrent(generation, settings: settings)
            }

            let changes = reconcileImport(events: page.events, fullSync: fullSync, context: context)
            pruneStaleBusyEvents(context: context)
            let previousSyncToken = settings.googleSyncToken
            if let nextSyncToken = page.nextSyncToken {
                settings.googleSyncToken = nextSyncToken
            }
            do {
                try context.save()
            } catch {
                settings.googleSyncToken = previousSyncToken
                throw error
            }

            if changes > 0 {
                // Scheduled work moves out of the way of the imported events.
                replanAfterBusyChange(context: context)
            }
        } catch GoogleAuthError.needsReconnect {
            if generation == importGeneration,
               settings.importFromGoogleCalendar,
               settings.googleAccountEmail != nil,
               !Task.isCancelled {
                settings.googleNeedsReconnect = true
            }
        } catch {
            // Network hiccup: silent, the next foreground poll retries.
        }
    }

    /// Applies a batch of Google events to the local BusyEvent mirror.
    /// Upserts on the event id; honors cancellations (incremental responses
    /// include them via `showDeleted`); skips all-day events and Loom's own
    /// exports. On a full sync, anything unmatched no longer exists — or fell
    /// out of the horizon — and is dropped. Returns how many records changed,
    /// so the caller knows whether to replan.
    @discardableResult
    static func reconcileImport(events: [GEvent], fullSync: Bool, context: ModelContext) -> Int {
        let existing = ((try? context.fetch(FetchDescriptor<BusyEvent>())) ?? [])
            .filter { $0.source == .googleCalendar }
        var existingById = Dictionary(
            existing.map { ($0.sourceId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var changes = 0

        for event in events {
            guard !event.isLoomExport else { continue }

            let cancelled = event.status == "cancelled"
            guard !cancelled,
                  let start = event.start?.dateTime,
                  let end = event.end?.dateTime,
                  end > start else {
                // Cancelled, all-day, or degenerate: drop any local mirror.
                if let match = existingById.removeValue(forKey: event.id) {
                    context.delete(match)
                    changes += 1
                }
                continue
            }

            let title = event.summary ?? "Busy"
            if let match = existingById.removeValue(forKey: event.id) {
                if match.title != title || match.startTime != start || match.endTime != end {
                    changes += 1
                }
                match.title = title
                match.startTime = start
                match.endTime = end
                match.calendarName = "Google"
            } else {
                context.insert(BusyEvent(
                    source: .googleCalendar,
                    sourceId: event.id,
                    title: title,
                    startTime: start,
                    endTime: end,
                    calendarName: "Google"
                ))
                changes += 1
            }
        }

        if fullSync {
            for (_, orphan) in existingById {
                context.delete(orphan)
                changes += 1
            }
        }
        return changes
    }

    /// Incremental syncs never re-deliver events that simply slid into the
    /// past, so sweep those locally — the scheduler only cares about the
    /// future anyway.
    private static func pruneStaleBusyEvents(context: ModelContext, now: Date = Date()) {
        let stale = ((try? context.fetch(FetchDescriptor<BusyEvent>())) ?? [])
            .filter { $0.source == .googleCalendar && $0.endTime < now }
        for event in stale {
            context.delete(event)
        }
    }

    /// Drop all imported Google busy events (import switched off).
    static func removeImportedEvents(context: ModelContext) {
        importGeneration &+= 1
        foregroundSyncTask?.cancel()
        foregroundSyncTask = nil
        foregroundSyncTaskId = nil
        let imported = ((try? context.fetch(FetchDescriptor<BusyEvent>())) ?? [])
            .filter { $0.source == .googleCalendar }
        for event in imported {
            context.delete(event)
        }
        try? context.save()
    }

    private static func ensureImportIsCurrent(
        _ generation: UInt,
        settings: UserSettings
    ) throws {
        try Task.checkCancellation()
        guard generation == importGeneration,
              settings.importFromGoogleCalendar,
              settings.googleAccountEmail != nil else {
            throw CancellationError()
        }
    }

    // MARK: - Export (Loom → Google)

    /// Reconcile the primary calendar's Loom-tagged events with the current
    /// schedule — the same shape as `CalendarExportService.syncNow`: update
    /// on time changes, insert what's missing, delete what no longer matches
    /// a block.
    static func exportNow(context: ModelContext, settings: UserSettings) async {
        let generation = exportGeneration
        guard settings.exportToGoogleCalendar, settings.googleAccountEmail != nil else { return }
        cancelExportCleanup()
        guard !isExporting else { return }
        isExporting = true
        defer { isExporting = false }

        do {
            let accessToken = try await GoogleOAuth.validAccessToken(urlSession: urlSession)
            try ensureExportIsCurrent(generation, settings: settings)
            settings.googleNeedsReconnect = false

            let now = Date()
            let horizon = Calendar.current.date(byAdding: .day, value: exportHorizonDays, to: now) ?? now

            let allBlocks = (try? context.fetch(FetchDescriptor<ScheduledBlock>())) ?? []
            let exportable = allBlocks.filter {
                !$0.isComplete && $0.endTime > now && $0.startTime < horizon && $0.task != nil
            }

            // Loom-tagged events currently on the calendar.
            let existing = try await fetchEvents(
                accessToken: accessToken,
                syncToken: nil,
                timeMin: now.addingTimeInterval(-86400),
                timeMax: horizon,
                loomTaggedOnly: true
            ).events
            try ensureExportIsCurrent(generation, settings: settings)
            var eventsById = Dictionary(
                existing.filter { $0.status != "cancelled" }.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )

            for block in exportable {
                let title = block.task?.title ?? "Loom block"
                if let eventId = block.googleCalendarEventId,
                   let event = eventsById.removeValue(forKey: eventId) {
                    if event.summary != title
                        || !sameInstant(event.start?.dateTime, block.startTime)
                        || !sameInstant(event.end?.dateTime, block.endTime) {
                        try await writeEvent(
                            path: eventId, method: "PATCH",
                            title: title, start: block.startTime, end: block.endTime,
                            accessToken: accessToken
                        )
                        try ensureExportIsCurrent(generation, settings: settings)
                    }
                } else {
                    let eventId = try await writeEvent(
                        path: nil, method: "POST",
                        title: title, start: block.startTime, end: block.endTime,
                        accessToken: accessToken
                    )
                    try ensureExportIsCurrent(generation, settings: settings)
                    block.googleCalendarEventId = eventId
                }
            }

            // Whatever is left no longer matches a block — remove it.
            for (eventId, _) in eventsById {
                try? await deleteEvent(id: eventId, accessToken: accessToken)
                try ensureExportIsCurrent(generation, settings: settings)
            }
            try ensureExportIsCurrent(generation, settings: settings)
            try context.save()
        } catch GoogleAuthError.needsReconnect {
            if generation == exportGeneration,
               settings.exportToGoogleCalendar,
               settings.googleAccountEmail != nil {
                settings.googleNeedsReconnect = true
            }
        } catch {
            // Silent; reconciled again after the next scheduling change.
        }
    }

    /// Delete every exported Loom event from the calendar and forget the ids
    /// (export switched off). Best effort — matching Apple's behavior of not
    /// blocking the toggle on network success.
    static func removeExportedEvents(context: ModelContext) {
        exportGeneration &+= 1
        pendingExport?.cancel()
        pendingExport = nil
        foregroundSyncTask?.cancel()
        foregroundSyncTask = nil
        foregroundSyncTaskId = nil
        exportCleanupTask?.cancel()
        cleanupGeneration &+= 1
        let generation = cleanupGeneration
        exportCleanupTask = Task {
            if let accessToken = try? await GoogleOAuth.validAccessToken(urlSession: urlSession) {
                guard cleanupIsCurrent(generation, context: context) else { return }
                let now = Date()
                let horizon = Calendar.current.date(byAdding: .day, value: exportHorizonDays, to: now) ?? now
                if let existing = try? await fetchEvents(
                    accessToken: accessToken,
                    syncToken: nil,
                    timeMin: now.addingTimeInterval(-86400),
                    timeMax: horizon,
                    loomTaggedOnly: true
                ).events {
                    guard cleanupIsCurrent(generation, context: context) else { return }
                    for event in existing where event.status != "cancelled" {
                        try? await deleteEvent(id: event.id, accessToken: accessToken)
                        guard cleanupIsCurrent(generation, context: context) else { return }
                    }
                }
            }
            guard cleanupIsCurrent(generation, context: context) else { return }
            clearExportIds(context: context)
            if cleanupGeneration == generation { exportCleanupTask = nil }
        }
    }

    private static func ensureExportIsCurrent(
        _ generation: UInt,
        settings: UserSettings
    ) throws {
        try Task.checkCancellation()
        guard generation == exportGeneration,
              settings.exportToGoogleCalendar,
              settings.googleAccountEmail != nil else {
            throw CancellationError()
        }
    }

    private static func cleanupIsCurrent(_ generation: UInt, context: ModelContext) -> Bool {
        let settings = UserSettings.fetchOrCreate(in: context)
        return !Task.isCancelled
            && generation == cleanupGeneration
            && !settings.exportToGoogleCalendar
            && settings.googleAccountEmail != nil
    }

    private static func cancelExportCleanup() {
        cleanupGeneration &+= 1
        exportCleanupTask?.cancel()
        exportCleanupTask = nil
    }

    private static func clearExportIds(context: ModelContext) {
        for block in (try? context.fetch(FetchDescriptor<ScheduledBlock>())) ?? [] {
            block.googleCalendarEventId = nil
        }
        try? context.save()
    }

    // MARK: - Disconnect

    /// Wipes the Keychain tokens, the Google-sourced busy events, and all
    /// sync state. Exported events are left on the calendar (the user can
    /// switch export off first to clean those up).
    static func disconnect(context: ModelContext) {
        importGeneration &+= 1
        exportGeneration &+= 1
        cancelExportCleanup()
        foregroundSyncTask?.cancel()
        foregroundSyncTask = nil
        foregroundSyncTaskId = nil
        pendingExport?.cancel()
        pendingExport = nil
        GoogleOAuth.disconnect()
        let settings = UserSettings.fetchOrCreate(in: context)
        settings.importFromGoogleCalendar = false
        settings.exportToGoogleCalendar = false
        settings.googleSyncToken = nil
        settings.googleAccountEmail = nil
        settings.googleNeedsReconnect = false
        removeImportedEvents(context: context)
        clearExportIds(context: context)
        replanAfterBusyChange(context: context)
    }

    // MARK: - HTTP

    /// Pages through events.list. Incremental when `syncToken` is set (410 →
    /// `.syncTokenExpired`), otherwise a full window fetch — the import
    /// horizon by default, or the given bounds.
    static func fetchEvents(
        accessToken: String,
        syncToken: String?,
        timeMin: Date? = nil,
        timeMax: Date? = nil,
        loomTaggedOnly: Bool = false
    ) async throws -> (events: [GEvent], nextSyncToken: String?) {
        var events: [GEvent] = []
        var pageToken: String?
        var nextSyncToken: String?

        repeat {
            var queryItems = [
                URLQueryItem(name: "maxResults", value: "250"),
                URLQueryItem(name: "singleEvents", value: "true")
            ]
            if let syncToken {
                queryItems.append(URLQueryItem(name: "syncToken", value: syncToken))
                queryItems.append(URLQueryItem(name: "showDeleted", value: "true"))
            } else {
                let now = Date()
                let min = timeMin ?? now
                let max = timeMax
                    ?? Calendar.current.date(byAdding: .day, value: importHorizonDays, to: now)
                    ?? now
                queryItems.append(URLQueryItem(name: "timeMin", value: rfc3339.string(from: min)))
                queryItems.append(URLQueryItem(name: "timeMax", value: rfc3339.string(from: max)))
            }
            if loomTaggedOnly {
                queryItems.append(URLQueryItem(
                    name: "privateExtendedProperty",
                    value: "\(loomMarkerKey)=\(loomMarkerValue)"
                ))
            }
            if let pageToken {
                queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
            }

            var components = URLComponents(url: eventsURL, resolvingAgainstBaseURL: false)!
            components.queryItems = queryItems
            var request = URLRequest(url: components.url!)
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await performRequest(request)
            let status = response.statusCode
            if status == 410 {
                throw GoogleCalendarError.syncTokenExpired
            }
            guard status == 200 else {
                throw GoogleCalendarError.http(status)
            }

            let page = try decoder.decode(GEventsPage.self, from: data)
            events.append(contentsOf: page.items ?? [])
            pageToken = page.nextPageToken
            nextSyncToken = page.nextSyncToken ?? nextSyncToken
        } while pageToken != nil

        return (events, nextSyncToken)
    }

    /// POST (insert) or PATCH (update) one event; returns the event's id.
    /// The response is decoded id-only with a plain decoder, so a date-format
    /// surprise elsewhere in the payload can't lose the id of an event that
    /// was in fact created (which would duplicate it on the next reconcile).
    private struct GEventIdOnly: Decodable {
        let id: String
    }

    @discardableResult
    private static func writeEvent(
        path: String?,
        method: String,
        title: String,
        start: Date,
        end: Date,
        accessToken: String
    ) async throws -> String? {
        var url = eventsURL
        if let path {
            url = eventsURL.appendingPathComponent(path)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "summary": title,
            "description": "Scheduled by Loom",
            "start": ["dateTime": rfc3339.string(from: start)],
            "end": ["dateTime": rfc3339.string(from: end)],
            "extendedProperties": ["private": [loomMarkerKey: loomMarkerValue]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await performRequest(request)
        let status = response.statusCode
        guard (200..<300).contains(status) else {
            throw GoogleCalendarError.http(status)
        }
        return (try? JSONDecoder().decode(GEventIdOnly.self, from: data))?.id
    }

    private static func deleteEvent(id: String, accessToken: String) async throws {
        var request = URLRequest(url: eventsURL.appendingPathComponent(id))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await performRequest(request)
        let status = response.statusCode
        // 404/410: already gone — the goal state, not a failure.
        guard (200..<300).contains(status) || status == 404 || status == 410 else {
            throw GoogleCalendarError.http(status)
        }
    }

    /// Shared Calendar API transport: one forced refresh for a rejected token,
    /// and bounded retries for the statuses Google documents as transient.
    private static func performRequest(
        _ originalRequest: URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        var request = originalRequest
        var retriedUnauthorized = false
        var transientAttempts = 0

        // A prior request in this reconciliation may already have refreshed
        // the token. Start with that value instead of provoking another 401.
        if let sentToken = bearerToken(in: request),
           let stored = GoogleTokenStore.load(),
           stored.accessToken != sentToken,
           stored.isFresh() {
            request.setValue("Bearer \(stored.accessToken)", forHTTPHeaderField: "Authorization")
        }

        while true {
            try Task.checkCancellation()
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw GoogleCalendarError.http(0)
            }

            if http.statusCode == 401,
               !retriedUnauthorized,
               let rejectedToken = bearerToken(in: request) {
                let refreshedToken = try await GoogleOAuth.refreshAccessToken(
                    rejectedAccessToken: rejectedToken,
                    urlSession: urlSession
                )
                request.setValue("Bearer \(refreshedToken)", forHTTPHeaderField: "Authorization")
                retriedUnauthorized = true
                continue
            }

            // 429 means the request was rejected before processing — safe to
            // retry any method. A 5xx may have landed AFTER the server
            // committed the work, so only idempotent methods retry: replaying
            // an insert POST could duplicate the calendar event.
            let method = request.httpMethod?.uppercased() ?? "GET"
            let isIdempotent = method != "POST" && method != "PATCH"
            if http.statusCode == 429
                || ((500...599).contains(http.statusCode) && isIdempotent) {
                transientAttempts += 1
                if transientAttempts < 3 {
                    let delay = retryDelay(response: http, attempt: transientAttempts)
                    try await Task.sleep(for: .seconds(delay))
                    continue
                }
            }

            return (data, http)
        }
    }

    private static func bearerToken(in request: URLRequest) -> String? {
        guard let authorization = request.value(forHTTPHeaderField: "Authorization"),
              authorization.hasPrefix("Bearer ") else { return nil }
        return String(authorization.dropFirst("Bearer ".count))
    }

    private static func retryDelay(response: HTTPURLResponse, attempt: Int) -> TimeInterval {
        if let retryAfter = response.value(forHTTPHeaderField: "Retry-After") {
            if let seconds = TimeInterval(retryAfter) {
                return min(max(0, seconds), 30)
            }

            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
            if let date = formatter.date(from: retryAfter) {
                return min(max(0, date.timeIntervalSinceNow), 30)
            }
        }

        let backoff = 0.5 * pow(2, Double(attempt - 1))
        return min(backoff + Double.random(in: 0...0.25), 8)
    }

    // MARK: - Dates

    /// Google re-normalizes time zones on the way back, so compare instants
    /// with a second of tolerance instead of Date equality.
    private static func sameInstant(_ a: Date?, _ b: Date) -> Bool {
        guard let a else { return false }
        return abs(a.timeIntervalSince(b)) < 1
    }

    nonisolated(unsafe) private static let rfc3339: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    nonisolated(unsafe) private static let rfc3339Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            if let date = rfc3339.date(from: raw) ?? rfc3339Fractional.date(from: raw) {
                return date
            }
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unrecognized RFC 3339 date: \(raw)"
            ))
        }
        return decoder
    }()
}
