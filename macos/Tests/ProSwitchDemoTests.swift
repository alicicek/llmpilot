import XCTest
@testable import llmpilot

/// Chunk 4B: SwitchDemo.tsx's data derivation (`eduDemoLanes`/
/// `eduMaskedLanes`/`SwitchDemoModel.lineFor`) and its animation loop
/// (`SwitchDemoModel`), driven entirely through `ManualEduClock`.
@MainActor
final class ProSwitchDemoTests: XCTestCase {
    // MARK: - constants (pinned against SwitchDemo.tsx)

    func test_constantsMatchSource() {
        // 2026-08-09 beat table, climb retold by the owner 2026-08-13:
        // 71→97 over 1400ms — the visible ride to one tick under the wall,
        // matching the adaptive engine's Max-20× ceiling.
        XCTAssertEqual(SwitchDemoModel.restMs, 300)
        XCTAssertEqual(SwitchDemoModel.climbMs, 1400)
        XCTAssertEqual(SwitchDemoModel.handoffMs, 200)
        XCTAssertEqual(SwitchDemoModel.settleDelayMs, 300)
        XCTAssertEqual(SwitchDemoModel.startPercent, 71, "①'s own starting number — one story, two screens")
        XCTAssertEqual(SwitchDemoModel.switchPercent, 97, "one tick under the wall — still BEFORE it, never at 100")
    }

    // MARK: - lineFor

    func test_lineFor_withResets() {
        let lanes = [
            EduLane(email: "a@x.com", low: 20, resets: "10:00"),
            EduLane(email: "b@x.com", low: 10, resets: "11:00"),
        ]
        XCTAssertEqual(
            SwitchDemoModel.lineFor(lanes: lanes, spent: 0, next: 1),
            "Switched to b@x.com — a@x.com rests until 10:00"
        )
    }

    func test_lineFor_withoutResets() {
        let lanes = [
            EduLane(email: "a@x.com", low: 20, resets: nil),
            EduLane(email: "b@x.com", low: 10, resets: "11:00"),
        ]
        XCTAssertEqual(
            SwitchDemoModel.lineFor(lanes: lanes, spent: 0, next: 1),
            "Switched to b@x.com — a@x.com rests until its window resets"
        )
    }

    // MARK: - eduMaskedLanes (web/src/fixtures.ts's masked pair)

    func test_maskedLanes_matchFixtureState() {
        XCTAssertEqual(eduMaskedLanes, [
            EduLane(email: "kai@example.dev", low: 9, resets: "17:19"),
            EduLane(email: "mira@example.dev", low: 0, resets: nil),
        ])
    }

    // MARK: - eduDemoLanes

    private func account(id: String, email: String, percent: Double?, resetsAt: Date? = nil) -> AccountState {
        let snapshot = percent.map {
            UsageSnapshot(asOf: Date(), buckets: [
                Bucket(kind: "session", scope: nil, percent: $0, resetsAt: resetsAt, severity: nil, active: true),
            ])
        }
        return AccountState(id: id, label: id, email: email, pinned: false, snapshot: snapshot, tokenNote: nil, stale: nil, configDir: nil)
    }

    private func state(accounts: [AccountState], activeID: String?) -> DaemonState {
        DaemonState(accounts: accounts, activeID: activeID, schedules: [], asOf: Date())
    }

    func test_eduDemoLanes_nilWithFewerThanTwoDistinctEmails() {
        XCTAssertNil(eduDemoLanes(state(accounts: [account(id: "a", email: "a@x.com", percent: 10)], activeID: "a")))
        XCTAssertNil(eduDemoLanes(state(accounts: [], activeID: nil)))
    }

    func test_eduDemoLanes_dedupesByEmailKeepingTheFirstSeen() {
        let s = state(accounts: [
            account(id: "a1", email: "dup@x.com", percent: 10),
            account(id: "a2", email: "dup@x.com", percent: 90), // same email, later id: dropped
            account(id: "a3", email: "b@x.com", percent: 50),
        ], activeID: "a1")
        // Only two DISTINCT emails exist ("dup@x.com" kept as a1, "b@x.com"):
        // active = a1 (10%), target = the lowest of the rest = b (50%).
        XCTAssertEqual(eduDemoLanes(s), [
            EduLane(email: "dup@x.com", low: 10, resets: nil),
            EduLane(email: "b@x.com", low: 50, resets: nil),
        ])
    }

    func test_eduDemoLanes_pairsActiveWithTheLowestHeadroomRemaining() {
        let s = state(accounts: [
            account(id: "alex", email: "alex@x.com", percent: 98),
            account(id: "kai", email: "kai@x.com", percent: 9),
            account(id: "mira", email: "mira@x.com", percent: 0),
        ], activeID: "kai")
        // Mirrors web/src/fixtures.ts's story exactly: active=kai(9%),
        // remaining sorted ascending by percent (alex 98, mira 0) -> mira.
        XCTAssertEqual(eduDemoLanes(s), [
            EduLane(email: "kai@x.com", low: 9, resets: nil),
            EduLane(email: "mira@x.com", low: 0, resets: nil),
        ])
    }

    func test_eduDemoLanes_fallsBackToFirstAccountWhenActiveIDUnmatched() {
        let s = state(accounts: [
            account(id: "a", email: "a@x.com", percent: 40),
            account(id: "b", email: "b@x.com", percent: 60),
        ], activeID: "not-in-the-fleet")
        XCTAssertEqual(eduDemoLanes(s)?.first?.email, "a@x.com")
    }

    // MARK: - narrative line copy

    func test_approachingAndSwitchingLines() {
        XCTAssertEqual(SwitchDemoModel.approachingLine, "Approaching session limit")
        let lane = EduLane(email: "b@x.com", low: 10, resets: "11:00")
        XCTAssertEqual(SwitchDemoModel.switchingLine(to: lane), "Switching to b@x.com…")
    }

    func test_voiceOverSummary_isOneCoherentSentence() {
        let lanes = [
            EduLane(email: "a@x.com", low: 20, resets: "10:00"),
            EduLane(email: "b@x.com", low: 10, resets: "11:00"),
        ]
        XCTAssertEqual(
            SwitchDemoModel.voiceOverSummary(lanes: lanes, spent: 0, next: 1),
            "Switched to b@x.com. a@x.com rests until 10:00."
        )
    }

    // MARK: - SwitchDemoModel: reduced motion

    func test_switchDemo_reducedMotionCollapsesToPostSwitchFrame() {
        let lanes = [
            EduLane(email: "a@x.com", low: 20, resets: "10:00"),
            EduLane(email: "b@x.com", low: 10, resets: "11:00"),
        ]
        let model = SwitchDemoModel(lanes: lanes, reducedMotion: true, clock: ManualEduClock())
        XCTAssertEqual(model.active, 1)
        XCTAssertEqual(model.percentA, 97, "A's fixed narrative bookend, not lanes[0].low")
        XCTAssertEqual(model.percentB, 10, "B's own real low")
        XCTAssertEqual(model.restingIndex, 0)
        XCTAssertTrue(model.settled)
        XCTAssertEqual(model.line, "Switched to b@x.com — a@x.com rests until 10:00")
    }

    // MARK: - SwitchDemoModel: the one-shot beat, start to settle

    func test_switchDemo_runsOnceAndSettles() {
        let lanes = [
            EduLane(email: "a@x.com", low: 20, resets: "10:00"),
            EduLane(email: "b@x.com", low: 10, resets: "11:00"),
        ]
        let clock = ManualEduClock()
        let model = SwitchDemoModel(lanes: lanes, reducedMotion: false, clock: clock)
        model.start()

        XCTAssertEqual(model.active, 0)
        XCTAssertEqual(model.percentA, 71)
        XCTAssertEqual(model.percentB, 10)
        XCTAssertNil(model.restingIndex)
        XCTAssertNil(model.line)
        XCTAssertFalse(model.settled)

        clock.advance(byMs: 299)
        XCTAssertNil(model.line, "still resting")

        clock.advance(byMs: 1) // restMs (300) elapses
        XCTAssertEqual(model.line, "Approaching session limit")
        XCTAssertEqual(model.percentA, 97, "the climb is ONE jump — the view animates the fill over climbMs")
        XCTAssertEqual(model.active, 0, "not yet — the visual flip waits for the climb + handoff")

        clock.advance(byMs: 1399)
        XCTAssertEqual(model.line, "Approaching session limit", "still climbing")
        clock.advance(byMs: 1) // climbMs (1400) elapses: 97% reached
        XCTAssertEqual(model.line, "Switching to b@x.com…")
        XCTAssertEqual(model.active, 0, "copy changes before the flip — never the reverse")
        XCTAssertNil(model.restingIndex)

        clock.advance(byMs: 199)
        XCTAssertEqual(model.active, 0)
        clock.advance(byMs: 1) // handoffMs (200) elapses: the flip lands
        XCTAssertEqual(model.active, 1, "the flip lands in the SAME beat the copy is already showing")
        XCTAssertEqual(model.restingIndex, 0)
        XCTAssertFalse(model.settled, "the composed summary line hasn't landed yet")

        clock.advance(byMs: 299)
        XCTAssertFalse(model.settled)
        clock.advance(byMs: 1) // settleDelayMs (300) elapses: 2200ms total
        XCTAssertTrue(model.settled)
        XCTAssertEqual(model.line, "Switched to b@x.com — a@x.com rests until 10:00")
        XCTAssertEqual(clock.nowMs, 2200)
    }

    func test_switchDemo_stopCancelsPendingBeats() {
        let lanes = [
            EduLane(email: "a@x.com", low: 20, resets: nil),
            EduLane(email: "b@x.com", low: 10, resets: nil),
        ]
        let clock = ManualEduClock()
        let model = SwitchDemoModel(lanes: lanes, reducedMotion: false, clock: clock)
        model.start()
        model.stop()
        clock.advance(byMs: 10_000)
        XCTAssertEqual(model.percentA, 71, "no timer should have survived stop()")
        XCTAssertEqual(model.active, 0)
        XCTAssertNil(model.line)
        XCTAssertFalse(model.settled)
    }

    func test_switchDemo_replayRunsTheSequenceAgain() {
        let lanes = [
            EduLane(email: "a@x.com", low: 20, resets: "10:00"),
            EduLane(email: "b@x.com", low: 10, resets: "11:00"),
        ]
        let clock = ManualEduClock()
        let model = SwitchDemoModel(lanes: lanes, reducedMotion: false, clock: clock)
        model.start()
        clock.advance(byMs: 2200)
        XCTAssertTrue(model.settled)

        // Replay (the native control just calls start() again): the whole
        // sequence resets and runs once more, not a resumed loop.
        model.start()
        XCTAssertEqual(model.active, 0)
        XCTAssertEqual(model.percentA, 71)
        XCTAssertNil(model.restingIndex)
        XCTAssertNil(model.line)
        XCTAssertFalse(model.settled)
        clock.advance(byMs: 2200)
        XCTAssertTrue(model.settled)
    }
}
