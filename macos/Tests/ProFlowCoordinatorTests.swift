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

    private func license(
        status: String, active: Bool = false, available: Bool = true, outcome: String? = nil
    ) -> LicenseInfo {
        let outcomeField = outcome.map { #","checkout_outcome":"\#($0)""# } ?? ""
        return try! DaemonDates.decoder().decode(
            LicenseInfo.self,
            from: Data(
                #"{"available":\#(available),"active":\#(active),"status":"\#(status)","nocard_trial_used":false\#(outcomeField)}"#
                    .utf8))
    }

    /// A price-screen ask that has pressed checkout once (a real hosted
    /// handoff): returns the machine and the identity the composition root
    /// captured at present time — what its `CheckoutDecider.watch` carries.
    /// `browser` true reports the NSWorkspace launch landed (the 1.3.4
    /// default flow); false leaves the fallback-sheet shape, where the
    /// caller may `checkoutSheetClosed()` to model the close. The stub's
    /// pre-flight license read is one `licenseRevealRequests` entry the
    /// caller counts.
    private func handedOffCheckout(
        winback: WinbackModel, api: StubCockpitAPI, quote: LadderQuote? = nil,
        url: String = "https://checkout.stripe.com/c/pay/x", browser: Bool = true,
        onDismiss: @escaping () -> Void = {}
    ) async -> (ask: AskMachine, presented: CheckoutIdentity) {
        let ask = AskMachine(
            license: license(status: "none"), quote: quote ?? winbackableQuote, guided: true, locale: "en-GB",
            winback: winback, api: api, onDismiss: onDismiss)
        ask.askReminder()
        ask.remindDays = 2
        ask.remindContinue()
        api.licenseCheckoutResult = .success(
            try! DaemonDates.decoder().decode(
                CheckoutHandoff.self, from: Data(#"{"url":"\#(url)","session_id":"sess_x"}"#.utf8)))
        await ask.pressCheckout()
        XCTAssertEqual(ask.handoffURL, url)
        let presented = ask.liveCheckout!
        if browser { ask.browserDidOpen(for: presented) }
        return (ask, presented)
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

    // MARK: - CheckoutDecider — the browser-handoff decider (1.3.4, retiring
    // PostCheckoutReload's sheet-close reread heuristic)

    func testDeciderTimingRidesTheDaemonsOwnVerdictWindow() {
        // The daemon DELIVERS a verdict by its 10-minute activation-poll
        // deadline (license.go pollFor lapsing is the "abandoned" signal) —
        // a watch ceiling below that would end before the silent-abandon
        // verdict exists to read. The poll cadence rides the daemon's 3s
        // worker poll the way the retired 2.5s rereads did.
        XCTAssertGreaterThanOrEqual(CheckoutDecider.defaultDeadline, 10 * 60 + 30)
        XCTAssertLessThanOrEqual(CheckoutDecider.defaultPollDelay, 3)
    }

    func testDeciderRoutesAnActivatedAskAndRefreshesTheSurfaces() async {
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

        // Activation routes with or without a handoff identity — it is not
        // an abandon verdict.
        await CheckoutDecider.watch(
            api: api, fleet: fleet, quote: quote, ask: ask, presented: nil, pollDelay: 0)

        XCTAssertNotNil(fleet.state)
        XCTAssertEqual(fleet.state?.accounts.count, 2)
        for _ in 0..<50 where quote.quote == nil { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(quote.quote?.trialDays, 4)
        // The still-open ask machine is routed to "Pro is on" — and the
        // activation ends the win-back ladder permanently.
        XCTAssertEqual(ask.screen, .active)
        XCTAssertEqual(winback.state, .spent)
    }

    func testDeclinedOutcomeArmsInstantlyAndEndsTheBrowserHandoffLine() async {
        // The buyer clicked the hosted page's back arrow: the worker
        // recorded the cancel-token hit, the daemon's poll surfaced
        // checkout_outcome=declined, and the watch arms the win-back while
        // the buyer is still looking — no 10s heuristic, no sheet-close.
        let api = StubCockpitAPI()
        api.licenseResult = .success(license(status: "none"))
        api.stateResult = .success(Fixtures.twoAccounts())
        let fleet = FleetViewModel(api: api, autostart: false)
        let quote = ProQuoteModel(api: api)
        let winback = freshWinback()
        let (ask, presented) = await handedOffCheckout(winback: winback, api: api)
        XCTAssertTrue(ask.browserOpen)
        api.licenseResult = .success(license(status: "none", outcome: "declined"))

        await CheckoutDecider.watch(
            api: api, fleet: fleet, quote: quote, ask: ask, presented: presented, pollDelay: 0.01)

        XCTAssertEqual(winback.state, .armed)
        XCTAssertEqual(ask.offerRung, .discountTrial)
        // The verdict ended the handoff: "finish in your browser" must not
        // outlive a tab that sits on the "Nothing was charged" page.
        XCTAssertNil(ask.handoffURL)
        XCTAssertFalse(ask.browserOpen)
        XCTAssertEqual(winback.decisionsPending, 0)
    }

    func testAbandonedOutcomeArmsWhenTheDaemonsDeadlineLapses() async {
        // Tab closed in silence: no cancel hit ever comes, the daemon's
        // 10-minute poll deadline delivers "abandoned", and the watch arms
        // for the next open (owner decision 2026-08-27).
        let api = StubCockpitAPI()
        api.licenseResult = .success(license(status: "none"))
        api.stateResult = .success(Fixtures.twoAccounts())
        let fleet = FleetViewModel(api: api, autostart: false)
        let quote = ProQuoteModel(api: api)
        let winback = freshWinback()
        let (ask, presented) = await handedOffCheckout(winback: winback, api: api)
        api.licenseResult = .success(license(status: "none", outcome: "abandoned"))

        await CheckoutDecider.watch(
            api: api, fleet: fleet, quote: quote, ask: ask, presented: presented, pollDelay: 0.01)

        XCTAssertEqual(winback.state, .armed)
    }

    func testNoOutcomeByTheWatchCeilingDecidesNothing() async {
        // The ceiling exists for a daemon that restarted mid-window (its
        // poll — and with it any verdict — died with it): a watch that ends
        // there proves nothing and must not arm.
        let api = StubCockpitAPI()
        api.licenseResult = .success(license(status: "none"))
        api.stateResult = .success(Fixtures.twoAccounts())
        let fleet = FleetViewModel(api: api, autostart: false)
        let quote = ProQuoteModel(api: api)
        let winback = freshWinback()
        let (ask, presented) = await handedOffCheckout(winback: winback, api: api)

        await CheckoutDecider.watch(
            api: api, fleet: fleet, quote: quote, ask: ask, presented: presented,
            pollDelay: 0.01, deadline: 0.1)

        XCTAssertEqual(winback.state, .intact, "no verdict, no arm")
        XCTAssertEqual(winback.decisionsPending, 0)
    }

    func testDeciderNeverArmsWhenANewerCheckoutOpensInsideItsWatch() async {
        // The watch runs for up to ~11 minutes. A buyer who presses the
        // money button again INSIDE that window has a newer session live
        // when the OLD watch's verdict finally lands — the identity guards
        // discard it instead of arming behind the new checkout.
        let api = StubCockpitAPI()
        api.licenseResult = .success(license(status: "none"))
        api.stateResult = .success(Fixtures.twoAccounts())
        let fleet = FleetViewModel(api: api, autostart: false)
        let quote = ProQuoteModel(api: api)
        let winback = freshWinback()
        let (ask, presentedOne) = await handedOffCheckout(winback: winback, api: api)

        let watchOne = Task {
            await CheckoutDecider.watch(
                api: api, fleet: fleet, quote: quote, ask: ask, presented: presentedOne,
                pollDelay: 0.02, deadline: 5)
        }
        try? await Task.sleep(nanoseconds: 30_000_000)
        // Mid-watch, the buyer starts checkout #2 (its mint expires session
        // #1 server-side; here it just makes identity #1 stale)...
        await ask.pressCheckout()
        XCTAssertNotNil(ask.handoffURL, "checkout 2 is live when watch 1 decides")
        XCTAssertEqual(api.licenseCheckoutRequests.count, 2)
        // ...and only then does session #1's declined verdict surface.
        api.licenseResult = .success(license(status: "none", outcome: "declined"))
        await watchOne.value

        XCTAssertEqual(winback.state, .intact, "watch 1 must not arm behind the newer checkout")
        XCTAssertEqual(ask.offerRung, .full)
    }

    func testCloseDuringTheWatchDismissesAndLeavesTheVerdictToTheDaemon() async {
        // The ✕ once the browser owns the surface, both ways the watch can
        // end. Declined/abandoned: the ✕ dismisses without arming, and the
        // daemon's verdict arms through the watch — the offer is there on
        // the next open. Paid: the ✕ dismisses without arming, activation
        // lands mid-watch, the watch routes it and the ladder is spent —
        // the buyer who just paid £9.99 was never shown £5.99.
        let api = StubCockpitAPI()
        api.licenseResult = .success(license(status: "none"))
        api.stateResult = .success(Fixtures.twoAccounts())
        let fleet = FleetViewModel(api: api, autostart: false)
        let quote = ProQuoteModel(api: api)

        // Declined-after-dismiss.
        let winbackA = freshWinback()
        var dismissed = 0
        let (askA, presentedA) = await handedOffCheckout(
            winback: winbackA, api: api, url: "https://checkout.stripe.com/c/pay/a",
            onDismiss: { dismissed += 1 })
        let watchA = Task {
            await CheckoutDecider.watch(
                api: api, fleet: fleet, quote: quote, ask: askA, presented: presentedA,
                pollDelay: 0.02, deadline: 5)
        }
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(winbackA.decisionsPending, 1)
        XCTAssertTrue(askA.closeEnabled, "the browser owns the surface — the paywall may dismiss again")
        askA.close()
        XCTAssertEqual(dismissed, 1, "the ✕ dismisses")
        XCTAssertEqual(winbackA.state, .intact, "…without arming ahead of the daemon's verdict")
        api.licenseResult = .success(license(status: "none", outcome: "declined"))
        await watchA.value
        XCTAssertEqual(winbackA.decisionsPending, 0)
        XCTAssertEqual(winbackA.state, .armed, "the daemon's verdict arms once it lands")

        // Paid.
        let winbackP = freshWinback()
        api.licenseResult = .success(license(status: "none"))
        let (askP, presentedP) = await handedOffCheckout(
            winback: winbackP, api: api, url: "https://checkout.stripe.com/c/pay/p")
        let watchP = Task {
            await CheckoutDecider.watch(
                api: api, fleet: fleet, quote: quote, ask: askP, presented: presentedP,
                pollDelay: 0.02, deadline: 5)
        }
        try? await Task.sleep(nanoseconds: 30_000_000)
        askP.close()
        XCTAssertEqual(winbackP.state, .intact, "a buyer who just paid must never be shown the lower offer")
        api.licenseResult = .success(license(status: "trialing", active: true))
        await watchP.value
        XCTAssertEqual(askP.screen, .active)
        XCTAssertEqual(winbackP.state, .spent)
    }

    func testFailedLicenseReadsTriggerNothing() async {
        // Fail case: a watch that cannot READ the license proves neither
        // activation nor a verdict — the ladder must not arm on the absence
        // of evidence.
        let api = StubCockpitAPI()
        api.licenseResult = .failure(DaemonError.down)
        api.stateResult = .success(Fixtures.twoAccounts())
        let fleet = FleetViewModel(api: api, autostart: false)
        let quote = ProQuoteModel(api: api)
        let winback = freshWinback()
        // (The press's own pre-flight read fails too — a failed read never
        // blocks a purchase — so the handoff still lands.)
        let (ask, presented) = await handedOffCheckout(winback: winback, api: api)

        await CheckoutDecider.watch(
            api: api, fleet: fleet, quote: quote, ask: ask, presented: presented,
            pollDelay: 0.01, deadline: 0.1)

        XCTAssertEqual(winback.state, .intact)
    }

    func testWatchWithoutAHandoffIdentityNeverArms() async {
        // Fail-closed: a watch handed an ask but no identity has nothing to
        // bind a verdict to — it must never arm, while an activation still
        // routes without one.
        let api = StubCockpitAPI()
        api.licenseResult = .success(license(status: "none", outcome: "declined"))
        api.stateResult = .success(Fixtures.twoAccounts())
        let fleet = FleetViewModel(api: api, autostart: false)
        let quote = ProQuoteModel(api: api)
        let winback = freshWinback()
        let ask = AskMachine(
            license: license(status: "none"), quote: winbackableQuote, guided: true, locale: "en-GB",
            winback: winback, api: api, onDismiss: {})

        await CheckoutDecider.watch(
            api: api, fleet: fleet, quote: quote, ask: ask, presented: nil, pollDelay: 0)

        XCTAssertEqual(winback.state, .intact, "no identity, no verdict")

        api.licenseResult = .success(license(status: "trialing", active: true))
        await CheckoutDecider.watch(
            api: api, fleet: fleet, quote: quote, ask: ask, presented: nil, pollDelay: 0)
        XCTAssertEqual(ask.screen, .active)
        XCTAssertEqual(winback.state, .spent)
    }

    func testWatchToleratesANilAskMachine() async {
        // The reopened paywall may have been dismissed long before the
        // verdict lands — the watch must finish without crashing on a nil
        // ask, and an activation still refreshes the surfaces.
        let api = StubCockpitAPI()
        api.licenseResult = .success(license(status: "trialing", active: true))
        api.stateResult = .success(Fixtures.twoAccounts())
        let fleet = FleetViewModel(api: api, autostart: false)
        let quote = ProQuoteModel(api: api)

        await CheckoutDecider.watch(
            api: api, fleet: fleet, quote: quote, ask: nil, presented: nil, pollDelay: 0)

        XCTAssertNotNil(fleet.state)
    }

    func testASupersededWatchStopsPollingPromptly() async {
        // The root cancels the old watch when a newer handoff starts its
        // own. Cancellation must actually stop the loop: a cancelled
        // Task.sleep throws instantly, and without the isCancelled guard
        // the loop would spin hot until the 11-minute ceiling.
        let api = StubCockpitAPI()
        api.licenseResult = .success(license(status: "none"))
        api.stateResult = .success(Fixtures.twoAccounts())
        let fleet = FleetViewModel(api: api, autostart: false)
        let quote = ProQuoteModel(api: api)
        let winback = freshWinback()
        let (ask, presented) = await handedOffCheckout(winback: winback, api: api)

        let watch = Task {
            await CheckoutDecider.watch(
                api: api, fleet: fleet, quote: quote, ask: ask, presented: presented,
                pollDelay: 0.01, deadline: 60)
        }
        try? await Task.sleep(nanoseconds: 30_000_000)
        watch.cancel()
        let before = Date()
        await watch.value
        XCTAssertLessThan(Date().timeIntervalSince(before), 1, "a cancelled watch returns promptly")
        XCTAssertEqual(winback.decisionsPending, 0)
        XCTAssertEqual(winback.state, .intact)
    }

    // MARK: - the ✕-inert span (press→browser-open, owner decision 2026-08-27)

    func testCloseIsInertFromPressUntilTheBrowserOpensThenEnabledAgain() async {
        let api = StubCockpitAPI()
        api.licenseResult = .success(license(status: "none"))
        let winback = freshWinback()
        // browser:false = the handoff landed but the launch has not — the
        // exact gap the span covers.
        let (ask, presented) = await handedOffCheckout(winback: winback, api: api, browser: false)
        XCTAssertFalse(ask.closeEnabled, "handoff landed, browser still opening — ✕ inert")
        ask.browserDidOpen(for: presented)
        XCTAssertTrue(ask.closeEnabled, "the browser owns the surface — ✕ enabled (dismiss-only)")
        // Start-again: a FRESH handoff goes inert again until ITS launch lands.
        await ask.pressCheckout()
        XCTAssertFalse(ask.browserOpen)
        XCTAssertFalse(ask.closeEnabled)
    }

    func testAStaleLaunchCompletionNeverFlipsTheNewerHandoffsState() async {
        // NSWorkspace completions can land out of order (money review F4):
        // press 1's completion arriving AFTER press 2 must not report press
        // 2's still-launching browser as open.
        let api = StubCockpitAPI()
        api.licenseResult = .success(license(status: "none"))
        let winback = freshWinback()
        let (ask, identityOne) = await handedOffCheckout(winback: winback, api: api, browser: false)
        await ask.pressCheckout() // press 2 — a newer identity owns the handoff
        let identityTwo = ask.liveCheckout!
        XCTAssertNotEqual(identityOne, identityTwo)

        ask.browserDidOpen(for: identityOne) // press 1's late completion
        XCTAssertFalse(ask.browserOpen, "a superseded launch must not end the newer press's inert span")
        ask.browserDidOpen(for: identityTwo)
        XCTAssertTrue(ask.browserOpen)

        // And after the surface closed entirely, even the right identity is
        // a no-op — there is no handoff left to report on.
        ask.checkoutSheetClosed()
        ask.browserDidOpen(for: identityTwo)
        XCTAssertFalse(ask.browserOpen)
    }

    func testAVerdictWaitsOutALiveFallbackSheetAndDeliversOnClose() async {
        // The machine refuses a verdict behind a live sheet (guard fail
        // case), and the WATCH must therefore hold it rather than consume
        // it (money review F6) — delivering the tick after the sheet closes.
        let api = StubCockpitAPI()
        api.licenseResult = .success(license(status: "none", outcome: "declined"))
        api.stateResult = .success(Fixtures.twoAccounts())
        let fleet = FleetViewModel(api: api, autostart: false)
        let quote = ProQuoteModel(api: api)
        let winback = freshWinback()
        let (ask, presented) = await handedOffCheckout(winback: winback, api: api, browser: false)
        XCTAssertTrue(ask.sheetLive)

        // Machine level: the verdict is refused while the sheet owns the
        // surface — nothing arms behind it.
        ask.checkoutAbandoned(presented)
        XCTAssertEqual(winback.state, .intact, "no verdict may arm behind a live sheet")

        let watch = Task {
            await CheckoutDecider.watch(
                api: api, fleet: fleet, quote: quote, ask: ask, presented: presented,
                pollDelay: 0.02, deadline: 5)
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(winback.state, .intact, "the watch holds the verdict while the sheet is up")
        ask.checkoutSheetClosed()
        await watch.value
        XCTAssertEqual(winback.state, .armed, "the held verdict delivers once the sheet closes")
    }

    func testCloseWhileTheBrowserOwnsTheSurfaceNeverArms() async {
        // The belt under `decisionsPending`: even with no watch running, a ✕
        // while the checkout is open in the browser dismisses without arming
        // — the lower offer must never paint behind a live payable tab.
        let api = StubCockpitAPI()
        api.licenseResult = .success(license(status: "none"))
        let winback = freshWinback()
        var dismissed = 0
        let (ask, _) = await handedOffCheckout(winback: winback, api: api, onDismiss: { dismissed += 1 })
        XCTAssertEqual(winback.decisionsPending, 0)
        ask.close()
        XCTAssertEqual(dismissed, 1)
        XCTAssertEqual(winback.state, .intact)
    }

    func testBrowserDidOpenAfterTheHandoffEndedIsANoOp() async {
        let api = StubCockpitAPI()
        api.licenseResult = .success(license(status: "none"))
        let winback = freshWinback()
        let (ask, presented) = await handedOffCheckout(winback: winback, api: api, browser: false)
        ask.checkoutSheetClosed() // the handoff surface is gone
        ask.browserDidOpen(for: presented)
        XCTAssertFalse(ask.browserOpen, "no handoff, nothing opened")
        XCTAssertTrue(ask.closeEnabled)
    }

    func testTheClientMintsHostedCheckouts() throws {
        // Money review F5: nothing asserted the 1.3.4 client actually asks
        // for the browser flow — the whole wave rides this one field.
        let body = CheckoutRequestBody(
            rung: "full", quote: QuoteEcho(trialDays: 4, currency: "gbp", amountMinor: 999),
            remindDaysBefore: 1)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as! [String: Any]
        XCTAssertEqual(json["ui"] as? String, "hosted")
        XCTAssertEqual(json["rung"] as? String, "full")
        XCTAssertEqual(json["remind_days_before"] as? Int, 1)
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
