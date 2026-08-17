import AppKit
import SwiftUI
import XCTest

@testable import llmpilot

/// Phase 4 chunk 4C — VIEW-WIRING tests for OnboardingFlowView.swift. Phase
/// sequencing itself is pinned by ProOnboardingModelTests; these tests pin
/// the screen-SELECTION this chunk's chrome adds on top (`OnboardingRenderKind
/// .resolve`, `OnboardingAccountsCopy.continueLabel`) plus crash-safety
/// mounting for every phase, including the placeholder slots education
/// screens will occupy once the sibling Pro/ builder's work lands.
@MainActor
final class OnboardingFlowViewTests: XCTestCase {
    // MARK: - OnboardingRenderKind.resolve — phase → screen selection

    func testEducationPhasesResolveToNamedPlaceholderSlots() {
        XCTAssertEqual(OnboardingRenderKind.resolve(phase: .wall, hasAsk: false), .educationSlot(phase: "wall"))
        XCTAssertEqual(OnboardingRenderKind.resolve(phase: .blind, hasAsk: false), .educationSlot(phase: "blind"))
        XCTAssertEqual(OnboardingRenderKind.resolve(phase: .switchDemo, hasAsk: false), .educationSlot(phase: "switch"))
        XCTAssertEqual(OnboardingRenderKind.resolve(phase: .windows, hasAsk: false), .educationSlot(phase: "windows"))
    }

    func testAccountsPhaseAlwaysResolvesToAccountsRegardlessOfAsk() {
        XCTAssertEqual(OnboardingRenderKind.resolve(phase: .accounts, hasAsk: false), .accounts)
        XCTAssertEqual(OnboardingRenderKind.resolve(phase: .accounts, hasAsk: true), .accounts)
    }

    func testAskPhaseFallsBackToTheEducationSlotWithoutAnAskMachine() {
        // Onboarding.tsx:210-218 — no license at all yet renders the SAME
        // screen the switch-demo phase does.
        XCTAssertEqual(OnboardingRenderKind.resolve(phase: .ask, hasAsk: false), .askFallback)
        XCTAssertEqual(OnboardingRenderKind.resolve(phase: .ask, hasAsk: true), .ask)
    }

    // MARK: - OnboardingAccountsCopy.headline — design critique 2026-08-09
    // ("Let's find yours." contradicted the very next line once detection
    // landed — the accounts empty-state funnel-bug fix's companion copy
    // change).

    func testAccountsHeadlineStillLoadingIsNeitherAPromiseNorAnAnswer() {
        XCTAssertEqual(OnboardingAccountsCopy.headline(detected: nil, groupCount: 0), "Finding your accounts…")
    }

    func testAccountsHeadlineZeroFoundAsksForTheActionNotADeadEnd() {
        // Owner 2026-08-10: "No signed-in accounts found." stated a negative
        // and asked for nothing, and the fixed lede then contradicted it.
        XCTAssertEqual(OnboardingAccountsCopy.headline(detected: [], groupCount: 0), "Add your Claude account.")
    }

    // MARK: - the lede tracks the same state as the headline, so the screen
    // can never say "we found none" and "add the ones you want" at once.

    func testAccountsLedeNeverRefersToAccountsThatWereNotFound() {
        let zero = OnboardingAccountsCopy.lede(detected: [], groupCount: 0)
        XCTAssertFalse(zero.contains("the ones"), "nothing to refer to: \(zero)")
        // Detected accounts are adopted automatically now, so the lede
        // states that instead of asking for an action (owner 2026-08-11).
        XCTAssertEqual(
            OnboardingAccountsCopy.lede(detected: [], groupCount: 2),
            "Signed in on this Mac — llmpilot is adding them and will watch their limits live.")
        XCTAssertEqual(
            OnboardingAccountsCopy.lede(detected: nil, groupCount: 0),
            "Checking this Mac for signed-in Claude accounts.")
    }

    func testAccountsHeadlineSingularVsPluralCount() {
        XCTAssertEqual(OnboardingAccountsCopy.headline(detected: [], groupCount: 1), "We found 1 account.")
        XCTAssertEqual(OnboardingAccountsCopy.headline(detected: [], groupCount: 2), "We found 2 accounts.")
    }

    // MARK: - F6 (audit 2026-08-16): number agreement — the headline said
    // "We found 1 account." and the lede beneath it said "adding THEM" for
    // the same single account.

    func testAccountsLedeAgreesInNumberWithTheHeadlineItSitsUnder() {
        XCTAssertEqual(
            OnboardingAccountsCopy.lede(detected: [], groupCount: 1),
            "Signed in on this Mac — llmpilot is adding it and will watch its limits live.")
        XCTAssertEqual(
            OnboardingAccountsCopy.lede(detected: [], groupCount: 2),
            "Signed in on this Mac — llmpilot is adding them and will watch their limits live.")
    }

    // MARK: - OnboardingAccountsCopy.rowIsAmbiguous — the raw config-dir
    // path renders ONLY when another row would read as the same email at a
    // glance (design critique 2026-08-09).

    func testRowIsAmbiguousOnlyWhenAnotherGroupSharesTheEmailCaseInsensitively() {
        let dirA = DetectedDir(configDir: "/Users/x/.claude", email: "Bob@example.com", registered: false)
        let dirB = DetectedDir(configDir: "/Users/x/.claude-work", email: "bob@example.com", registered: false)
        let dirC = DetectedDir(configDir: "/Users/x/.claude-solo", email: "solo@example.com", registered: false)
        let groups = LadderLogic.groupByEmail([dirA, dirB, dirC])
        XCTAssertEqual(groups.count, 3, "groupByEmail is case-SENSITIVE — three distinct rows")

        XCTAssertTrue(OnboardingAccountsCopy.rowIsAmbiguous("Bob@example.com", among: groups))
        XCTAssertTrue(OnboardingAccountsCopy.rowIsAmbiguous("bob@example.com", among: groups))
        XCTAssertFalse(
            OnboardingAccountsCopy.rowIsAmbiguous("solo@example.com", among: groups),
            "the only row with this email — nothing to disambiguate")
    }

    // MARK: - automatic adoption (owner 2026-08-11). Detection was always
    // automatic; ADOPTION was not, so the corridor could list a user's
    // accounts and leave with none of them registered.

    func testDirsToAdoptSkipsAlreadyRegisteredAndNeverActsWhileDetecting() {
        let fresh = DetectedDir(configDir: "/Users/x/.claude", email: "a@example.dev", registered: false)
        let already = DetectedDir(configDir: "/Users/x/.claude-work", email: "b@example.dev", registered: true)

        XCTAssertEqual(OnboardingAccountsCopy.dirsToAdopt([fresh, already]), ["/Users/x/.claude"])
        XCTAssertEqual(
            OnboardingAccountsCopy.dirsToAdopt(nil), [],
            "detection has not answered — adopting anything here would act on no evidence")
        XCTAssertEqual(OnboardingAccountsCopy.dirsToAdopt([]), [])
        XCTAssertEqual(
            OnboardingAccountsCopy.dirsToAdopt([already]), [],
            "re-entry must not re-adopt what is already registered")
    }

    // MARK: - the phantom-sign-in filter (audit 2026-08-11). A folder whose
    // credential is gone keeps its oauthAccount block forever — the web
    // filtered these at fetch time (FirstRun.tsx:104 `signed_in !== false`)
    // and the native port had lost that filter, so dead folders were listed
    // as "We found N accounts." and auto-adopted into an engine refusal.

    func testCorridorCandidatesDropSignedOutDirsAndOnlyThose() {
        let live = DetectedDir(configDir: "/Users/x/.claude", email: "a@example.dev", registered: false, signedIn: true)
        let phantom = DetectedDir(configDir: "/Users/x/.claude-old", email: "b@example.dev", registered: false, signedIn: false)
        // signed_in ABSENT means doubt, and doubt must never hide a real
        // account (the same rule /v1/detect itself follows).
        let unknown = DetectedDir(configDir: "/Users/x/.claude-alt", email: "c@example.dev", registered: false, signedIn: nil)
        // A registered dir STAYS listed — automatic adoption registers rows
        // while the screen is up, and filtering on `registered` would make
        // them vanish mid-screen.
        let adopted = DetectedDir(configDir: "/Users/x/.claude-work", email: "d@example.dev", registered: true, signedIn: true)

        XCTAssertEqual(
            OnboardingAccountsCopy.corridorCandidates([live, phantom, unknown, adopted]),
            [live, unknown, adopted])
        XCTAssertNil(
            OnboardingAccountsCopy.corridorCandidates(nil),
            "nil is 'still detecting', not 'nothing found' — the filter must preserve that distinction")
    }

    func testDirsToAdoptNeverAdoptsASignedOutDir() {
        let phantom = DetectedDir(configDir: "/Users/x/.claude-old", email: "b@example.dev", registered: false, signedIn: false)
        let live = DetectedDir(configDir: "/Users/x/.claude", email: "a@example.dev", registered: false, signedIn: true)
        XCTAssertEqual(
            OnboardingAccountsCopy.dirsToAdopt([phantom, live]), ["/Users/x/.claude"],
            "adopting a credential-less dir can only produce the raw engine refusal")
        XCTAssertEqual(OnboardingAccountsCopy.dirsToAdopt([phantom]), [])
    }

    // MARK: - F1 (audit 2026-08-16): signedOutCandidates — the complement of
    // corridorCandidates. A CONFIRMED signed-out dir (signed_in == false)
    // must be acknowledged on screen even though it is never counted or
    // adopted; a dir where signed-in status is merely unknown (nil) must
    // NOT be classified as signed out — doubt must never manufacture a
    // false "signed out" row, same rule corridorCandidates itself follows.

    func testSignedOutCandidatesOnlyClassifiesConfirmedSignOutsAsSignedOut() {
        let live = DetectedDir(configDir: "/Users/x/.claude", email: "a@example.dev", registered: false, signedIn: true)
        let phantom = DetectedDir(configDir: "/Users/x/.claude-alt", email: "b@example.dev", registered: false, signedIn: false)
        let unknown = DetectedDir(configDir: "/Users/x/.claude-unk", email: "c@example.dev", registered: false, signedIn: nil)
        let adopted = DetectedDir(configDir: "/Users/x/.claude-work", email: "d@example.dev", registered: true, signedIn: true)

        XCTAssertEqual(
            OnboardingAccountsCopy.signedOutCandidates([live, phantom, unknown, adopted]), [phantom],
            "only a CONFIRMED signed-out dir is acknowledged — doubt (nil) and live dirs are not")
        XCTAssertEqual(
            OnboardingAccountsCopy.signedOutCandidates(nil), [],
            "still detecting — nothing to acknowledge yet")
        XCTAssertEqual(OnboardingAccountsCopy.signedOutCandidates([]), [])
    }

    func testSignedOutCandidatesAndCorridorCandidatesPartitionDetectedWithNoOverlap() {
        // The two lists together must account for every LIVE and every
        // CONFIRMED-dead dir exactly once — this is what "acknowledged, not
        // auto-adopted, not double-counted" means in code.
        let live = DetectedDir(configDir: "/Users/x/.claude", email: "a@example.dev", registered: false, signedIn: true)
        let phantom = DetectedDir(configDir: "/Users/x/.claude-alt", email: "b@example.dev", registered: false, signedIn: false)
        let dirs = [live, phantom]
        let shown = Set((OnboardingAccountsCopy.corridorCandidates(dirs) ?? []).map(\.configDir))
        let signedOut = Set(OnboardingAccountsCopy.signedOutCandidates(dirs).map(\.configDir))
        XCTAssertTrue(shown.isDisjoint(with: signedOut), "no dir is both a live candidate and an acknowledged signed-out row")
        XCTAssertEqual(shown.union(signedOut), Set(dirs.map(\.configDir)))
    }

    // MARK: - the adopt-failure line (audit 2026-08-11): what happened,
    // then the remedy — never the engine's raw Keychain-service message.

    func testAdoptFailureLineCountsAndNamesTheRemedy() {
        XCTAssertEqual(
            OnboardingAccountsCopy.adoptFailureLine(1),
            "1 account could not be added — open Add account to finish setting it up.")
        XCTAssertEqual(
            OnboardingAccountsCopy.adoptFailureLine(3),
            "3 accounts could not be added — open Add account to finish setting them up.")
    }

    // MARK: - OnboardingAccountsCopy.continueLabel — FirstRun.tsx:78

    func testContinueLabelFollowsWhetherATourFollows() {
        XCTAssertEqual(OnboardingAccountsCopy.continueLabel(tour: true), "Continue")
        XCTAssertEqual(OnboardingAccountsCopy.continueLabel(tour: false), "Open the cockpit")
    }

    // MARK: - ③-empty content (owner 2026-08-13). Three standing rules are
    // load-bearing here, so each gets its fail case pinned: the no-CLI rule
    // (owner 2026-08-12 — the block REPLACED a deleted Terminal hint and
    // must never regrow one), the honesty bound on the trust line (the
    // licensing worker, Sparkle, and checkout are real network surfaces, so
    // "nothing leaves this Mac" would be a false claim), and ④/⑤'s
    // example-disclosure discipline for fabricated numbers.

    func testEmptyStateCopyNeverMentionsTheCLI() {
        for line in OnboardingAccountsCopy.emptySteps + [OnboardingAccountsCopy.emptyTrustLine] {
            let lower = line.lowercased()
            XCTAssertFalse(lower.contains("terminal"), "no-CLI rule: \(line)")
            XCTAssertFalse(lower.contains("cli"), "no-CLI rule: \(line)")
            // "llmpilot" as a sentence SUBJECT is the product's name and
            // fine; "run llmpilot …" is a command and banned.
            XCTAssertFalse(lower.contains("run llmpilot"), "no command strings in corridor copy: \(line)")
        }
    }

    func testEmptyStateTrustLineStatesTheKeychainFactWithoutOverclaiming() {
        let line = OnboardingAccountsCopy.emptyTrustLine
        XCTAssertTrue(line.contains("Keychain"), "the trust fact is the point: \(line)")
        XCTAssertTrue(line.contains("No telemetry"), "the second true fact: \(line)")
        XCTAssertFalse(
            line.lowercased().contains("nothing leaves"),
            "overclaim — llmpilot has real network surfaces beyond Anthropic: \(line)")
        XCTAssertFalse(
            line.lowercased().contains("talks only to"),
            "overclaim — licensing/updates/checkout are not Anthropic: \(line)")
    }

    func testEmptyStateExampleIsDisclosedAsOne() {
        XCTAssertTrue(
            OnboardingAccountsCopy.emptyExampleNote.hasPrefix("Example"),
            "fabricated numbers never render undisclosed (audit 2026-08-11)")
        XCTAssertTrue(
            OnboardingAccountsCopy.emptyExampleEmail.hasSuffix("@example.dev"),
            "the example identity must be unmistakably fake, never a real-looking address")
        XCTAssertEqual(OnboardingAccountsCopy.emptySteps.count, 3)
    }

    // MARK: - hosting: mounting every phase never crashes

    private func mount<V: View>(_ view: V) {
        let window = AXTestSupport.host(view)
        defer { window.orderOut(nil) }
        XCTAssertNotNil(window.contentView)
    }

    private var emptyState: DaemonState {
        DaemonState(accounts: [], activeID: nil, schedules: [], asOf: Date())
    }

    func testMountsEveryEducationPlaceholderWithoutCrashing() {
        let m = OnboardingModel(tour: true, startedEmpty: false)
        for _ in 0..<4 {
            mount(OnboardingFlowView(model: m, accounts: [], detected: nil, state: emptyState, ask: nil))
            m.advance()
        }
    }

    func testMountsAccountsStepInEveryDetectionState() {
        let m = OnboardingModel(tour: true, startedEmpty: true)
        // detected still loading (nil).
        mount(OnboardingFlowView(model: m, accounts: [], detected: nil, state: emptyState, ask: nil))
        // zero detected.
        mount(OnboardingFlowView(model: m, accounts: [], detected: [], state: emptyState, ask: nil))
        // one group, not yet in the fleet.
        let dirs = [DetectedDir(configDir: "/Users/x/.claude", email: "a@example.dev", registered: false)]
        mount(OnboardingFlowView(model: m, accounts: [], detected: dirs, state: emptyState, ask: nil))
        // same identity now present in the fleet (percent renders).
        let account = AccountState(
            id: "a1", label: "a", email: "a@example.dev", pinned: false, snapshot: nil, tokenNote: nil, stale: nil,
            configDir: "/Users/x/.claude")
        mount(OnboardingFlowView(model: m, accounts: [account], detected: dirs, state: emptyState, ask: nil))
    }

    // MARK: - F2 (audit 2026-08-16): the row's live lane (`RunwayBar` per
    // bucket, reused from the popover) mounts for both an account whose
    // snapshot has landed and one that is still being added.

    func testMountsAccountsStepWithALiveSnapshotRenderingTheRunwayLane() {
        let m = OnboardingModel(tour: true, startedEmpty: true)
        let dirs = [DetectedDir(configDir: "/Users/x/.claude", email: "a@example.dev", registered: true, signedIn: true)]
        // Same shape as the audit's reference lane: 5h + wk + a scoped
        // bucket, all with a reset time.
        let account = Fixtures.account(
            id: "a1", label: "a", email: "a@example.dev",
            buckets: [
                Fixtures.bucket(kind: "session", percent: 2, resetsAt: Date().addingTimeInterval(3600)),
                Fixtures.bucket(kind: "weekly_all", percent: 63, resetsAt: Date().addingTimeInterval(86400)),
                Fixtures.bucket(kind: "weekly_scoped", scope: "Fable", percent: 92, resetsAt: Date().addingTimeInterval(86400)),
            ])
        mount(OnboardingFlowView(model: m, accounts: [account], detected: dirs, state: emptyState, ask: nil))
    }

    func testMountsAccountsStepWithNoSnapshotYetShowingThePlaceholderNotAFleetRow() {
        // The identity is registered but the daemon hasn't reported a
        // snapshot yet — "Adding…" must render instead of a blank row, and
        // must not crash reaching into an empty bucket list.
        let m = OnboardingModel(tour: true, startedEmpty: true)
        let dirs = [DetectedDir(configDir: "/Users/x/.claude", email: "a@example.dev", registered: true, signedIn: true)]
        let account = AccountState(
            id: "a1", label: "a", email: "a@example.dev", pinned: false, snapshot: nil, tokenNote: nil, stale: nil,
            configDir: "/Users/x/.claude")
        mount(OnboardingFlowView(model: m, accounts: [account], detected: dirs, state: emptyState, ask: nil))
    }

    // MARK: - F1 (audit 2026-08-16): a confirmed signed-out sibling folder
    // renders as an acknowledged, dimmed row alongside a normal account —
    // never counted, never adopted, but never silently dropped either.

    func testMountsAccountsStepWithASignedOutSiblingAlongsideALiveAccount() {
        let m = OnboardingModel(tour: true, startedEmpty: true)
        let dirs = [
            DetectedDir(configDir: "/Users/x/.claude", email: "a@outlook.com", registered: true, signedIn: true),
            DetectedDir(configDir: "/Users/x/.claude-alt", email: "a@gmail.com", registered: false, signedIn: false),
        ]
        let account = Fixtures.account(id: "a1", label: "a", email: "a@outlook.com",
                                        buckets: [Fixtures.bucket(kind: "session", percent: 2)])
        mount(OnboardingFlowView(model: m, accounts: [account], detected: dirs, state: emptyState, ask: nil))
    }

    func testMountsAccountsStepWithOnlySignedOutDirsAndZeroLiveGroups() {
        // The zero-groups branch (OnboardingEmptyAccountsView) plus the
        // signed-out acknowledgment must coexist without crashing.
        let m = OnboardingModel(tour: true, startedEmpty: true)
        let dirs = [DetectedDir(configDir: "/Users/x/.claude-alt", email: "a@gmail.com", registered: false, signedIn: false)]
        mount(OnboardingFlowView(model: m, accounts: [], detected: dirs, state: emptyState, ask: nil))
    }

    func testMountsAskPhaseWithAndWithoutAnAskMachine() {
        let m = OnboardingModel(tour: true, startedEmpty: false)
        for _ in 0..<4 { m.advance() }
        XCTAssertEqual(m.phase, .ask)
        // No ask yet — the fallback placeholder.
        mount(OnboardingFlowView(model: m, accounts: [], detected: nil, state: emptyState, ask: nil))
        // Ask resolved.
        let license = try! DaemonDates.decoder().decode(
            LicenseInfo.self,
            from: Data(#"{"available":true,"active":false,"status":"none","nocard_trial_used":false}"#.utf8))
        let ask = AskMachine(license: license, quote: nil, guided: true, locale: "en-GB", winback: freshWinback(), api: StubCockpitAPI(), onDismiss: {})
        mount(OnboardingFlowView(model: m, accounts: [], detected: nil, state: emptyState, ask: ask))
    }

    // MARK: - Phase 4 chunk 4E: the real education/switch screens mount
    // (these used to render `EducationSlotPlaceholder`; this chunk wires
    // WallScreen/BlindSpotScreen/WindowsScreen/OnboardingSwitchStepView in).

    func testMountsEveryRealEducationScreenAgainstAnEmptyFleetWithoutCrashing() {
        let m = OnboardingModel(tour: true, startedEmpty: false)
        // wall, blind, switch (masked — no genuine two-account fleet), windows.
        for _ in 0..<4 {
            mount(OnboardingFlowView(model: m, accounts: [], detected: nil, state: emptyState, ask: nil))
            m.advance()
        }
    }

    func testMountsTheSwitchStepAgainstATwoAccountFleetWithoutCrashing() {
        // Real (unmasked) lanes this time — eduDemoLanes(state) resolves
        // instead of falling back to eduMaskedLanes.
        let m = OnboardingModel(tour: true, startedEmpty: false)
        m.advance() // wall
        m.advance() // blind
        XCTAssertEqual(m.phase, .switchDemo)
        mount(OnboardingFlowView(model: m, accounts: Fixtures.twoAccounts().accounts, detected: nil,
                                  state: Fixtures.twoAccounts(), ask: nil))
    }

    func testMountsTheAskFallbackSwitchStepWithoutCrashing() {
        // Onboarding.tsx:210-218's fallback renders the SAME switch section
        // as the real ④ phase, reached here via `.ask` with no AskMachine.
        let m = OnboardingModel(tour: false, startedEmpty: false)
        XCTAssertEqual(m.phase, .ask)
        mount(OnboardingFlowView(model: m, accounts: [], detected: nil, state: emptyState, ask: nil))
    }
}
