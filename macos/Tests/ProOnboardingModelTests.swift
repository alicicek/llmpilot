import XCTest
@testable import llmpilot

/// Phase 4 chunk A — defect-class tests for OnboardingModel.swift
/// (web/src/pro/Onboarding.tsx's phase state machine). Hermetic: no view,
/// no daemon.
@MainActor
final class ProOnboardingModelTests: XCTestCase {
    // MARK: - case-fold identity
    // web twin: firstrun.spec.ts "one identity spelled two ways is one
    // account, not two"

    func testIdentitiesFoldCaseAndKeepTheFirstSpellingSeen() {
        let accounts = [
            AccountState(id: "real-1", label: "real", email: "real-adopted@example.dev", pinned: false,
                         snapshot: nil, tokenNote: nil, stale: nil, configDir: "/Users/x/.claude"),
        ]
        let detected = [
            DetectedDir(configDir: "/Users/x/.claude-alt", email: "REAL-Adopted@Example.dev", registered: false),
        ]
        let identities = OnboardingModel.identities(accounts: accounts, detected: detected)
        // One identity, not two — and the FIRST spelling seen (the fleet's
        // own, lowercase) wins, not detection's differently-cased one.
        XCTAssertEqual(identities, ["real-adopted@example.dev"])
    }

    func testIdentitiesExcludeDetectedDirsConfirmedSignedOut() {
        let detected = [
            DetectedDir(configDir: "/Users/x/.claude", email: "a@example.dev", registered: false, signedIn: false),
        ]
        XCTAssertEqual(OnboardingModel.identities(accounts: [], detected: detected), [])
    }

    // MARK: - failed-license-fetch still offers exit
    // web twin: firstrun.spec.ts "no license at all (source build / failed
    // license fetch): the accounts screen still offers an exit"

    func testFailedLicenseFetchStartsOnAccountsWithAnExitPath() {
        // tour=false (the F1-class repro: one failed GET /v1/license), fleet
        // empty.
        let m = OnboardingModel(tour: false, startedEmpty: true)
        XCTAssertEqual(m.phase, .accounts)
        // The forward path must NOT depend on tour deciding one of the two
        // accounts-screen controls and stranding the other — both Continue
        // and "I'll sign in later" resolve through this ONE property.
        XCTAssertEqual(m.accountsForward, .exit)
    }

    // MARK: - zero-detection skip path
    // web twin: firstrun.spec.ts "no accounts detected: the empty state
    // offers skip → the wall on the demo fleet → no dead-end"

    func testZeroDetectionSkipWalksForwardOnToTheMaskedDemoFleet() {
        let m = OnboardingModel(tour: true, startedEmpty: true)
        XCTAssertEqual(m.phase, .wall)
        m.advance()
        XCTAssertEqual(m.phase, .blind)
        m.advance()
        XCTAssertEqual(m.phase, .accounts)
        // With a tour, "I'll sign in later" == Continue: skip is a forward
        // move, never an exit.
        XCTAssertEqual(m.accountsForward, .advance)
        m.advance()
        XCTAssertEqual(m.phase, .switchDemo)
        // Nothing was ever added — the switch demo runs on the masked
        // fixture pair, not an empty "real" fleet.
        XCTAssertTrue(m.resolvedMasked(accounts: []))
        m.advance()
        XCTAssertEqual(m.phase, .windows)
        m.advance()
        XCTAssertEqual(m.phase, .ask)
    }

    // MARK: - late license answer still gets the full ladder
    // web twin: firstrun.spec.ts "a licence that answers after the flow
    // opens still gets the full ladder"

    func testLateTourUpgradeResetsToTheWallRatherThanStrandingAccounts() {
        // An empty fleet mounts the flow the instant /v1/state lands, which
        // can be BEFORE /v1/license answers — tour starts false.
        let m = OnboardingModel(tour: false, startedEmpty: true)
        XCTAssertEqual(m.phase, .accounts)
        // The license answers ~700ms later: tour flips true. Without the
        // reset, `showOnboarding` would hold the flow open while the only
        // forward control on THIS screen called exit: stuck on accounts
        // forever (the original P0 this pins).
        m.updateTour(true)
        XCTAssertEqual(m.phase, .wall)
        XCTAssertTrue(m.tour)
        m.advance()
        XCTAssertEqual(m.phase, .blind)
        // The ladder now includes every education screen — not just the
        // accounts step it was reduced to before this fix.
        XCTAssertEqual(m.phases, [.wall, .blind, .accounts, .switchDemo, .windows])
    }

    func testTourOnlyEverGoesUp() {
        let m = OnboardingModel(tour: true, startedEmpty: false)
        m.advance() // wall -> blind
        XCTAssertEqual(m.phase, .blind)
        // A downgrade (activating flips props.tour false mid-flow) must be
        // ignored — no reset, no phase change.
        m.updateTour(false)
        XCTAssertTrue(m.tour)
        XCTAssertEqual(m.phase, .blind)
        // Already true: re-affirming it is a no-op, not another reset to wall.
        m.updateTour(true)
        XCTAssertEqual(m.phase, .blind)
    }

    // MARK: - ② (blind spot) skipped entirely on fewer than two identities
    // design critique 2026-08-09

    func testBlindSpotSkippedAndTotalShrinksWithFewerThanTwoIdentities() {
        let solo = OnboardingModel(tour: true, startedEmpty: false, identityCount: 1)
        XCTAssertEqual(solo.phases, [.wall, .switchDemo, .windows], "blind spot dropped, not replaced")
        XCTAssertEqual(solo.total, 3 + 4, "the step total shrinks with it — never a hardcoded 8")
        XCTAssertEqual(solo.phase, .wall)
        solo.advance()
        XCTAssertEqual(solo.phase, .switchDemo, "advancing from the wall skips straight past the blind spot")

        let zero = OnboardingModel(tour: true, startedEmpty: false, identityCount: 0)
        XCTAssertEqual(zero.phases, [.wall, .switchDemo, .windows])
    }

    func testBlindSpotIncludedWithTwoOrMoreIdentities() {
        let pair = OnboardingModel(tour: true, startedEmpty: false, identityCount: 2)
        XCTAssertEqual(pair.phases, [.wall, .blind, .switchDemo, .windows])
        XCTAssertEqual(pair.total, 4 + 4)
        pair.advance()
        XCTAssertEqual(pair.phase, .blind)

        let trio = OnboardingModel(tour: true, startedEmpty: false, identityCount: 3)
        XCTAssertEqual(trio.phases, [.wall, .blind, .switchDemo, .windows], "any count \u{2265}2 includes it, not just exactly 2")
    }

    func testIdentityCountDefaultsToIncludingBlindSpot() {
        // Existing callers that don't yet pass a real identity count keep
        // today's behaviour: ② stays in the ladder.
        let m = OnboardingModel(tour: true, startedEmpty: false)
        XCTAssertEqual(m.identityCount, 2)
        XCTAssertTrue(m.phases.contains(.blind))
    }

    // MARK: - ②'s gate settles while the user is still on ① (audit
    // 2026-08-11): the flow arms one round trip BEFORE /v1/detect answers,
    // so a construction-time freeze read 0 on every fresh machine and ②
    // never rendered for the multi-account audience it teaches.

    func testIdentityCountSettlesWhileStillOnTheWall() {
        let m = OnboardingModel(tour: true, startedEmpty: true, identityCount: 0)
        XCTAssertEqual(m.phases, [.wall, .accounts, .switchDemo, .windows])
        // Detection answers during ①'s own beat — ② joins the ladder and
        // the totals grow with it.
        m.updateIdentityCount(2)
        XCTAssertEqual(m.identityCount, 2)
        XCTAssertEqual(m.phases, [.wall, .blind, .accounts, .switchDemo, .windows])
        XCTAssertEqual(m.total, 5 + 4)
        m.advance()
        XCTAssertEqual(m.phase, .blind, "the settled count is what advance() walks")
    }

    func testIdentityCountIsCommittedOncePastTheWall() {
        // The guard's FAIL case: past ①, a late answer must not rewrite the
        // dots (or mount/unmount ②) under the user.
        let m = OnboardingModel(tour: true, startedEmpty: false, identityCount: 0)
        m.advance() // wall → switchDemo (no blind at count 0)
        XCTAssertEqual(m.phase, .switchDemo)
        m.updateIdentityCount(2)
        XCTAssertEqual(m.identityCount, 0, "committed — the ladder must not change shape mid-walk")
        XCTAssertEqual(m.phases, [.wall, .switchDemo, .windows])
    }

    func testLateTourUpgradeReopensTheIdentityCountWindow() {
        // updateTour's reset back to .wall restarts the ladder from the
        // beginning — the count window deliberately reopens with it.
        let m = OnboardingModel(tour: false, startedEmpty: true, identityCount: 0)
        XCTAssertEqual(m.phase, .accounts)
        m.updateIdentityCount(2)
        XCTAssertEqual(m.identityCount, 0, "no wall on screen — nothing is settling")
        m.updateTour(true)
        XCTAssertEqual(m.phase, .wall)
        m.updateIdentityCount(2)
        XCTAssertEqual(m.identityCount, 2)
        XCTAssertTrue(m.phases.contains(.blind))
    }

    // MARK: - accounts screen present only when the fleet started empty

    func testAccountsPhaseAbsentWhenTheFleetStartedNonEmpty() {
        let m = OnboardingModel(tour: true, startedEmpty: false)
        XCTAssertFalse(m.phases.contains(.accounts))
        XCTAssertEqual(m.phases, [.wall, .blind, .switchDemo, .windows])
    }

    // MARK: - the ask fallback ("ask" is never a member of `phases`)

    func testAdvanceFromTheLastPhaseLandsOnAskNotAWraparound() {
        let m = OnboardingModel(tour: true, startedEmpty: false)
        for expected: OnboardingPhase in [.blind, .switchDemo, .windows, .ask] {
            m.advance()
            XCTAssertEqual(m.phase, expected)
        }
        // Advancing again from "ask" (not a phases member: indexOf == -1)
        // must land on "ask" again, never loop back to phases[0] — a loop
        // with no exit now the corridor has removed the per-screen ✕.
        m.advance()
        XCTAssertEqual(m.phase, .ask)
    }

    // MARK: - the ask must survive a transient license failure

    func testResolvedLicenseCarriesThroughATransientGap() {
        let m = OnboardingModel(tour: true, startedEmpty: false)
        XCTAssertNil(m.resolvedLicense(nil))
        let known = try! DaemonDates.decoder().decode(
            LicenseInfo.self,
            from: Data(#"{"available":true,"active":false,"status":"none","nocard_trial_used":false}"#.utf8))
        XCTAssertEqual(m.resolvedLicense(known), known)
        // A refetch (activation poll, or a blip) nulls the license again —
        // the ask must not go blank.
        XCTAssertEqual(m.resolvedLicense(nil), known)
    }

    // MARK: - tour-follows-first-run
    // web twin: tour.spec.ts "the guide follows the first-run flow rather
    // than being consumed by it"
    //
    // The Tour OVERLAY component itself (its own steps, "Show me around",
    // the real-cockpit-element spotlighting) is UI, not modeled by this
    // pure-model chunk — deferred to the screens chunk. What this chunk CAN
    // pin: the onboarding ladder always reaches a real, working terminal
    // exit (never a stuck state a later "open the guide" hook could not
    // fire from).

    func testOnboardingReachesAWorkingExitEvenWithNoQuoteMocked() {
        let onboarding = OnboardingModel(tour: true, startedEmpty: false)
        for _ in 0..<3 { onboarding.advance() } // wall -> blind -> switch -> windows
        onboarding.advance()
        XCTAssertEqual(onboarding.phase, .ask)

        var dismissed = 0
        let license = try! DaemonDates.decoder().decode(
            LicenseInfo.self,
            from: Data(#"{"available":true,"active":false,"status":"none","nocard_trial_used":false}"#.utf8))
        let ask = AskMachine(
            license: license, quote: nil, guided: true, locale: "en-GB",
            winback: freshWinback(), api: StubCockpitAPI(), onDismiss: { dismissed += 1 })

        // No quote mocked: the ask owes an exit even with nothing to state
        // a price on — and it is the flow's ONLY one at this point.
        XCTAssertEqual(ask.screen, .noTerms)
        XCTAssertTrue(ask.closeButtonVisible)
        ask.close()
        XCTAssertEqual(dismissed, 1)
    }
}
