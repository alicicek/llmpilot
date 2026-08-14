import XCTest
@testable import llmpilot

/// Covers BoardInspector.swift's pure derivation helpers — a native port of
/// web/src/board/Inspector.tsx's inline math. No golden-vector file here
/// (Inspector.tsx isn't part of the cross-stack pinned set); these assert
/// directly against the ported formulas.
final class InspectorDerivationTests: XCTestCase {
    private func ls(trigger: Int, reset: Int, chained: Bool = false) -> BoardClassify.LaneSchedule {
        BoardClassify.LaneSchedule(
            schedule: .init(id: "s1", accountID: "a1", hour: trigger / 60, minute: trigger % 60),
            trigger: trigger, reset: reset, chained: chained
        )
    }

    // MARK: - dl-row math

    func testRowsWithoutChainTargetOmitsGapRow() {
        let rows = BoardInspectorDerivation.rows(ls: ls(trigger: 0, reset: 300), chainTarget: nil)
        XCTAssertEqual(rows.autoNudge, "00:00")
        XCTAssertEqual(rows.chargesUnattended, "00:00 – 05:00")
        XCTAssertEqual(rows.freshAndFull, "from 05:00")
        XCTAssertNil(rows.gapToNextReset)
    }

    func testGapExactly315IsOK() {
        // reset=300 (05:00), chainTarget=615 (10:15) — circularGap == 315 == MIN_GAP_MIN.
        let rows = BoardInspectorDerivation.rows(ls: ls(trigger: 0, reset: 300), chainTarget: 615)
        XCTAssertEqual(BoardSchedule.circularGap(300, 615), 315)
        XCTAssertEqual(rows.gapToNextReset, "05:15 ✓︎")
    }

    func testGap314IsWarn() {
        // One minute short of the 315 floor must flip to the warn glyph.
        let rows = BoardInspectorDerivation.rows(ls: ls(trigger: 0, reset: 300), chainTarget: 614)
        XCTAssertEqual(BoardSchedule.circularGap(300, 614), 314)
        XCTAssertEqual(rows.gapToNextReset, "05:14 ⚠︎")
    }

    func testGap316IsOK() {
        let rows = BoardInspectorDerivation.rows(ls: ls(trigger: 0, reset: 300), chainTarget: 616)
        XCTAssertEqual(rows.gapToNextReset, "05:16 ✓︎")
    }

    // MARK: - card-visibility exclusivity table vs ChipClass

    private struct VisCase {
        let cls: BoardClassify.ChipClass
        let chained: Bool
        let hasMid: Bool
        let idle: Bool
        let blocked: Bool
        let missed: Bool
        let chainedCard: Bool
        let ran: Bool
        let line: UInt
    }

    func testCardVisibilityTable() {
        let mid = BoardClassify.MidWindow(start: 0, end: 100)
        let cases: [VisCase] = [
            // upcoming, standalone — idle-dependency only.
            VisCase(cls: .upcoming, chained: false, hasMid: false,
                     idle: true, blocked: false, missed: false, chainedCard: false, ran: false, line: #line),
            // upcoming, chained — chained card only.
            VisCase(cls: .upcoming, chained: true, hasMid: false,
                     idle: false, blocked: false, missed: false, chainedCard: true, ran: false, line: #line),
            // missed — idle-dependency card ALSO shows (Inspector.tsx's
            // explicit "missed-today or not" comment).
            VisCase(cls: .missed, chained: false, hasMid: false,
                     idle: true, blocked: false, missed: true, chainedCard: false, ran: false, line: #line),
            // charging only reaches classify() when chained (see
            // BoardClassify.classify) — chained card only.
            VisCase(cls: .charging, chained: true, hasMid: false,
                     idle: false, blocked: false, missed: false, chainedCard: true, ran: false, line: #line),
            // blocked with a mid-window present — blocked card only, idle
            // explicitly excluded (`cls !== "blocked"`).
            VisCase(cls: .blocked, chained: false, hasMid: true,
                     idle: false, blocked: true, missed: false, chainedCard: false, ran: false, line: #line),
            // blocked WITHOUT a mid-window (defensive: classify() can't
            // reach this, the card still requires `mid` non-nil).
            VisCase(cls: .blocked, chained: false, hasMid: false,
                     idle: false, blocked: false, missed: false, chainedCard: false, ran: false, line: #line),
            // ran, standalone — idle-dependency AND ran both show (mockup's
            // "alongside, not instead of").
            VisCase(cls: .ran, chained: false, hasMid: false,
                     idle: true, blocked: false, missed: false, chainedCard: false, ran: true, line: #line),
            // ran, chained — chained AND ran both show.
            VisCase(cls: .ran, chained: true, hasMid: false,
                     idle: false, blocked: false, missed: false, chainedCard: true, ran: true, line: #line),
            // blocked AND chained can co-occur (classify() checks blocked
            // FIRST, independent of chained) — both cards show.
            VisCase(cls: .blocked, chained: true, hasMid: true,
                     idle: false, blocked: true, missed: false, chainedCard: true, ran: false, line: #line),
        ]

        for c in cases {
            let lane = ls(trigger: 0, reset: 300, chained: c.chained)
            let v = BoardInspectorDerivation.cardVisibility(ls: lane, cls: c.cls, mid: c.hasMid ? mid : nil)
            XCTAssertEqual(v.idleDependency, c.idle, "idle mismatch for \(c.cls)/chained=\(c.chained)/mid=\(c.hasMid)", line: c.line)
            XCTAssertEqual(v.blocked, c.blocked, "blocked mismatch for \(c.cls)/chained=\(c.chained)/mid=\(c.hasMid)", line: c.line)
            XCTAssertEqual(v.missed, c.missed, "missed mismatch for \(c.cls)/chained=\(c.chained)/mid=\(c.hasMid)", line: c.line)
            XCTAssertEqual(v.chained, c.chainedCard, "chained mismatch for \(c.cls)/chained=\(c.chained)/mid=\(c.hasMid)", line: c.line)
            XCTAssertEqual(v.ran, c.ran, "ran mismatch for \(c.cls)/chained=\(c.chained)/mid=\(c.hasMid)", line: c.line)
        }
    }

    // MARK: - chain/catch-up labels

    func testCatchUpLabelAddsWindow() {
        XCTAssertEqual(BoardInspectorDerivation.catchUpLabel(nowMinutes: 60), "06:00") // 60 + 300 (5h window) = 360
    }

    func testChainResultLabelWrapsDay() {
        // chainTarget near midnight: 1400 (23:20) + 300 (5h) wraps past DAY_MIN.
        XCTAssertEqual(BoardInspectorDerivation.chainResultLabel(chainTarget: 1400), BoardSchedule.fmtHM((1400 + 300) % 1440))
        XCTAssertNil(BoardInspectorDerivation.chainResultLabel(chainTarget: nil))
    }

    func testBlockedLabels() {
        let mid = BoardClassify.MidWindow(start: 100, end: 1400) // 23:20
        let labels = BoardInspectorDerivation.blockedLabels(mid: mid)
        XCTAssertEqual(labels.retries, "23:20")
        XCTAssertEqual(labels.landsAt, BoardSchedule.fmtHM((1400 + 300) % 1440))
    }
}
