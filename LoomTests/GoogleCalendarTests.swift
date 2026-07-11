import XCTest
import SwiftData
@testable import Loom

final class GoogleCalendarTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: SharedStore.schema, configurations: [config])
        context = ModelContext(container)
    }

    override func tearDownWithError() throws {
        container = nil
        context = nil
    }

    // MARK: - PKCE

    func testCodeChallengeMatchesRFC7636Vector() {
        // Appendix B of RFC 7636: the canonical verifier/challenge pair.
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(
            GoogleOAuth.codeChallenge(for: verifier),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        )
    }

    func testRandomVerifierIsURLSafeAndUnique() {
        let a = GoogleOAuth.randomURLSafeString(byteCount: 48)
        let b = GoogleOAuth.randomURLSafeString(byteCount: 48)
        XCTAssertNotEqual(a, b)
        XCTAssertFalse(a.isEmpty)
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
        )
        XCTAssertTrue(a.unicodeScalars.allSatisfy(allowed.contains))
    }

    // MARK: - id_token parsing

    func testParseEmailFromIdToken() {
        // header.payload.signature with a base64url payload carrying an email.
        let payload = Data(#"{"email":"nick@christoforakis.com","sub":"123"}"#.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let token = "eyJhbGciOiJSUzI1NiJ9.\(payload).sig"
        XCTAssertEqual(GoogleOAuth.parseEmail(fromIdToken: token), "nick@christoforakis.com")
    }

    func testParseEmailRejectsGarbage() {
        XCTAssertNil(GoogleOAuth.parseEmail(fromIdToken: "not-a-jwt"))
        XCTAssertNil(GoogleOAuth.parseEmail(fromIdToken: "a.!!!!.c"))
    }

    // MARK: - Token freshness

    func testTokenFreshness() {
        var tokens = GoogleTokens(
            accessToken: "a", refreshToken: "r",
            expiresAt: Date().addingTimeInterval(3600), email: nil
        )
        XCTAssertTrue(tokens.isFresh())
        // Inside the one-minute slack: treated as stale so a request can't
        // ride a token that dies mid-flight.
        tokens.expiresAt = Date().addingTimeInterval(30)
        XCTAssertFalse(tokens.isFresh())
        tokens.expiresAt = Date().addingTimeInterval(-10)
        XCTAssertFalse(tokens.isFresh())
    }

    // MARK: - Import reconciliation

    private func gEvent(
        id: String,
        title: String? = "Busy",
        start: Date?,
        end: Date?,
        status: String? = nil,
        allDayDate: String? = nil,
        loomTagged: Bool = false
    ) -> GoogleCalendarService.GEvent {
        GoogleCalendarService.GEvent(
            id: id,
            status: status,
            summary: title,
            start: .init(dateTime: start, date: allDayDate),
            end: .init(dateTime: end, date: allDayDate),
            extendedProperties: loomTagged
                ? .init(private: [GoogleCalendarService.loomMarkerKey: GoogleCalendarService.loomMarkerValue])
                : nil
        )
    }

    private func googleBusyEvents() throws -> [BusyEvent] {
        try context.fetch(FetchDescriptor<BusyEvent>())
            .filter { $0.source == .googleCalendar }
    }

    @MainActor
    func testImportInsertsNewEvents() throws {
        let start = Date().addingTimeInterval(3600)
        let changes = GoogleCalendarService.reconcileImport(
            events: [gEvent(id: "e1", title: "Dentist", start: start, end: start.addingTimeInterval(1800))],
            fullSync: true,
            context: context
        )
        XCTAssertEqual(changes, 1)
        let imported = try googleBusyEvents()
        XCTAssertEqual(imported.count, 1)
        XCTAssertEqual(imported.first?.title, "Dentist")
        XCTAssertEqual(imported.first?.sourceId, "e1")
    }

    @MainActor
    func testImportUpsertsOnEventId() throws {
        let start = Date().addingTimeInterval(3600)
        context.insert(BusyEvent(
            source: .googleCalendar, sourceId: "e1", title: "Old title",
            startTime: start, endTime: start.addingTimeInterval(1800)
        ))

        let newStart = start.addingTimeInterval(7200)
        GoogleCalendarService.reconcileImport(
            events: [gEvent(id: "e1", title: "Moved", start: newStart, end: newStart.addingTimeInterval(1800))],
            fullSync: false,
            context: context
        )
        let imported = try googleBusyEvents()
        XCTAssertEqual(imported.count, 1, "Upsert must never duplicate")
        XCTAssertEqual(imported.first?.title, "Moved")
        XCTAssertEqual(imported.first?.startTime, newStart)
    }

    @MainActor
    func testImportHonorsCancellations() throws {
        let start = Date().addingTimeInterval(3600)
        context.insert(BusyEvent(
            source: .googleCalendar, sourceId: "e1", title: "Dentist",
            startTime: start, endTime: start.addingTimeInterval(1800)
        ))

        GoogleCalendarService.reconcileImport(
            events: [gEvent(id: "e1", start: nil, end: nil, status: "cancelled")],
            fullSync: false,
            context: context
        )
        XCTAssertTrue(try googleBusyEvents().isEmpty)
    }

    @MainActor
    func testImportSkipsAllDayAndLoomTaggedEvents() throws {
        let start = Date().addingTimeInterval(3600)
        GoogleCalendarService.reconcileImport(
            events: [
                gEvent(id: "allday", start: nil, end: nil, allDayDate: "2026-07-11"),
                gEvent(id: "ours", title: "Loom block", start: start,
                       end: start.addingTimeInterval(1800), loomTagged: true)
            ],
            fullSync: true,
            context: context
        )
        XCTAssertTrue(try googleBusyEvents().isEmpty, "All-day and Loom-exported events must not become busy time")
    }

    @MainActor
    func testFullSyncDropsOrphansButIncrementalKeepsThem() throws {
        let start = Date().addingTimeInterval(3600)
        context.insert(BusyEvent(
            source: .googleCalendar, sourceId: "gone", title: "Deleted upstream",
            startTime: start, endTime: start.addingTimeInterval(1800)
        ))

        // Incremental responses only carry deltas: an absent event is not a
        // deletion, so the mirror must survive.
        GoogleCalendarService.reconcileImport(events: [], fullSync: false, context: context)
        XCTAssertEqual(try googleBusyEvents().count, 1)

        // A full window fetch is the whole truth: unmatched means gone.
        GoogleCalendarService.reconcileImport(events: [], fullSync: true, context: context)
        XCTAssertTrue(try googleBusyEvents().isEmpty)
    }

    @MainActor
    func testImportLeavesAppleEventsAlone() throws {
        let start = Date().addingTimeInterval(3600)
        context.insert(BusyEvent(
            source: .appleCalendar, sourceId: "apple-1", title: "Apple event",
            startTime: start, endTime: start.addingTimeInterval(1800)
        ))

        GoogleCalendarService.reconcileImport(events: [], fullSync: true, context: context)
        let apple = try context.fetch(FetchDescriptor<BusyEvent>())
            .filter { $0.source == .appleCalendar }
        XCTAssertEqual(apple.count, 1, "A Google full sync must never touch Apple-sourced busy events")
    }

    // MARK: - Wire decoding

    func testEventPageDecodingHandlesGoogleDateFormats() throws {
        let json = """
        {
          "items": [
            {
              "id": "abc",
              "status": "confirmed",
              "summary": "Standup",
              "start": { "dateTime": "2026-07-11T15:00:00-04:00" },
              "end": { "dateTime": "2026-07-11T15:30:00.000-04:00" }
            },
            {
              "id": "allday",
              "start": { "date": "2026-07-12" },
              "end": { "date": "2026-07-13" }
            }
          ],
          "nextSyncToken": "sync-123"
        }
        """
        let page = try GoogleCalendarService.decoder.decode(
            GoogleCalendarService.GEventsPage.self, from: Data(json.utf8)
        )
        XCTAssertEqual(page.items?.count, 2)
        XCTAssertEqual(page.nextSyncToken, "sync-123")
        let timed = page.items?.first
        XCTAssertNotNil(timed?.start?.dateTime)
        XCTAssertNotNil(timed?.end?.dateTime, "Fractional-second RFC 3339 must decode too")
        XCTAssertEqual(
            timed!.end!.dateTime!.timeIntervalSince(timed!.start!.dateTime!),
            1800, accuracy: 1
        )
        let allDay = page.items?.last
        XCTAssertNil(allDay?.start?.dateTime)
        XCTAssertEqual(allDay?.start?.date, "2026-07-12")
    }
}
