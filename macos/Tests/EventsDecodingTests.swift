import XCTest
@testable import llmpilot

/// New file per brief: decode coverage for `DaemonState.events` /
/// `DaemonEvent` (API/Models.swift) added for the native events feed
/// (Views/Cockpit/EventsFeedView.swift). Existing decode test files are
/// left untouched — this is additive coverage only.
final class EventsDecodingTests: XCTestCase {
    private func stateJSON(eventsFragment: String) -> String {
        """
        {"accounts": [], "as_of": "2026-08-07T12:00:00Z"\(eventsFragment)}
        """
    }

    func testEventsAbsentDecodesEmpty() throws {
        let s = try DaemonDates.decoder().decode(DaemonState.self, from: Data(stateJSON(eventsFragment: "").utf8))
        XCTAssertEqual(s.events, [])
    }

    func testEventsNullDecodesEmpty() throws {
        let json = stateJSON(eventsFragment: ", \"events\": null")
        let s = try DaemonDates.decoder().decode(DaemonState.self, from: Data(json.utf8))
        XCTAssertEqual(s.events, [])
    }

    func testEventsDecodesFullShape() throws {
        let json = stateJSON(eventsFragment: """
        , "events": [
          {"at": "2026-08-07T09:00:00Z", "kind": "switch", "account_id": "acct-a",
           "message": "Switched to acct-a", "late": true},
          {"at": "2026-08-07T08:00:00Z", "kind": "rotate", "message": "Rotated"}
        ]
        """)
        let s = try DaemonDates.decoder().decode(DaemonState.self, from: Data(json.utf8))
        XCTAssertEqual(s.events.count, 2)
        XCTAssertEqual(s.events[0].kind, "switch")
        XCTAssertEqual(s.events[0].accountID, "acct-a")
        XCTAssertEqual(s.events[0].message, "Switched to acct-a")
        XCTAssertEqual(s.events[0].late, true)
        // account_id and late are both optional — a second entry omitting
        // them must still decode.
        XCTAssertNil(s.events[1].accountID)
        XCTAssertNil(s.events[1].late)
    }

    /// Bucket.kind is documented as an OPEN string the daemon passes through
    /// verbatim (Models.swift:91-92) — DaemonEvent.kind rides the same rule:
    /// an unrecognized kind must still decode and render, never error.
    func testUnknownEventKindPassesThrough() throws {
        let json = """
        {"at": "2026-08-07T09:00:00Z", "kind": "some_future_kind", "message": "x"}
        """
        let e = try DaemonDates.decoder().decode(DaemonEvent.self, from: Data(json.utf8))
        XCTAssertEqual(e.kind, "some_future_kind")
    }

    func testEventsWithinStateDefaultOrderIsPreservedByDecoder() throws {
        // The decoder itself does no reordering — `orderedEvents` (Views/
        // Cockpit/EventsFeedView.swift) owns the newest-first + cap-50 rule,
        // tested separately below against the daemon's actual wire order.
        let json = stateJSON(eventsFragment: """
        , "events": [
          {"at": "2026-08-07T08:00:00Z", "kind": "switch", "message": "first"},
          {"at": "2026-08-07T09:00:00Z", "kind": "switch", "message": "second"}
        ]
        """)
        let s = try DaemonDates.decoder().decode(DaemonState.self, from: Data(json.utf8))
        XCTAssertEqual(s.events.map(\.message), ["first", "second"])
    }

    // MARK: - orderedEvents (EventsFeedView.swift)

    private func event(at: String, kind: String = "switch", message: String) -> DaemonEvent {
        try! DaemonDates.decoder().decode(
            DaemonEvent.self,
            from: Data("{\"at\":\"\(at)\",\"kind\":\"\(kind)\",\"message\":\"\(message)\"}".utf8))
    }

    func testOrderedEventsIsNewestFirstAndCapped() {
        let events = (0..<60).map { i in
            event(at: "2026-08-07T\(String(format: "%02d", i % 24)):00:00Z", message: "e\(i)")
        }
        let ordered = orderedEvents(events)
        XCTAssertEqual(ordered.count, 50)
        // Newest `at` sorts first.
        for i in 0..<(ordered.count - 1) {
            XCTAssertGreaterThanOrEqual(ordered[i].at, ordered[i + 1].at)
        }
    }

    func testOrderedEventsEmpty() {
        XCTAssertEqual(orderedEvents([]), [])
    }

    // MARK: - Activity (EventsFeedView.swift)

    private func event(at: String, kind: String, account: String?, message: String) -> DaemonEvent {
        let acct = account.map { ",\"account_id\":\"\($0)\"" } ?? ""
        return try! DaemonDates.decoder().decode(
            DaemonEvent.self,
            from: Data("{\"at\":\"\(at)\",\"kind\":\"\(kind)\"\(acct),\"message\":\"\(message)\"}".utf8))
    }

    /// Re-aiming the Mac's wake is plumbing: older daemons logged one per
    /// schedule edit, and none of them reach the feed.
    func testActivityHidesWakePlumbing() {
        let rows = Activity.rows([
            event(at: "2026-11-01T01:13:00Z", kind: "wake_armed", account: nil, message: "mac will wake Sun 06:13"),
            event(at: "2026-11-01T01:15:00Z", kind: "trigger", account: "a", message: "01:15 nudge opened a fresh window on a"),
            event(at: "2026-11-01T01:20:00Z", kind: "wake", account: "a", message: "armed wake for a at 08:30"),
        ])
        XCTAssertEqual(rows.map(\.event.kind), ["trigger"])
    }

    /// Back-to-back repeats of one event fold into a line with a count; the
    /// same text on another account, or a repeat with something between,
    /// stays its own line.
    func testActivityFoldsBackToBackRepeats() {
        let rows = Activity.rows([
            event(at: "2026-11-01T03:35:00Z", kind: "trigger_skipped", account: "a", message: "skipped"),
            event(at: "2026-11-01T03:58:00Z", kind: "trigger_skipped", account: "a", message: "skipped"),
            event(at: "2026-11-01T04:10:00Z", kind: "trigger_skipped", account: "b", message: "skipped"),
            event(at: "2026-11-01T04:20:00Z", kind: "switch", account: "b", message: "Switched to b"),
            event(at: "2026-11-01T04:30:00Z", kind: "trigger_skipped", account: "b", message: "skipped"),
        ])
        XCTAssertEqual(rows.map(\.count), [1, 1, 1, 2])
        XCTAssertEqual(rows.map(\.event.accountID), ["b", "b", "b", "a"])
        // The folded line keeps its newest time.
        XCTAssertEqual(rows[3].event.at, ISO8601DateFormatter().date(from: "2026-11-01T03:58:00Z"))
    }

    func testFailedTodayCountsOnlyTodaysFailures() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = ISO8601DateFormatter().date(from: "2026-11-01T12:00:00Z")!
        let events = [
            event(at: "2026-10-31T23:59:00Z", kind: "trigger_failed", account: "a", message: "yesterday"),
            event(at: "2026-11-01T01:15:00Z", kind: "trigger_failed", account: "a", message: "today"),
            event(at: "2026-11-01T02:00:00Z", kind: "trigger_skipped", account: "a", message: "not a failure"),
        ]
        XCTAssertEqual(Activity.failedToday(events, now: now, calendar: cal), 1)
        XCTAssertEqual(Activity.failedToday([], now: now, calendar: cal), 0)
    }
}
