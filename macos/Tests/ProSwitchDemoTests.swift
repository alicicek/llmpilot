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
        // F9 (2026-08-16 audit): the number-climb and post-handoff creep
        // tick constants.
        XCTAssertEqual(SwitchDemoModel.climbTickMs, 50)
        XCTAssertEqual(SwitchDemoModel.creepMs, 4000)
        XCTAssertEqual(SwitchDemoModel.creepTickMs, 200)
        XCTAssertEqual(SwitchDemoModel.creepAmount, 8, "mid the owner's requested 6–12% band")
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
        // F10 (2026-08-16 audit): SPEC-127 "demo identities read real" —
        // a real-looking domain, not the old @example.dev placeholder.
        XCTAssertEqual(eduMaskedLanes, [
            EduLane(email: "kai@llmpilot.dev", low: 9, resets: "17:19"),
            EduLane(email: "mira@llmpilot.dev", low: 0, resets: nil),
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
        XCTAssertEqual(model.percentA, 71, "the climb hasn't ticked yet — the first tick is climbTickMs away")
        XCTAssertEqual(model.active, 0, "not yet — the visual flip waits for the climb + handoff")

        // F9 (2026-08-16 audit): the NUMBER climbs with the bar now, not a
        // single jump to 97 — halfway through the 1400ms climb it reads
        // halfway between 71 and 97.
        clock.advance(byMs: 700)
        XCTAssertEqual(model.percentA, 84, "halfway through the climb")

        clock.advance(byMs: 699)
        XCTAssertEqual(model.line, "Approaching session limit", "still climbing")
        clock.advance(byMs: 1) // climbMs (1400) elapses: 97% reached
        XCTAssertEqual(model.line, "Switching to b@x.com…")
        XCTAssertEqual(model.percentA, 97, "A's fixed narrative bookend — legible AT the moment of the switch")
        XCTAssertEqual(model.active, 0, "copy changes before the flip — never the reverse")
        XCTAssertNil(model.restingIndex)

        clock.advance(byMs: 199)
        XCTAssertEqual(model.active, 0)
        clock.advance(byMs: 1) // handoffMs (200) elapses: the flip lands
        XCTAssertEqual(model.active, 1, "the flip lands in the SAME beat the copy is already showing")
        XCTAssertEqual(model.restingIndex, 0)
        XCTAssertFalse(model.settled, "the composed summary line hasn't landed yet")
        XCTAssertEqual(model.percentB, 10, "B's creep hasn't ticked yet — the first tick is creepTickMs away")

        clock.advance(byMs: 299)
        XCTAssertFalse(model.settled)
        clock.advance(byMs: 1) // settleDelayMs (300) elapses: 2200ms total
        XCTAssertTrue(model.settled)
        XCTAssertEqual(model.line, "Switched to b@x.com — a@x.com rests until 10:00")
        XCTAssertEqual(clock.nowMs, 2200)

        // F9: B keeps creeping in the background past `settled` — "you
        // keep working" doesn't stop just because the narrative line
        // landed. Halfway through the 4s creep (2000ms after handoff).
        clock.advance(byMs: 1700) // t = 3900 = handoff(1900) + 2000
        XCTAssertEqual(model.percentB, 14, "halfway through B's post-handoff creep")

        // The creep completes at handoff + creepMs (1900 + 4000 = 5900)
        // and stops exactly at its target — no drift after.
        clock.advance(byMs: 2000) // t = 5900
        XCTAssertEqual(model.percentB, 18, "B's creep bookend: low(10) + creepAmount(8)")
        clock.advance(byMs: 10_000)
        XCTAssertEqual(model.percentB, 18, "the creep stops at its target — no drift after completion")
    }

    // MARK: - SwitchDemoModel: F9 (2026-08-16 audit) — the two standalone claims

    /// "when it hits 97, it should switch" — A's percent must be legible
    /// AT the exact instant the climb completes, not lost inside an
    /// invisible jump that happened 1400ms earlier.
    func test_switchDemo_aPercentReads97AtTheMomentOfTheSwitch() {
        let clock = ManualEduClock()
        let model = SwitchDemoModel(lanes: eduMaskedLanes, reducedMotion: false, clock: clock)
        model.start()
        clock.advance(byMs: SwitchDemoModel.restMs + SwitchDemoModel.climbMs)
        XCTAssertEqual(model.percentA, SwitchDemoModel.switchPercent)
        XCTAssertEqual(model.line, SwitchDemoModel.switchingLine(to: eduMaskedLanes[1]))
    }

    /// the other account creeps upward after the handoff so the user sees
    /// work continue on it (audit 2026-08-16, F9).
    func test_switchDemo_bCreepsAfterHandoffButNotBefore() {
        let lanes = [
            EduLane(email: "a@x.com", low: 20, resets: "10:00"),
            EduLane(email: "b@x.com", low: 10, resets: "11:00"),
        ]
        let clock = ManualEduClock()
        let model = SwitchDemoModel(lanes: lanes, reducedMotion: false, clock: clock)
        model.start()
        let toHandoff = SwitchDemoModel.restMs + SwitchDemoModel.climbMs + SwitchDemoModel.handoffMs
        clock.advance(byMs: toHandoff)
        XCTAssertEqual(model.percentB, 10, "no creep before the handoff lands")
        clock.advance(byMs: SwitchDemoModel.creepMs)
        XCTAssertEqual(model.percentB, 10 + SwitchDemoModel.creepAmount, "B creeps up after the handoff")
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

        // Let B's creep progress a bit before replaying — proves Replay
        // resets the CREEP too, not just the headline beats.
        clock.advance(byMs: 1700) // t = 3900: B is mid-creep
        XCTAssertEqual(model.percentB, 14)

        // Replay (the native control just calls start() again): the whole
        // sequence resets and runs once more, not a resumed loop.
        model.start()
        XCTAssertEqual(model.active, 0)
        XCTAssertEqual(model.percentA, 71)
        XCTAssertEqual(model.percentB, 10, "B's mid-creep progress resets with everything else")
        XCTAssertNil(model.restingIndex)
        XCTAssertNil(model.line)
        XCTAssertFalse(model.settled)
        clock.advance(byMs: 2200)
        XCTAssertTrue(model.settled)

        // The creep isn't a one-shot side effect of the first run — it
        // fires again on the replayed pass too.
        clock.advance(byMs: SwitchDemoModel.creepMs)
        XCTAssertEqual(model.percentB, 18)
    }
}
