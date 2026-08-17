import XCTest
@testable import llmpilot

/// Phase 4 chunk 4E (integration) — defect-class tests for the composition-
/// root decision logic NativeCockpitWindow.swift drives
/// (ProFlowCoordinator.swift): the first-run/paywall mount decision
/// (App.tsx:268-279), the corridor `guided` flag mapping, and the
/// post-checkout reload sequence. Hermetic: StubCockpitAPI only, no window,
/// no daemon.
@MainActor
final class ProFlowCoordinatorTests: XCTestCase {
    /// A quote whose discount is genuinely lower — the shape the win-back
    /// rung's arming gate requires.
    private let winbackableQuote = LadderQuote(
        trialDays: 4, chargeDate: Date(timeIntervalSince1970: 1_784_707_200),
        pricesFull: ["gbp": 999], pricesDiscount: ["gbp": 599])

    private func license(status: String, active: Bool = false, available: Bool = true) -> LicenseInfo {
        try! DaemonDates.decoder().decode(
            LicenseInfo.self,
            from: Data(
                #"{"available":\#(available),"active":\#(active),"status":"\#(status)","nocard_trial_used":false}"#
                    .utf8))
    }

    // MARK: - ProFlowLogic.firstRun — App.tsx:268

    func testFirstRunIsExactlyAnEmptyFleet() {
        XCTAssertTrue(ProFlowLogic.firstRun(accounts: []))
        XCTAssertFalse(ProFlowLogic.firstRun(accounts: [
            AccountState(id: "a", label: "a", email: "a@example.dev", pinned: false,
                         snapshot: nil, tokenNote: nil, stale: nil, configDir: "/x"),
        ]))
    }

    // MARK: - ProFlowLogic.showOnboarding — App.tsx:273-275

    func testShowOnboardingRequiresAvailableUnlicensedStatusNoneNotDismissed() {
        XCTAssertTrue(ProFlowLogic.showOnboarding(license: license(status: "none"), onboarded: false))
        // Already dismissed this Mac.
        XCTAssertFalse(ProFlowLogic.showOnboarding(license: license(status: "none"), onboarded: true))
        // Active — never re-pitched.
        XCTAssertFalse(ProFlowLogic.showOnboarding(license: license(status: "trialing", active: true), onboarded: false))
        // Lapsed/revoked are the honest-paused banner's job, not first run.
        XCTAssertFalse(ProFlowLogic.showOnboarding(license: license(status: "lapsed"), onboarded: false))
        // Source build (unavailable) never sees the pitch.
        XCTAssertFalse(ProFlowLogic.showOnboarding(license: license(status: "none", available: false), onboarded: false))
        // No license resolved yet.
        XCTAssertFalse(ProFlowLogic.showOnboarding(license: nil, onboarded: false))
    }

    // MARK: - ProFlowLogic.wantFlow / showFlow — App.tsx:278-279

    func testWantFlowIsFirstRunUnclosedOrShowOnboarding() {
        // First run, never closed.
        XCTAssertTrue(ProFlowLogic.wantFlow(firstRun: true, flowClosed: false, showOnboarding: false))
        // First run, but the accounts-only flow was explicitly closed.
        XCTAssertFalse(ProFlowLogic.wantFlow(firstRun: true, flowClosed: true, showOnboarding: false))
        // Fleet non-empty, but the pro pitch is due — flowClosed is
        // irrelevant to that path.
        XCTAssertTrue(ProFlowLogic.wantFlow(firstRun: false, flowClosed: true, showOnboarding: true))
        // Neither condition.
        XCTAssertFalse(ProFlowLogic.wantFlow(firstRun: false, flowClosed: true, showOnboarding: false))
    }

    func testShowFlowHoldsOnTheLatchOnceWantFlowDrops() {
        // wantFlow dropped (activation flipped showOnboarding false) but the
        // latch still holds — the activation-facts screen must not vanish
        // mid-story.
        XCTAssertTrue(ProFlowLogic.showFlow(wantFlow: false, flowLatched: true))
        XCTAssertFalse(ProFlowLogic.showFlow(wantFlow: false, flowLatched: false))
        XCTAssertTrue(ProFlowLogic.showFlow(wantFlow: true, flowLatched: false))
    }

    // MARK: - ProFlowLogic.guided — the corridor ✕ flag

    func testGuidedCorridorFlagMapsFirstRunTrueReopenFalse() {
        XCTAssertTrue(ProFlowLogic.guided(for: .firstRunFlow))
        XCTAssertFalse(ProFlowLogic.guided(for: .reopenedPaywall))
    }

    // MARK: - ProQuoteModel — useQuote.ts's fetch/validate/retry contract

    func testQuoteModelLoadsAndValidatesAWellFormedQuote() async {
        let api = StubCockpitAPI()
        api.licenseQuoteResult = .success(try! DaemonDates.decoder().decode(
            LicenseQuote.self,
            from: Data(
                #"{"trial_days":4,"charge_date":"2026-08-20T00:00:00Z","prices":{"full":{"gbp":999},"discount":{"gbp":599}}}"#
                    .utf8)))
        let model = ProQuoteModel(api: api)
        model.loadIfNeeded()
        for _ in 0..<50 where model.quote == nil && !model.failed {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(model.quote?.trialDays, 4)
        XCTAssertFalse(model.failed)
    }

    func testQuoteModelFailsOnMalformedTermsNeverInventingAPrice() async {
        // No prices at all — api.ts's fetchQuote throws for exactly this;
        // LadderQuote.validated returns nil, which must surface as `failed`,
        // never a quote with an invented price.
        let api = StubCockpitAPI()
        api.licenseQuoteResult = .success(try! DaemonDates.decoder().decode(
            LicenseQuote.self, from: Data(#"{"trial_days":4,"charge_date":"2026-08-20T00:00:00Z"}"#.utf8)))
        let model = ProQuoteModel(api: api)
        model.loadIfNeeded()
        for _ in 0..<50 where model.quote == nil && !model.failed {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNil(model.quote)
        XCTAssertTrue(model.failed)
    }

    func testQuoteModelLoadIfNeededIsANoOpOnceSettled() async {
        let api = StubCockpitAPI()
        api.licenseQuoteResult = .failure(DaemonError.down)
        let model = ProQuoteModel(api: api)
        model.loadIfNeeded()
        for _ in 0..<50 where !model.failed { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(model.failed)
        // A second loadIfNeeded must not refetch — only an explicit reload() does.
        model.loadIfNeeded()
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(model.failed) // still true, no crash/race either way
    }

    // MARK: - PostCheckoutReload — the native-only post-checkout-sheet reload

    func testPostCheckoutReloadProductionWindowSpansTheActivationPoll() {
        // The F1 (P0) fix IS these constants: every behavior test passes
        // fast overrides, so this is the one gate on the production
        // timing. >= 9s spans three ticks of the daemon's 3s activation
        // poll (license.go pollEvery) — below that, a buyer who just paid
        // through the embedded sheet is called an abandoner again.
        XCTAssertGreaterThanOrEqual(
            Double(PostCheckoutReload.defaultRereads) * PostCheckoutReload.defaultRereadDelay, 9)
    }

    func testPostCheckoutReloadPullsLicenseStateAndQuoteThenRoutesAnActivatedAsk() async {
        let api = StubCockpitAPI()
        api.licenseResult = .success(license(status: "trialing", active: true))
        api.stateResult = .success(Fixtures.twoAccounts())
        api.licenseQuoteResult = .success(try! DaemonDates.decoder().decode(
            LicenseQuote.self,
            from: Data(
                #"{"trial_days":4,"charge_date":"2026-08-20T00:00:00Z","prices":{"full":{"gbp":999},"discount":{"gbp":599}}}"#
                    .utf8)))
        let fleet = FleetViewModel(api: api, autostart: false)
        let quote = ProQuoteModel(api: api)
        let winback = freshWinback()
        let ask = AskMachine(
            license: license(status: "none"), quote: nil, guided: true, locale: "en-GB",
            winback: winback, api: api, onDismiss: {})
        XCTAssertNotEqual(ask.screen, .active)

        await PostCheckoutReload.run(api: api, fleet: fleet, quote: quote, ask: ask)

        // license → state → quote, in that order, each hit exactly once.
        XCTAssertEqual(api.licenseRevealRequests, [false])
        XCTAssertNotNil(fleet.state)
        XCTAssertEqual(fleet.state?.accounts.count, 2)
        for _ in 0..<50 where quote.quote == nil { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(quote.quote?.trialDays, 4)
        // The still-open ask machine is routed to "Pro is on" — and the
        // activation ends the win-back ladder permanently.
        XCTAssertEqual(ask.screen, .active)
        XCTAssertEqual(winback.state, .spent)
    }

    func testPostCheckoutReloadLeavesAnUnactivatedAskUnrouted() async {
        // The buyer closed the sheet without completing payment — the
        // reload must not force the ask onto a screen it never earned, and
        // the still-inactive reload IS the abandoned-checkout
        // trigger: it arms the win-back rung.
        let api = StubCockpitAPI()
        api.licenseResult = .success(license(status: "none", active: false))
        api.stateResult = .success(Fixtures.twoAccounts())
        let fleet = FleetViewModel(api: api, autostart: false)
        let quote = ProQuoteModel(api: api)
        let winback = freshWinback()
        let ask = AskMachine(
            license: license(status: "none"), quote: winbackableQuote, guided: true, locale: "en-GB",
            winback: winback, api: api, onDismiss: {})

        await PostCheckoutReload.run(api: api, fleet: fleet, quote: quote, ask: ask, rereads: 2, rereadDelay: 0)

        XCTAssertNotEqual(ask.screen, .active)
        XCTAssertEqual(winback.state, .armed, "an abandoned checkout is the win-back's second trigger")
        // The decision waited out the re-read window: 1 initial + 2 re-reads.
        XCTAssertEqual(api.licenseRevealRequests.count, 3)
    }

    func testPostCheckoutReloadWaitsOutTheActivationPollBeforeCallingItAbandoned() async {
        // Adversarial review F1 (P0): production checkout completes INSIDE
        // the sheet (embedded, no /pro/activated navigation), so a buyer
        // who just PAID leaves through the same Cancel an abandoner uses —
        // and GET /v1/license lags behind the daemon's ~3s activation
        // poll. A first read of "inactive" must NOT arm the win-back; a
        // re-read that turns active routes to "Pro is on" and spends the
        // ladder instead.
        let api = StubCockpitAPI()
        api.licenseResultQueue = [
            .success(license(status: "none", active: false)),
            .success(license(status: "trialing", active: true)),
        ]
        api.licenseResult = .success(license(status: "trialing", active: true))
        api.stateResult = .success(Fixtures.twoAccounts())
        let fleet = FleetViewModel(api: api, autostart: false)
        let quote = ProQuoteModel(api: api)
        let winback = freshWinback()
        let ask = AskMachine(
            license: license(status: "none"), quote: winbackableQuote, guided: true, locale: "en-GB",
            winback: winback, api: api, onDismiss: {})

        await PostCheckoutReload.run(api: api, fleet: fleet, quote: quote, ask: ask, rereads: 4, rereadDelay: 0)

        XCTAssertEqual(ask.screen, .active, "activation landing mid-window must route the ask, not arm the rung")
        XCTAssertEqual(winback.state, .spent)
        // Exited the window early, on the activating re-read.
        XCTAssertEqual(api.licenseRevealRequests.count, 2)
    }

    func testPostCheckoutReloadDiscardsAStaleInactiveReadWhenRereadsFail() async {
        // Found in review: a successful inactive FIRST read followed
        // by failing re-reads must not decide "abandoned" — the deciding
        // read is the final one, and a failed final read proves nothing.
        let api = StubCockpitAPI()
        api.licenseResultQueue = [.success(license(status: "none", active: false))]
        api.licenseResult = .failure(DaemonError.down)
        api.stateResult = .success(Fixtures.twoAccounts())
        let fleet = FleetViewModel(api: api, autostart: false)
        let quote = ProQuoteModel(api: api)
        let winback = freshWinback()
        let ask = AskMachine(
            license: license(status: "none"), quote: winbackableQuote, guided: true, locale: "en-GB",
            winback: winback, api: api, onDismiss: {})

        await PostCheckoutReload.run(api: api, fleet: fleet, quote: quote, ask: ask, rereads: 2, rereadDelay: 0)

        XCTAssertEqual(winback.state, .intact, "stale evidence must not arm the rung")
    }

    func testPostCheckoutReloadFailedLicenseReadTriggersNothing() async {
        // Fail case: a reload that cannot READ the license proves
        // neither activation nor abandonment — the ladder must not arm on
        // the absence of evidence.
        let api = StubCockpitAPI()
        api.licenseResult = .failure(DaemonError.down)
        api.stateResult = .success(Fixtures.twoAccounts())
        let fleet = FleetViewModel(api: api, autostart: false)
        let quote = ProQuoteModel(api: api)
        let winback = freshWinback()
        let ask = AskMachine(
            license: license(status: "none"), quote: nil, guided: true, locale: "en-GB",
            winback: winback, api: api, onDismiss: {})

        await PostCheckoutReload.run(api: api, fleet: fleet, quote: quote, ask: ask, rereads: 2, rereadDelay: 0)

        XCTAssertEqual(winback.state, .intact)
    }

    func testPostCheckoutReloadToleratesANilAskMachine() async {
        // The reopened paywall may have already been dismissed by the time
        // the sheet closes — the reload must still pull license/state/quote
        // without crashing on a nil ask.
        let api = StubCockpitAPI()
        api.licenseResult = .success(license(status: "none"))
        api.stateResult = .success(Fixtures.twoAccounts())
        let fleet = FleetViewModel(api: api, autostart: false)
        let quote = ProQuoteModel(api: api)

        await PostCheckoutReload.run(api: api, fleet: fleet, quote: quote, ask: nil, rereads: 0)

        XCTAssertEqual(api.licenseRevealRequests, [false])
        XCTAssertNotNil(fleet.state)
    }

    // MARK: - live ask stats (review 2026-08-08 P1-4; App.tsx:289,544,577 +
    // Onboarding.tsx:204-205 recompute these per render)

    func testCaughtThisWeekCountsOnlyRecentSwitchAndRotateEvents() {
        let now = Date(timeIntervalSince1970: 1_784_707_200)
        let events = [
            DaemonEvent(at: now.addingTimeInterval(-3600), kind: "switch", accountID: "a", message: "", late: nil),
            DaemonEvent(at: now.addingTimeInterval(-6 * 86_400), kind: "rotate", accountID: "a", message: "", late: nil),
            // Too old — outside the 7-day window.
            DaemonEvent(at: now.addingTimeInterval(-8 * 86_400), kind: "switch", accountID: "a", message: "", late: nil),
            // Wrong kind.
            DaemonEvent(at: now.addingTimeInterval(-3600), kind: "schedule", accountID: "a", message: "", late: nil),
        ]
        XCTAssertEqual(ProFlowLogic.caughtThisWeek(events: events, now: now), 2)
    }

    func testAskStatsMirrorTheWebsPerRenderProps() {
        let now = Date(timeIntervalSince1970: 1_784_707_200)
        var state = Fixtures.twoAccounts(now: now)
        state.events = [
            DaemonEvent(at: now.addingTimeInterval(-60), kind: "switch", accountID: "acct-a", message: "", late: nil)
        ]
        let stats = ProFlowLogic.askStats(state: state, now: now)
        XCTAssertEqual(stats.watched, 2)
        XCTAssertEqual(stats.switchable, 2) // neither fixture account is pinned
        XCTAssertEqual(stats.caught, 1)

        // App.tsx:544 `caughtThisWeek || undefined` — zero reads as absent.
        state.events = []
        XCTAssertNil(ProFlowLogic.askStats(state: state, now: now).caught)

        // No state at all (pre-connect) — zeros, no crash.
        let empty = ProFlowLogic.askStats(state: nil, now: now)
        XCTAssertEqual(empty.watched, 0)
        XCTAssertNil(empty.caught)
    }

    // MARK: - ⑨ watch-only promote (owner 2026-08-12, layer 1)

    private func account(
        _ id: String, email: String = "", pinned: Bool, dir: String
    ) -> AccountState {
        AccountState(
            id: id, label: id, email: email, pinned: pinned, snapshot: nil, tokenNote: nil,
            stale: nil, configDir: dir)
    }

    func testWatchOnlyLanesListPinnedAccountsAndExcludeConfirmedSignedOut() {
        let accounts = [
            account("main", email: "main@x.dev", pinned: false, dir: "/u/.claude"),
            account("work", email: "work@x.dev", pinned: true, dir: "/u/.claude-work"),
            account("dead", email: "dead@x.dev", pinned: true, dir: "/u/.claude-dead"),
            account("odd", email: "odd@x.dev", pinned: true, dir: ""),
        ]
        let detected = [
            DetectedDir(configDir: "/u/.claude-work", email: "work@x.dev", registered: true, signedIn: true),
            // CONFIRMED signed out — offering the move could only refuse.
            DetectedDir(configDir: "/u/.claude-dead", email: "dead@x.dev", registered: true, signedIn: false),
        ]
        let lanes = ProFlowLogic.watchOnlyLanes(accounts: accounts, detected: detected)
        XCTAssertEqual(lanes.map(\.configDir), ["/u/.claude-work"], "unpinned, signed-out, and dir-less lanes all excluded")
        XCTAssertEqual(lanes.first?.email, "work@x.dev")
    }

    func testWatchOnlyLanesDoubtStaysListedAndLabelFallsBackWhenEmailEmpty() {
        // Absent from detect entirely (signed_in unknown) → doubt must
        // never hide a real account, same rule /v1/detect follows.
        let accounts = [account("solo", pinned: true, dir: "/u/.claude-solo")]
        let lanes = ProFlowLogic.watchOnlyLanes(accounts: accounts, detected: [])
        XCTAssertEqual(lanes.map(\.configDir), ["/u/.claude-solo"])
        XCTAssertEqual(lanes.first?.email, "solo", "the label stands in for a missing email")
    }

    @MainActor
    func testActivationMoveTakesTwoClicksAndTheDisarmFailCaseHolds() async {
        let api = StubCockpitAPI()
        let model = ActivationMoveModel(api: api)
        var moved = 0
        model.onMoved = { moved += 1 }

        // Click one arms; nothing moves.
        model.requestMove("/u/.claude-work")
        XCTAssertEqual(model.confirmDir, "/u/.claude-work")
        XCTAssertEqual(moved, 0)

        // The disarm (timeout's own path, called directly per precedent)
        // makes the NEXT click a fresh first click — never a surprise move.
        model.resetConfirm(for: "/u/.claude-work")
        XCTAssertNil(model.confirmDir)
        model.requestMove("/u/.claude-work")
        XCTAssertEqual(model.confirmDir, "/u/.claude-work")
        XCTAssertEqual(moved, 0, "a disarmed confirm must not carry over")
    }

    @MainActor
    func testActivationMoveSuccessReportsTheDaemonsNoteAndRefreshes() async throws {
        let api = StubCockpitAPI()
        api.adoptMoveResult = .success(try DaemonDates.decoder().decode(
            AdoptMoveResult.self,
            from: Data(#"{"account":{"id":"w","label":"w","email":"w@x.dev","pinned":false,"config_dir":"/u/.claude-work","keychain_service":"svc-w"},"outcome":"clone_suspect","note":"A second copy may still exist."}"#.utf8)))
        let model = ActivationMoveModel(api: api)
        var moved = 0
        model.onMoved = { moved += 1 }

        model.requestMove("/u/.claude-work")
        model.requestMove("/u/.claude-work")
        for _ in 0..<50 where model.busyDir != nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(moved, 1)
        XCTAssertEqual(model.notes["/u/.claude-work"], "A second copy may still exist.")
        XCTAssertNil(model.busyDir)
    }

    @MainActor
    func testActivationMoveFailureKeepsARemedyNoteAndNeverRefreshes() async {
        let api = StubCockpitAPI()
        api.adoptMoveResult = .failure(DaemonError.down)
        let model = ActivationMoveModel(api: api)
        var moved = 0
        model.onMoved = { moved += 1 }

        model.requestMove("/u/.claude-work")
        model.requestMove("/u/.claude-work")
        for _ in 0..<50 where model.busyDir != nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(moved, 0)
        XCTAssertNotNil(model.notes["/u/.claude-work"])
    }
}
