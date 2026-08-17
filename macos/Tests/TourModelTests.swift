import XCTest
@testable import llmpilot

/// Chunk 5A — TourModel.swift (web/src/shell/Tour.tsx port). Hermetic: no
/// view, no daemon. Web twin: web/tests/tour.spec.ts — the case names below
/// cite the spec case they mirror.
///
/// F15 (audit 2026-08-16, owner decision): the tour dropped its fourth step (target "daemon",
/// which spotlighted the now-gone "Daemon active" pill) — three steps now,
/// not four. `allTargets` below reflects the three that remain.
@MainActor
final class TourModelTests: XCTestCase {
    private let allTargets: Set<String> = ["runway", "switch", "fresh-window"]

    // MARK: - full fleet: nothing dropped
    // web twin: "the guide walks the real cockpit and ends" — adapted to
    // STEP 1 OF 3 ... STEP 3 OF 3, Got it on the last step.

    func testFullFleetShowsAllThreeStepsInOrder() {
        let model = TourModel()
        model.availableTargets = allTargets
        XCTAssertEqual(model.live.map(\.target), ["runway", "switch", "fresh-window"])
        XCTAssertEqual(model.total, 3)
        XCTAssertEqual(model.stepNumber, 1)
        XCTAssertEqual(model.current?.target, "runway")
        XCTAssertFalse(model.isLast)
        XCTAssertFalse(model.isDone)
    }

    func testAdvanceWalksEveryStepThenTheLastOneReadsGotIt() {
        let model = TourModel()
        model.availableTargets = allTargets

        model.advance() // -> switch
        XCTAssertEqual(model.current?.target, "switch")
        XCTAssertEqual(model.stepNumber, 2)
        XCTAssertFalse(model.isLast)

        model.advance() // -> fresh-window, the last one
        XCTAssertEqual(model.current?.target, "fresh-window")
        XCTAssertEqual(model.stepNumber, 3)
        XCTAssertTrue(model.isLast)
        XCTAssertFalse(model.isDone)

        model.advance() // past the end — "Got it" was pressed
        XCTAssertTrue(model.isDone)
        XCTAssertNil(model.current)
    }

    // MARK: - one-account fleet: renumbering
    // web twin: "a one-account fleet skips the step whose control does not
    // exist" — STEP 1 OF 2, Next lands on "Open a window on your own clock"

    func testSoloFleetDropsSwitchAndRenumbers() {
        let model = TourModel()
        model.availableTargets = ["runway", "fresh-window"] // no "switch" target on screen
        XCTAssertEqual(model.live.map(\.target), ["runway", "fresh-window"])
        XCTAssertEqual(model.total, 2)
        XCTAssertEqual(model.current?.target, "runway")
        XCTAssertEqual(model.stepNumber, 1)

        model.advance()
        XCTAssertEqual(model.current?.target, "fresh-window")
        XCTAssertEqual(model.stepNumber, 2)
        XCTAssertEqual(model.current?.title, "Open a window on your own clock")
        XCTAssertTrue(model.isLast)
    }

    // MARK: - no "daemon" target exists any more
    // F15: the catalog itself must never re-introduce the dropped step.

    func testCatalogNoLongerCarriesADaemonStep() {
        XCTAssertFalse(TourStepCatalog.all.map(\.target).contains("daemon"))
        XCTAssertEqual(TourStepCatalog.all.count, 3)
    }

    // MARK: - the fresh-window step's copy carries the sentence F15 kept
    // reachable (audit 2026-08-16: "a menu bar manager like Ice or Bartender
    // may hide the icon" survives the dropped step, folded into this one).

    func testFreshWindowStepKeepsTheMenuBarManagerSentence() {
        let model = TourModel()
        model.availableTargets = allTargets
        model.advance() // -> switch
        model.advance() // -> fresh-window
        XCTAssertEqual(model.current?.target, "fresh-window")
        XCTAssertTrue(model.current?.body.contains("menu bar manager") == true)
        XCTAssertTrue(model.current?.body.contains("Ice or Bartender") == true)
    }

    // MARK: - last-step copy is verbatim (App.tsx:92-113, minus "daemon")

    func testStepCopyIsVerbatim() {
        let model = TourModel()
        model.availableTargets = allTargets
        XCTAssertEqual(model.current?.title, "This is your real usage")
        model.advance()
        XCTAssertEqual(model.current?.title, "Move to an account with room")
        model.advance()
        XCTAssertEqual(model.current?.title, "Open a window on your own clock")
    }

    // MARK: - never shows an empty guide
    // web twin: Tour.tsx:100-103 "there was never anything on screen worth
    // pointing at"

    func testNoTargetsOnScreenIsImmediatelyDone() {
        let model = TourModel()
        XCTAssertTrue(model.isDone)
        XCTAssertNil(model.current)
        XCTAssertEqual(model.total, 0)
    }

    // MARK: - skip ends the guide at any step
    // web twin: "skip ends the guide at any step"

    func testEndIsIdempotentAndWorksMidWalk() {
        let model = TourModel()
        model.availableTargets = allTargets
        model.advance() // step 2 of 3
        model.end()
        XCTAssertTrue(model.isDone)
        model.end() // idempotent
        XCTAssertTrue(model.isDone)
    }

    // MARK: - a fresh walk always starts at step one
    // web twin: "on a real cockpit the guide opens itself, then never again"
    // / "Show me around" — each open is a fresh component instance.

    func testFreshModelAlwaysStartsAtStepOne() {
        let first = TourModel()
        first.availableTargets = allTargets
        first.advance()
        XCTAssertEqual(first.stepNumber, 2)

        let second = TourModel() // a fresh "Show me around" open
        second.availableTargets = allTargets
        XCTAssertEqual(second.stepNumber, 1)
        XCTAssertEqual(second.current?.target, "runway")
    }

    // MARK: - card layout (Tour.tsx:107-116)

    func testCardPlacesBelowTargetWhenItFits() {
        let origin = TourCardLayout.origin(
            targetRect: CGRect(x: 40, y: 40, width: 120, height: 60),
            cardHeight: 150,
            viewport: CGSize(width: 900, height: 700))
        // below = target.maxY + pad + cardHeight < viewport.height -> 40+60+8+150=258 < 700
        XCTAssertEqual(origin.y, 40 + 60 + 8 + 4, accuracy: 0.01)
        XCTAssertEqual(origin.x, 40, accuracy: 0.01)
    }

    func testCardFlipsAboveWhenBelowWouldOverflowTheViewport() {
        let origin = TourCardLayout.origin(
            targetRect: CGRect(x: 40, y: 600, width: 120, height: 60),
            cardHeight: 150,
            viewport: CGSize(width: 900, height: 700))
        // below = 600+60+8+150=818, not < 700 -> place above: top - pad - cardHeight
        XCTAssertEqual(origin.y, 600 - 8 - 150, accuracy: 0.01)
    }

    func testCardClampsToTheViewportEitherWay() {
        // A target pinned at the very top-left: "above" placement would go
        // negative — clamp to the 12pt margin.
        let origin = TourCardLayout.origin(
            targetRect: CGRect(x: 2, y: 2, width: 20, height: 20),
            cardHeight: 150,
            viewport: CGSize(width: 900, height: 700))
        XCTAssertGreaterThanOrEqual(origin.x, 12)
        XCTAssertGreaterThanOrEqual(origin.y, 12)
    }
}
