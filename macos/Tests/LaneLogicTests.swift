import AppKit
import SwiftUI
import XCTest
@testable import llmpilot

/// Pure-logic coverage for the fleet lanes port (Views/Cockpit/
/// FleetLanesView.swift + ConnectivityViews.swift): status-line derivation
/// (LaneHeader.tsx lines 30-46), the token-note severity split, the
/// stale-OR rule, avatar-color determinism, and the daemon-age label.
final class LaneLogicTests: XCTestCase {
    // MARK: - fixtures

    private func bucket(
        kind: String = "session", scope: String? = nil, percent: Double, resetsAt: String? = nil,
        severity: String? = nil, active: Bool? = nil
    ) -> Bucket {
        var json = "{\"kind\":\"\(kind)\",\"percent\":\(percent)"
        if let scope { json += ",\"scope\":\"\(scope)\"" }
        if let resetsAt { json += ",\"resets_at\":\"\(resetsAt)\"" }
        if let severity { json += ",\"severity\":\"\(severity)\"" }
        if let active { json += ",\"active\":\(active)" }
        json += "}"
        return try! DaemonDates.decoder().decode(Bucket.self, from: json.data(using: .utf8)!)
    }

    // MARK: - token-note severity (LaneHeader.tsx `tokenNoteSevere`)

    func testTokenNoteSeverity() {
        XCTAssertTrue(tokenNoteSevere("token expired — sign in again"))
        XCTAssertTrue(tokenNoteSevere("needs a fresh sign-in"))
        XCTAssertFalse(tokenNoteSevere("expiring in 3 days"))
        XCTAssertFalse(tokenNoteSevere(""))
    }

    // MARK: - stale OR rule (LaneHeader.tsx line 26)

    func testLaneStaleORRule() {
        let now = 14 * 60 + 32 // 14:32, matches the fixture clock elsewhere in the suite

        // Authoritative daemon mark wins even with a fresh snapshot.
        let fresh = ISO8601DateFormatter().string(from: dateAt(hour: 14, minute: 30))
        XCTAssertTrue(laneStale(
            accountStale: true,
            snapshotAsOf: DaemonDates.parseRFC3339(fresh), nowMinutes: now))

        // No account-level mark, but the snapshot itself is old (> 10 min per
        // BoardTime.staleAfterMin) — still stale.
        let old = dateAt(hour: 14, minute: 10)
        XCTAssertTrue(laneStale(accountStale: false, snapshotAsOf: old, nowMinutes: now))
        XCTAssertTrue(laneStale(accountStale: nil, snapshotAsOf: old, nowMinutes: now))

        // Neither condition holds.
        let recent = dateAt(hour: 14, minute: 25)
        XCTAssertFalse(laneStale(accountStale: false, snapshotAsOf: recent, nowMinutes: now))

        // No snapshot at all and no account mark — never stale.
        XCTAssertFalse(laneStale(accountStale: nil, snapshotAsOf: nil, nowMinutes: now))
    }

    private func dateAt(hour: Int, minute: Int) -> Date {
        var c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        c.hour = hour
        c.minute = minute
        c.second = 0
        return Calendar.current.date(from: c)!
    }

    // MARK: - status-line derivation table (LaneHeader.tsx lines 30-46)

    func testLaneStatusLineTable() {
        let now = 14 * 60 + 32
        let resets = ISO8601DateFormatter().string(from: dateAt(hour: 16, minute: 5))

        // No session bucket at all.
        XCTAssertEqual(
            laneStatusLine(session: nil, stale: false, nowMinutes: now),
            LaneStatusLine(dot: .gray, text: "Nothing scheduled"))

        // Idle session (not active) — ok dot.
        let idle = bucket(percent: 0, active: false)
        XCTAssertEqual(
            laneStatusLine(session: idle, stale: false, nowMinutes: now),
            LaneStatusLine(dot: .ok, text: "Idle — no active window"))

        // Idle session while stale — dot drains to gray, text unchanged.
        XCTAssertEqual(
            laneStatusLine(session: idle, stale: true, nowMinutes: now),
            LaneStatusLine(dot: .gray, text: "Idle — no active window"))

        // Active session with a reset time — warn dot, mid-window text,
        // progress percent + time-left carried through.
        let active = bucket(percent: 62, resetsAt: resets, active: true)
        let line = laneStatusLine(session: active, stale: false, nowMinutes: now)
        XCTAssertEqual(line.dot, .warn)
        XCTAssertEqual(line.text, "Mid-window — resets 16:05")
        XCTAssertEqual(line.progressPercent, 62)
        XCTAssertEqual(line.timeLeft, "1:33 left")

        // Same, but stale — dot drains to gray, everything else unchanged
        // (line 46: stale always wins the dot, last).
        let staleLine = laneStatusLine(session: active, stale: true, nowMinutes: now)
        XCTAssertEqual(staleLine.dot, .gray)
        XCTAssertEqual(staleLine.text, "Mid-window — resets 16:05")

        // Active flag true but no resets_at present — falls through to the
        // idle branch (LaneHeader.tsx's `session.active && session.resets_at`
        // guard requires BOTH).
        let activeNoReset = bucket(percent: 40, active: true)
        XCTAssertEqual(
            laneStatusLine(session: activeNoReset, stale: false, nowMinutes: now),
            LaneStatusLine(dot: .ok, text: "Idle — no active window"))
    }

    // MARK: - avatar color (avatar.ts port)

    func testAvatarShiftDeterministicAndSpread() {
        XCTAssertEqual(avatarShift(for: "acct-a"), avatarShift(for: "acct-a"))

        // Same hash-math family as web's avatarStyle: hue is one of 5 fixed
        // steps, saturation one of 3.
        let ids = ["acct-a", "acct-b", "acct-c", "acct-d", "acct-e", "watched-1", "z"]
        let shifts = ids.map(avatarShift(for:))
        for shift in shifts {
            XCTAssertTrue([0, 72, 144, 216, 288].contains(shift.hueDegrees))
            XCTAssertTrue([85, 100, 115].contains(shift.saturationPercent))
        }
        // A spread of 7 short ids should not collapse to one bucket.
        XCTAssertGreaterThan(Set(shifts.map(\.hueDegrees)).count, 1)
    }

    func testAvatarColorDeterministicAndSpread() {
        let a1 = NSColor(avatarColor(id: "acct-a", dark: false))
        let a2 = NSColor(avatarColor(id: "acct-a", dark: false))
        XCTAssertEqual(a1.hueComponent, a2.hueComponent, accuracy: 0.0001)
        XCTAssertEqual(a1.saturationComponent, a2.saturationComponent, accuracy: 0.0001)

        // Light and dark resolve independently for the same id (different
        // base accent hexes).
        let dark = NSColor(avatarColor(id: "acct-a", dark: true))
        XCTAssertNotNil(dark)

        // Different ids spread across at least two distinct hues.
        let hues = Set(["acct-a", "acct-b", "acct-c", "acct-d", "acct-e"].map {
            Double(NSColor(avatarColor(id: $0, dark: false)).hueComponent)
        })
        XCTAssertGreaterThan(hues.count, 1)
    }

    // MARK: - ageLabel (App.tsx `ageLabel`, App.tsx:70-74)

    func testAgeLabelVectors() {
        let now = Date()
        struct Vector { let minutesAgo: Double; let expected: String }
        let vectors: [Vector] = [
            Vector(minutesAgo: 0, expected: "0 min ago"),
            Vector(minutesAgo: 1, expected: "1 min ago"),
            Vector(minutesAgo: 59, expected: "59 min ago"),
            Vector(minutesAgo: 60, expected: "1 h ago"),
            Vector(minutesAgo: 90, expected: "1.5 h ago"),
            Vector(minutesAgo: 600, expected: "10 h ago"),
            Vector(minutesAgo: 690, expected: "11.5 h ago"),
        ]
        for v in vectors {
            let then = now.addingTimeInterval(-v.minutesAgo * 60)
            XCTAssertEqual(ageLabel(from: then, now: now), v.expected, "minutesAgo=\(v.minutesAgo)")
        }
        // Never negative — a clock skewed slightly into the future clamps to 0.
        let future = now.addingTimeInterval(30)
        XCTAssertEqual(ageLabel(from: future, now: now), "0 min ago")
    }

    // MARK: - connectivity pill label (Toolbar.tsx `pillLabel`)

    func testConnectivityPillLabel() {
        XCTAssertEqual(connectivityPillLabel(status: .live, asOfAge: "9 min ago"), "Daemon active")
        XCTAssertEqual(connectivityPillLabel(status: .connecting, asOfAge: nil), "Connecting")
        XCTAssertEqual(connectivityPillLabel(status: .starting, asOfAge: nil), "Connecting")
        XCTAssertEqual(connectivityPillLabel(status: .down, asOfAge: "9 min ago"), "Daemon down — as of 9 min ago")
        XCTAssertEqual(connectivityPillLabel(status: .down, asOfAge: nil), "Daemon not running")
    }
}
