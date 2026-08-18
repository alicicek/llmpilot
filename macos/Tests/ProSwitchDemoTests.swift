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
            "Switched to b@x.com — a@x.com resets at 10:00"
        )
    }

    func test_lineFor_withoutResets() {
        let lanes = [
            EduLane(email: "a@x.com", low: 20, resets: nil),
            EduLane(email: "b@x.com", low: 10, resets: "11:00"),
        ]
        XCTAssertEqual(
            SwitchDemoModel.lineFor(lanes: lanes, spent: 0, next: 1),
            "Switched to b@x.com — a@x.com resets when its window does"
        )
    }

    // MARK: - eduMaskedLanes (web/src/fixtures.ts's masked pair)

    func test_maskedLanes_matchFixtureState() {
        // F10 (2026-08-16 audit): SPEC-127 "demo identities read real" —
        // a real-looking domain, not the old @example.dev placeholder.
        // A FUNCTION of now: the pair used to hardcode "17:19", which is a
        // reset in the PAST for anyone walking the corridor after tea time —
        // and once the caption names the distance too, a fixed clock reads
        // "~-2h". The story is "about three hours stuck", so that is what it
        // stores and the clock is derived.
        let now = Date(timeIntervalSince1970: 1_755_500_000)
        let lanes = eduMaskedLanes(now: now)
        XCTAssertEqual(lanes.map(\.email), ["kai@llmpilot.dev", "mira@llmpilot.dev"])
        XCTAssertEqual(lanes.map(\.low), [9, 0])
        XCTAssertEqual(lanes[0].restsForMinutes, 3 * 60 + 19)
        XCTAssertEqual(lanes[0].resets, EducationMath.hhmm(now.addingTimeInterval(199 * 60)))
        XCTAssertNil(lanes[1].resets, "the second lane has no reset to name")
        XCTAssertNil(lanes[1].restsForMinutes)
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
            "Switched to b@x.com. a@x.com resets at 10:00."
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
        XCTAssertEqual(model.line, "Switched to b@x.com — a@x.com resets at 10:00")
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
        XCTAssertEqual(model.line, "Switched to b@x.com — a@x.com resets at 10:00")
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
        let model = SwitchDemoModel(lanes: eduMaskedLanes(), reducedMotion: false, clock: clock)
        model.start()
        clock.advance(byMs: SwitchDemoModel.restMs + SwitchDemoModel.climbMs)
        XCTAssertEqual(model.percentA, SwitchDemoModel.switchPercent)
        XCTAssertEqual(model.line, SwitchDemoModel.switchingLine(to: eduMaskedLanes()[1]))
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
    // MARK: - the rested lane's caption (owner 2026-08-18): the reset clock
    // AND roughly how long the lane rests, never the clock alone.

    func testRestCaptionNamesTheClockAndRoughlyHowLong() {
        XCTAssertEqual(
            SwitchDemoModel.restCaption(resets: "17:19", restsForMinutes: 3 * 60 + 19),
            "Resets at 17:19 · ~3h")
        // Rounds to whole hours above an hour — the "~" is doing that work.
        XCTAssertEqual(
            SwitchDemoModel.restCaption(resets: "20:40", restsForMinutes: 3 * 60 + 40),
            "Resets at 20:40 · ~4h")
    }

    func testRestCaptionKeepsMinutesUnderAnHour() {
        // 45 minutes rounded to "~1h" would overstate the wait on the one
        // screen that is arguing about waiting.
        XCTAssertEqual(SwitchDemoModel.approxDuration(minutes: 45), "45m")
        XCTAssertEqual(SwitchDemoModel.approxDuration(minutes: 59), "59m")
        XCTAssertEqual(SwitchDemoModel.approxDuration(minutes: 60), "1h")
        XCTAssertEqual(
            SwitchDemoModel.restCaption(resets: "09:05", restsForMinutes: 45),
            "Resets at 09:05 · ~45m")
    }

    func testRestCaptionFallsBackRatherThanGuessing() {
        XCTAssertEqual(
            SwitchDemoModel.restCaption(resets: "17:19", restsForMinutes: nil),
            "Resets at 17:19", "unknown distance shows the clock alone")
        XCTAssertEqual(
            SwitchDemoModel.restCaption(resets: "17:19", restsForMinutes: 0),
            "Resets at 17:19", "a reset already due carries no distance")
        XCTAssertEqual(
            SwitchDemoModel.restCaption(resets: nil, restsForMinutes: nil),
            "Resets when its window does")
    }

    func testALaneWhoseResetHasPassedCarriesNoDistance() {
        let now = Date(timeIntervalSince1970: 1_755_500_000)
        let stale = state(
            accounts: [
                account(id: "a", email: "a@x.com", percent: 90, resetsAt: now.addingTimeInterval(-3600)),
                account(id: "b", email: "b@x.com", percent: 10, resetsAt: now.addingTimeInterval(7200)),
            ],
            activeID: "a")
        let lanes = try! XCTUnwrap(eduDemoLanes(stale, now: now))
        XCTAssertNil(lanes[0].restsForMinutes, "a stale snapshot must not render \"~-1h\"")
        XCTAssertEqual(lanes[1].restsForMinutes, 120)
    }

    func testTheSettledSentenceCarriesTheDistanceToo() {
        let lanes = [
            EduLane(email: "a@x.com", low: 20, resets: "10:00", restsForMinutes: 3 * 60 + 19),
            EduLane(email: "b@x.com", low: 10, resets: nil),
        ]
        XCTAssertEqual(
            SwitchDemoModel.lineFor(lanes: lanes, spent: 0, next: 1),
            "Switched to b@x.com — a@x.com resets at 10:00, ~3h away")
        // VoiceOver reads "3h" as "three h", so it gets the words.
        XCTAssertEqual(
            SwitchDemoModel.voiceOverSummary(lanes: lanes, spent: 0, next: 1),
            "Switched to b@x.com. a@x.com resets at 10:00, about 3 hours away.")
        XCTAssertEqual(SwitchDemoModel.approxDurationSpoken(minutes: 60), "about 1 hour")
        XCTAssertEqual(SwitchDemoModel.approxDurationSpoken(minutes: 45), "about 45 minutes")
    }

}
