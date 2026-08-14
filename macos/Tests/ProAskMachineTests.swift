import XCTest
@testable import llmpilot

/// Phase 4 chunk A — defect-class tests for AskMachine.swift
/// (web/src/pro/Paywall.tsx + App.tsx's checkout wiring) and
/// LicenseAccountModel (web/src/pro/LicenseSection.tsx's cancel/recover/
/// claim). Hermetic: StubCockpitAPI only, no network, no daemon.
///
/// UI-level axe (accessibility) passes — pro.spec.ts "axe: the education
/// screens...", "axe: receipt, reminder and price screens...", "axe:
/// Settings → License (trial)..." — are DEFERRED to the screens chunk: they
/// assert on rendered DOM/AX trees this pure-model chunk has none of.
@MainActor
final class ProAskMachineTests: XCTestCase {
    private let fourDayQuote = LadderQuote(
        trialDays: 4, chargeDate: Date(timeIntervalSince1970: 1_784_707_200),
        pricesFull: ["gbp": 999, "usd": 1299], pricesDiscount: ["gbp": 599, "usd": 799])

    private func license(status: String, active: Bool = false) -> LicenseInfo {
        try! DaemonDates.decoder().decode(
            LicenseInfo.self,
            from: Data(#"{"available":true,"active":\#(active),"status":"\#(status)","nocard_trial_used":false}"#.utf8))
    }

    private func checkoutHandoff(url: String, sessionID: String = "sess_1") -> CheckoutHandoff {
        try! DaemonDates.decoder().decode(
            CheckoutHandoff.self, from: Data(#"{"url":"\#(url)","session_id":"\#(sessionID)"}"#.utf8))
    }

    // MARK: - full-ladder ordering, incl. no-price-before-receipt
    // web twin: pro.spec.ts "the full ladder: problem → benefits → receipt
    // → reminder → price → handoff → activation facts"

    func testFullLadderOrderingReceiptThenRemindThenPriceThenCheckout() async {
        let api = StubCockpitAPI()
        api.licenseCheckoutResult = .success(checkoutHandoff(url: "https://checkout.stripe.com/c/pay/full?remind=2"))
        let ask = AskMachine(
            license: license(status: "none"), quote: fourDayQuote, guided: true, locale: "en-GB",
            api: api, onDismiss: {})

        // ⑥ receipt first — no price stated yet.
        XCTAssertEqual(ask.screen, .receipt)
        XCTAssertNil(ask.committedAmount)
        // Checkout is unreachable before the price screen — pinned as an
        // explicit guard (the web source relies on the button simply not
        // rendering anywhere else; this model has no view to hide it behind).
        await ask.pressCheckout()
        XCTAssertTrue(api.licenseCheckoutRequests.isEmpty)

        // ⑦ the reminder — locks in the buyer's choice, states no amount.
        ask.askReminder()
        XCTAssertEqual(ask.screen, .remind)
        ask.remindDays = 2
        ask.remindContinue()

        // ⑧ the price — every consent fact, the only checkout button.
        XCTAssertEqual(ask.screen, .price)
        XCTAssertEqual(ask.offerCopy?.headline, "Try the autopilot free for 4 days.")
        XCTAssertEqual(ask.offerCopy?.amount, "£9.99")

        // Checkout starts HERE, and the reminder choice made two screens
        // back RIDES the call.
        await ask.pressCheckout()
        XCTAssertEqual(api.licenseCheckoutRequests.count, 1)
        let req = api.licenseCheckoutRequests[0]
        XCTAssertEqual(req.rung, "full")
        XCTAssertEqual(req.remindDaysBefore, 2)
        XCTAssertEqual(req.echo, QuoteEcho(trialDays: 4, currency: "gbp", amountMinor: 999))
        XCTAssertEqual(ask.committedAmount, "£9.99")
        XCTAssertEqual(ask.handoffURL, "https://checkout.stripe.com/c/pay/full?remind=2")
    }

    // (The decline-ladder tests that lived here went with the ladder itself
    // — owner 2026-08-11: the ✕ closes, the corridor quotes ONE price.)

    // MARK: - reminder changeable after price
    // web twin: pro.spec.ts "the reminder day can still be changed after
    // the price is seen"

    func testReminderDayStaysChangeableFromThePriceScreen() async {
        let api = StubCockpitAPI()
        api.licenseCheckoutResult = .success(checkoutHandoff(url: "https://pay/full?remind=2"))
        let ask = AskMachine(
            license: license(status: "none"), quote: fourDayQuote, guided: true, locale: "en-GB",
            api: api, onDismiss: {})
        ask.askReminder()
        ask.remindDays = 1
        ask.remindContinue()
        XCTAssertEqual(ask.screen, .price)

        // "Change the reminder day" routes back to ⑦ without leaving the flow.
        ask.askReminder()
        XCTAssertEqual(ask.screen, .remind)
        ask.remindDays = 2
        ask.remindContinue()

        await ask.pressCheckout()
        XCTAssertEqual(api.licenseCheckoutRequests.first?.remindDaysBefore, 2)
    }

    // MARK: - paused: full consent + always-working close
    // web twins: pro.spec.ts "paused paywall (trial restart) states the
    // full consent, keeps an exit, and walks to a commit"; "a lapsed user
    // can always leave the paused screen"

    func testPausedStatesFullConsentAndQuotesTheOnePrice() {
        var dismissed = 0
        let ask = AskMachine(
            license: license(status: "lapsed"), quote: fourDayQuote, guided: false, locale: "en-GB",
            api: StubCockpitAPI(), onDismiss: { dismissed += 1 })
        XCTAssertEqual(ask.screen, .paused)
        // Restarting a card-upfront trial owes the SAME dates/amount as the
        // first ask — the full rung, which is now the ONLY rung the app can
        // quote (owner 2026-08-11: the lower-price ladder is gone).
        XCTAssertEqual(ask.offerCopy?.rung, .full)
        XCTAssertEqual(ask.offerCopy?.headline, "Try the autopilot free for 4 days.")

        // The close is ALWAYS working (the 1.2.6 regression this pins
        // shipped with NO ✕ at all here).
        XCTAssertTrue(ask.closeButtonVisible)
        ask.close()
        XCTAssertEqual(dismissed, 1)
    }

    // MARK: - one-click cancel
    // web twin: pro.spec.ts "Settings → License shows the trial and
    // cancels it in one click"

    func testOneClickCancelCallsTheWireAndReloads() async {
        let api = StubCockpitAPI()
        api.licenseCancelResult = .success(LicenseCancelResult(status: "lapsed"))
        let model = LicenseAccountModel(api: api)
        var reloaded = 0
        model.onReload = { reloaded += 1 }

        await model.cancel()
        XCTAssertEqual(api.licenseCancelCalls, 1)
        XCTAssertEqual(reloaded, 1)
        XCTAssertFalse(model.busy)
        XCTAssertNil(model.note)
    }

    func testCancelFailureReportsARemedyAndNeverReloads() async {
        let api = StubCockpitAPI()
        api.licenseCancelResult = .failure(DaemonError.http(502, "cancel could not complete — try again"))
        let model = LicenseAccountModel(api: api)
        var reloaded = 0
        model.onReload = { reloaded += 1 }

        await model.cancel()
        XCTAssertEqual(model.note, "cancel could not complete — try again")
        XCTAssertEqual(reloaded, 0)
    }

    // MARK: - uniform recover copy
    // web twin: pro.spec.ts "recover-by-email answers with uniform copy"

    func testRecoverAnswersWithUniformCopyOnSuccess() async {
        let api = StubCockpitAPI()
        api.licenseRecoverResult = .success(())
        let model = LicenseAccountModel(api: api)

        await model.recover(email: "someone@example.com")
        XCTAssertEqual(api.licenseRecoverRequests, ["someone@example.com"])
        // Uniform whether or not the address is on file — the model never
        // branches on outcome; the daemon's 202-for-everyone contract
        // (license.go handleLicenseRecover) is what makes this true, and
        // this pins that the model doesn't undermine it with its own copy.
        XCTAssertEqual(model.note, "If that email has a purchase, a recovery link is on its way. Open it on this Mac.")
    }

    // MARK: - claim {token} wire body
    // web twin: pro.spec.ts "recovery code restores Pro from Settings →
    // License"

    func testClaimSendsTheExactTokenBodyAndRestoresOnSuccess() async {
        let api = StubCockpitAPI()
        api.licenseClaimResult = .success(LicenseClaimResult(status: "lifetime"))
        let model = LicenseAccountModel(api: api)
        var reloaded = 0
        model.onReload = { reloaded += 1 }

        await model.claim(token: "abc123deadbeef")
        XCTAssertEqual(api.licenseClaimRequests, ["abc123deadbeef"])
        XCTAssertEqual(model.note, "Restored — Pro is back on.")
        XCTAssertEqual(reloaded, 1)
    }

    func testClaimFailureMapsKnownRefusalCodesToCopy() async {
        let api = StubCockpitAPI()
        api.licenseClaimResult = .failure(ApiError(status: 400, code: "invalid_input", message: "bad body"))
        let model = LicenseAccountModel(api: api)

        await model.claim(token: "x")
        XCTAssertEqual(model.note, LadderLogic.licenseErrorCopy("invalid_input"))
    }

    // MARK: - success-only clears + transient-UI lifecycle
    // (review 2026-08-08 P2-8 + P1-6; LicenseSection.tsx clears inside
    // `try` (:75,:92,:106), and its `revealed`/`note` are component-local
    // state destroyed with the dialog (:51))

    func testMutationsReportWhetherTheWriteLanded() async {
        let api = StubCockpitAPI()
        api.licenseCancelResult = .failure(DaemonError.http(502, "worker down"))
        api.licenseRecoverResult = .failure(DaemonError.http(502, "worker down"))
        api.licenseClaimResult = .success(LicenseClaimResult(status: "lifetime"))
        let model = LicenseAccountModel(api: api)

        // The card keeps the confirm box armed / the typed email intact on
        // failure, so the return value is the load-bearing signal.
        let cancelLanded = await model.cancel()
        XCTAssertFalse(cancelLanded)
        let recoverLanded = await model.recover(email: "a@b.c")
        XCTAssertFalse(recoverLanded)
        let claimLanded = await model.claim(token: "tok")
        XCTAssertTrue(claimLanded)
    }

    func testResetTransientUIClearsTheRevealAndTheNote() async {
        let api = StubCockpitAPI()
        api.licenseResult = .success(licenseWithID())
        let model = LicenseAccountModel(api: api)

        await model.reveal()
        XCTAssertNotNil(model.revealedID)
        await model.recover(email: "a@b.c")
        XCTAssertNotNil(model.note)

        // Settings closed — the next open must start masked with fresh copy.
        model.resetTransientUI()
        XCTAssertNil(model.revealedID)
        XCTAssertNil(model.note)
    }

    private func licenseWithID() -> LicenseInfo {
        try! DaemonDates.decoder().decode(
            LicenseInfo.self,
            from: Data(#"{"available":true,"active":true,"status":"trialing","nocard_trial_used":false,"license_id":"lp_full_1234567890","license_id_masked":"lp_full_…7890"}"#.utf8))
    }

    // MARK: - quote_stale restarts the ask with NEW terms
    // web twin: firstrun.spec.ts "quote_stale restarts the ask with the NEW
    // terms and the remedy line"

    func testQuoteStaleRestartsAtReceiptOnceTheReloadedQuoteLands() async {
        let api = StubCockpitAPI()
        api.licenseCheckoutResult = .failure(ApiError(status: 409, code: "quote_stale", message: "terms drifted"))
        let ask = AskMachine(
            license: license(status: "none"), quote: fourDayQuote, guided: true, locale: "en-GB",
            api: api, onDismiss: {})
        var reloadCalls = 0
        ask.reloadQuote = { reloadCalls += 1 }
        ask.askReminder()
        ask.remindDays = 1
        ask.remindContinue()
        XCTAssertEqual(ask.screen, .price)

        await ask.pressCheckout()
        XCTAssertEqual(reloadCalls, 1)
        XCTAssertEqual(
            ask.checkoutError, "The price or trial terms changed — review the new terms and confirm.")
        // The reload hasn't landed yet — still on price, remedy beside the
        // button that was pressed.
        XCTAssertEqual(ask.stage, .price)

        // The reloaded quote lands with DIFFERENT terms — restart at ⑥.
        let reQuoted = LadderQuote(
            trialDays: 4, chargeDate: fourDayQuote.chargeDate,
            pricesFull: ["gbp": 1099, "usd": 1299], pricesDiscount: fourDayQuote.pricesDiscount)
        ask.setQuote(reQuoted)
        XCTAssertEqual(ask.stage, .receipt)
        XCTAssertEqual(ask.screen, .receipt)

        // Walking forward again states the RELOADED price.
        ask.askReminder()
        ask.remindDays = 1
        ask.remindContinue()
        XCTAssertEqual(ask.offerCopy?.amount, "£10.99")
    }

    func testTermsChangeBounceIsGuardedByALiveHandoffURL() async {
        let api = StubCockpitAPI()
        api.licenseCheckoutResult = .success(checkoutHandoff(url: "https://pay/full"))
        let ask = AskMachine(
            license: license(status: "none"), quote: fourDayQuote, guided: true, locale: "en-GB",
            api: api, onDismiss: {})
        ask.askReminder()
        ask.remindDays = 1
        ask.remindContinue()
        await ask.pressCheckout()
        XCTAssertNotNil(ask.handoffURL)
        XCTAssertEqual(ask.stage, .price)

        // A routine re-quote arrives while the payment window is open —
        // must NOT yank the handoff line (that would invite the re-click
        // that orphans a live Session's activation poll).
        let reQuoted = LadderQuote(
            trialDays: 4, chargeDate: fourDayQuote.chargeDate,
            pricesFull: ["gbp": 1099], pricesDiscount: fourDayQuote.pricesDiscount)
        ask.setQuote(reQuoted)
        XCTAssertEqual(ask.stage, .price)
    }

    func testRoutineRequoteWithUnchangedTermsDoesNotBounce() {
        let ask = AskMachine(
            license: license(status: "none"), quote: fourDayQuote, guided: true, locale: "en-GB",
            api: StubCockpitAPI(), onDismiss: {})
        ask.askReminder()
        ask.remindDays = 1
        ask.remindContinue()
        XCTAssertEqual(ask.stage, .price)

        // The 15-minute TTL re-quote fetches a FRESH object with the SAME
        // numbers — must not throw the buyer off the commit screen.
        let sameNumbers = LadderQuote(
            trialDays: fourDayQuote.trialDays, chargeDate: Date(), // a later charge_date, same terms
            pricesFull: fourDayQuote.pricesFull, pricesDiscount: fourDayQuote.pricesDiscount)
        ask.setQuote(sameNumbers)
        XCTAssertEqual(ask.stage, .price)
    }

    // MARK: - short trial never locks Continue
    // web twin: firstrun.spec.ts "a trial too short to offer a reminder
    // choice never locks the flow"

    func testShortTrialWithNoOffsetsSkipsTheQuestionEntirely() {
        let oneDayQuote = LadderQuote(
            trialDays: 1, chargeDate: Date(timeIntervalSince1970: 1_784_000_000),
            pricesFull: fourDayQuote.pricesFull, pricesDiscount: fourDayQuote.pricesDiscount)
        let ask = AskMachine(
            license: license(status: "none"), quote: oneDayQuote, guided: true, locale: "en-GB",
            api: StubCockpitAPI(), onDismiss: {})
        // [2,1].filter(< 1) is EMPTY — no chips, so no question.
        XCTAssertEqual(ask.remindOffsets, [])
        ask.askReminder()
        // Never lands on a screen whose Continue nothing could enable —
        // silently pre-answers with the sole viable value.
        XCTAssertEqual(ask.remindDays, 1)
        XCTAssertEqual(ask.screen, .price)
    }

    // MARK: - corridor: no exit before the ask
    // web twin: tour.spec.ts "no screen before the ask offers a way out of
    // the flow" (the OnboardingModel side of this is pinned in
    // ProOnboardingModelTests; this is the AskMachine side — SPEC-127 D9:
    // ⑧ is the corridor's ONLY door).

    func testGuidedFlowHidesCloseUntilThePriceScreen() {
        let ask = AskMachine(
            license: license(status: "none"), quote: fourDayQuote, guided: true, locale: "en-GB",
            api: StubCockpitAPI(), onDismiss: {})
        XCTAssertEqual(ask.screen, .receipt)
        XCTAssertFalse(ask.closeButtonVisible)
        ask.askReminder()
        XCTAssertEqual(ask.screen, .remind)
        XCTAssertFalse(ask.closeButtonVisible)
        ask.remindDays = 1
        ask.remindContinue()
        XCTAssertEqual(ask.screen, .price)
        XCTAssertTrue(ask.closeButtonVisible) // the corridor's one door
    }

    func testReopenedPaywallKeepsACloseOnEveryScreen() {
        // Not guided (`dots === undefined` in the web source): every screen
        // keeps its own ✕, since the corridor rule is a property of
        // onboarding, not of the paywall itself.
        let ask = AskMachine(
            license: license(status: "none"), quote: fourDayQuote, guided: false, locale: "en-GB",
            api: StubCockpitAPI(), onDismiss: {})
        XCTAssertEqual(ask.screen, .receipt)
        XCTAssertTrue(ask.closeButtonVisible)
    }

    // MARK: - applyReloadedLicense — Phase 4 chunk 4E's post-checkout routing
    // (the native twin of Paywall.tsx reading `license.active` live from
    // props; AskMachine has no page-reload/SSE equivalent to ride, so the
    // composition root pushes a reloaded license in explicitly).

    func testApplyReloadedLicenseRoutesToTheActiveScreen() async {
        let api = StubCockpitAPI()
        api.licenseCheckoutResult = .success(checkoutHandoff(url: "https://checkout.stripe.com/c/pay/full"))
        let ask = AskMachine(
            license: license(status: "none"), quote: fourDayQuote, guided: true, locale: "en-GB",
            api: api, onDismiss: {})
        ask.askReminder()
        ask.remindDays = 1
        ask.remindContinue()
        await ask.pressCheckout()
        XCTAssertEqual(ask.committedAmount, "£9.99") // preserved — a reconstructed machine would lose this
        XCTAssertEqual(ask.screen, .price)

        ask.applyReloadedLicense(license(status: "lifetime", active: true))

        XCTAssertEqual(ask.screen, .active)
        // The activation facts screen still needs the price it committed to.
        XCTAssertEqual(ask.committedAmount, "£9.99")
    }

    func testApplyReloadedLicenseIgnoresAStillInactiveReload() {
        let ask = AskMachine(
            license: license(status: "none"), quote: fourDayQuote, guided: true, locale: "en-GB",
            api: StubCockpitAPI(), onDismiss: {})
        XCTAssertEqual(ask.screen, .receipt)

        // The buyer closed the checkout sheet without completing payment —
        // the reload must not force an unearned screen.
        ask.applyReloadedLicense(license(status: "none", active: false))

        XCTAssertEqual(ask.screen, .receipt)
    }

    // MARK: - checkout sheet close (review 2026-08-08 P1-5)
    // Natively the sheet IS the payment surface: once it closes, the
    // "Checkout is open in the payment window" line must die with it, and a
    // second checkout returning the IDENTICAL url must still re-present
    // (the view re-presents on nil→url change).

    func testCheckoutSheetClosedClearsTheHandoffAndReleasesTheBounceGuard() async {
        let api = StubCockpitAPI()
        api.licenseCheckoutResult = .success(checkoutHandoff(url: "https://checkout.stripe.com/c/pay/full"))
        let ask = AskMachine(
            license: license(status: "none"), quote: fourDayQuote, guided: true, locale: "en-GB",
            api: api, onDismiss: {})
        ask.askReminder()
        ask.remindDays = 1
        ask.remindContinue()
        await ask.pressCheckout()
        XCTAssertNotNil(ask.handoffURL)

        // While the payment window is open, a drifted re-quote must NOT
        // bounce the buyer (setQuote's live-handoff guard).
        let drifted = LadderQuote(
            trialDays: 9, chargeDate: fourDayQuote.chargeDate,
            pricesFull: fourDayQuote.pricesFull, pricesDiscount: fourDayQuote.pricesDiscount)
        ask.setQuote(drifted)
        XCTAssertEqual(ask.screen, .price)

        ask.checkoutSheetClosed()
        XCTAssertNil(ask.handoffURL, "the sheet is gone — the machine must not claim a live payment window")

        // With the sheet closed the guard is released: the NEXT terms drift
        // walks the buyer back to the receipt.
        let driftedAgain = LadderQuote(
            trialDays: 12, chargeDate: fourDayQuote.chargeDate,
            pricesFull: fourDayQuote.pricesFull, pricesDiscount: fourDayQuote.pricesDiscount)
        ask.setQuote(driftedAgain)
        XCTAssertEqual(ask.screen, .receipt)
    }
}
