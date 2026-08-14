import XCTest
@testable import llmpilot

/// Chunk 4B: the education screens' beat drivers (Pro/
/// EducationTimingModels.swift) and their pure math helpers (Pro/
/// EducationMath.swift), driven entirely through `ManualEduClock` — no
/// real sleeps anywhere in this file.
@MainActor
final class ProEducationTimingTests: XCTestCase {
    // MARK: - constants (pinned against Education.tsx)

    func test_wallBeat_constantsMatchSource() {
        XCTAssertEqual(WallBeatModel.startPercent, 71)
        XCTAssertEqual(WallBeatModel.endPercent, 100)
        XCTAssertEqual(WallBeatModel.restMs, 300, "design critique 2026-08-09 beat table")
        XCTAssertEqual(WallBeatModel.fillMs, 900, "design critique 2026-08-09 beat table")
    }

    func test_blindSpotBeat_constantsMatchSource() {
        XCTAssertEqual(BlindSpotBeatModel.revealDelayMs, 350, "design critique 2026-08-09 beat table")
        XCTAssertEqual(BlindSpotBeatModel.revealFadeMs, 200, "design critique 2026-08-09 beat table")
    }

    func test_windowsBeat_constantsMatchSource() {
        XCTAssertEqual(WindowsBeatModel.bookedDelayMs, 450, "design critique 2026-08-09 beat table")
        XCTAssertEqual(WindowsBeatModel.openedDelayMs, 1500, "design critique 2026-08-09 beat table")
    }

    /// DELIBERATE DIVERGENCE from Education.tsx's 01:00–06:00/07:40 board
    /// (owner 2026-08-12): the native ⑤ tells the schedule-on-autopilot
    /// story — booked for 07:00, resets 12:00, the now-line at 10:20
    /// INSIDE the block, mid-window on a tank that opened on its own.
    func test_educationMath_windowsConstantsTellTheAutopilotStory() {
        XCTAssertEqual(EducationMath.windowsHeaderWidth, 228, "Education.tsx:419 HDR_PX — unchanged")
        XCTAssertEqual(EducationMath.windowsNowMinutes, 10 * 60 + 20)
        XCTAssertEqual(EducationMath.windowsNowLabel, "10:20")
        XCTAssertEqual(EducationMath.windowsBlockStartMinutes, 7 * 60)
        XCTAssertEqual(EducationMath.windowsBlockEndMinutes, 12 * 60)
        XCTAssertEqual(
            EducationMath.windowsBlockEndMinutes - EducationMath.windowsBlockStartMinutes, 300,
            "the drawn block must stay exactly the 5-hour window the lede promises")
        XCTAssertTrue(
            (EducationMath.windowsBlockStartMinutes..<EducationMath.windowsBlockEndMinutes)
                .contains(EducationMath.windowsNowMinutes),
            "the now-line sits INSIDE the block — mid-window is the whole story")
    }

    // MARK: - EducationMath pure helpers

    func test_futureInstant_roundsDownToTheLocalHour_hoursAhead() {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 8; comps.day = 7
        comps.hour = 14; comps.minute = 22; comps.second = 9
        let now = Calendar.current.date(from: comps)!
        let result = EducationMath.futureInstant(hoursFromNow: 3, now: now)
        let out = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: result)
        XCTAssertEqual(out.hour, 17)
        XCTAssertEqual(out.minute, 0)
        XCTAssertEqual(out.second, 0)
    }

    func test_boardHour_isTodayAtTheGivenHour_zeroed() {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 8; comps.day = 7
        comps.hour = 23; comps.minute = 50
        let now = Calendar.current.date(from: comps)!
        let result = EducationMath.boardHour(6, now: now)
        let out = Calendar.current.dateComponents([.day, .hour, .minute, .second], from: result)
        XCTAssertEqual(out.day, 7, "same day as `now`, not tomorrow")
        XCTAssertEqual(out.hour, 6)
        XCTAssertEqual(out.minute, 0)
        XCTAssertEqual(out.second, 0)
    }

    func test_pctOfDay() {
        XCTAssertEqual(EducationMath.pctOfDay(0), 0)
        XCTAssertEqual(EducationMath.pctOfDay(12 * 60), 50)
        XCTAssertEqual(EducationMath.pctOfDay(24 * 60), 100)
    }

    // MARK: - ① WallBeatModel

    func test_wallBeat_fillsInOneShotThenReportsSpent() {
        let clock = ManualEduClock()
        let model = WallBeatModel(reducedMotion: false, clock: clock)
        model.start()
        XCTAssertEqual(model.percent, 71)
        XCTAssertFalse(model.spent)

        clock.advance(byMs: 299)
        XCTAssertEqual(model.percent, 71, "still resting")

        clock.advance(byMs: 1) // restMs elapses: ONE jump to 100, not a stepped climb
        XCTAssertEqual(model.percent, 100)
        XCTAssertFalse(model.spent, "the toast lands only once the fill's own duration elapses")

        clock.advance(byMs: 899)
        XCTAssertFalse(model.spent)
        clock.advance(byMs: 1) // fillMs elapses
        XCTAssertTrue(model.spent)
        XCTAssertEqual(model.percent, 100)
    }

    func test_wallBeat_reducedMotionCollapsesToFinalFrame() {
        let clock = ManualEduClock()
        let model = WallBeatModel(reducedMotion: true, clock: clock)
        XCTAssertEqual(model.percent, 100)
        XCTAssertTrue(model.spent)
        model.start() // guarded no-op — no timers registered
        clock.advance(byMs: 10_000)
        XCTAssertEqual(model.percent, 100)
        XCTAssertTrue(model.spent)
    }

    func test_wallBeat_stopCancelsPendingBeats() {
        let clock = ManualEduClock()
        let model = WallBeatModel(reducedMotion: false, clock: clock)
        model.start()
        model.stop()
        clock.advance(byMs: 10_000)
        XCTAssertEqual(model.percent, 71, "no timer should have survived stop()")
        XCTAssertFalse(model.spent)
    }

    // MARK: - ② BlindSpotBeatModel

    func test_blindSpotBeat_revealsAt350ms() {
        let clock = ManualEduClock()
        let model = BlindSpotBeatModel(reducedMotion: false, clock: clock)
        model.start()
        XCTAssertFalse(model.revealed)
        clock.advance(byMs: 349)
        XCTAssertFalse(model.revealed)
        clock.advance(byMs: 1)
        XCTAssertTrue(model.revealed)
    }

    func test_blindSpotBeat_reducedMotionCollapsesToRevealed() {
        let model = BlindSpotBeatModel(reducedMotion: true, clock: ManualEduClock())
        XCTAssertTrue(model.revealed)
    }

    // MARK: - ⑤ WindowsBeatModel

    func test_windowsBeat_booksThenGoesIdle() {
        let clock = ManualEduClock()
        let model = WindowsBeatModel(reducedMotion: false, clock: clock)
        model.start()
        XCTAssertFalse(model.booked)
        XCTAssertFalse(model.opened)

        clock.advance(byMs: 450)
        XCTAssertTrue(model.booked)
        XCTAssertFalse(model.opened)

        clock.advance(byMs: 1050) // total 1500
        XCTAssertTrue(model.opened)
    }

    func test_windowsBeat_reducedMotionCollapsesToFinalFrame() {
        let model = WindowsBeatModel(reducedMotion: true, clock: ManualEduClock())
        XCTAssertTrue(model.booked)
        XCTAssertTrue(model.opened)
    }
}
