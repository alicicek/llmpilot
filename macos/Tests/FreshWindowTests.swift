import XCTest
@testable import llmpilot

/// Covers FreshWindowMenu.swift's pure `FreshWindowResolver` — a native
/// port of web/src/App.tsx's `bookFreshWindow`: the nextBookableReset
/// booking math (including the mid-window floor) and the verbatim "fully
/// booked" flash text.
final class FreshWindowTests: XCTestCase {
    func testResolveDerivesTriggerFromBookableReset() {
        // now=05:00 (300); no existing resets, no active session — the
        // earliest slot is now + 5h, snap-aligned (already is): reset=10:00,
        // trigger = reset - 5h = 05:00.
        let outcome = FreshWindowResolver.resolve(
            label: "Ada", nowMinutes: 300, existingResets: [], activeEndMinutes: nil
        )
        XCTAssertEqual(outcome, .create(hour: 5, minute: 0))
    }

    func testResolveDerivesTriggerFromMidWindowFloor() {
        // now=05:00 (300) but the account is mid-window with an active
        // session ending 10:00 (600) — the floor is
        // max(now+5h, activeEnd+5h) = max(600, 900) = 900 (15:00), so the
        // booked reset is 15:00 and the trigger is 15:00 - 5h = 10:00.
        let outcome = FreshWindowResolver.resolve(
            label: "Ada", nowMinutes: 300, existingResets: [], activeEndMinutes: 600
        )
        XCTAssertEqual(outcome, .create(hour: 10, minute: 0))
    }

    func testResolveClearsExistingResetsByMinGap() {
        // An existing reset at 15:00 (900) with a 5h15m minimum gap pushes
        // the next slot out to 20:15 (1215) rather than the naive 15:00
        // floor from now=05:00.
        let outcome = FreshWindowResolver.resolve(
            label: "Ada", nowMinutes: 300, existingResets: [900], activeEndMinutes: nil
        )
        guard case let .create(hour, minute) = outcome else {
            return XCTFail("expected .create, got \(outcome)")
        }
        let resetMin = hour * 60 + minute + BoardSchedule.windowHours * 60
        XCTAssertGreaterThanOrEqual(BoardSchedule.circularGap(900, resetMin % 1440), BoardSchedule.minGapMin)
    }

    func testResolveFullyBookedProducesVerbatimFlash() {
        // Five resets evenly spaced 288 min apart (< the 315 min gap floor)
        // blankets the whole day: every candidate is within 144 min of one
        // of them, so no slot can clear all five by >=315.
        let existing = [0, 288, 576, 864, 1152]
        let outcome = FreshWindowResolver.resolve(
            label: "Ada Lovelace", nowMinutes: 0, existingResets: existing, activeEndMinutes: nil
        )
        XCTAssertEqual(outcome, .fullyBooked(message: "Ada Lovelace is fully booked — resets must sit ≥ 5 h 15 min apart."))
    }

    func testResolveFullyBookedUsesRawLabelNotEmailFallback() {
        // Mirrors App.tsx's `acct?.label ?? accountId`: the flash uses the
        // account's raw `label` even when empty — NOT the menu item's
        // `label || email` display fallback. Documented source quirk, not
        // silently "fixed" here.
        let existing = [0, 288, 576, 864, 1152]
        let outcome = FreshWindowResolver.resolve(
            label: "", nowMinutes: 0, existingResets: existing, activeEndMinutes: nil
        )
        XCTAssertEqual(outcome, .fullyBooked(message: " is fully booked — resets must sit ≥ 5 h 15 min apart."))
    }

    func testMenuAccountDisplayNameFallsBackToEmail() {
        let withLabel = FreshWindowAccount(id: "a1", label: "Ada", email: "ada@example.com")
        let withoutLabel = FreshWindowAccount(id: "a2", label: "", email: "ada@example.com")
        XCTAssertEqual(withLabel.displayName, "Ada")
        XCTAssertEqual(withoutLabel.displayName, "ada@example.com")
    }
}
