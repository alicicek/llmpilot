import XCTest
@testable import llmpilot

/// Phase 4 chunk A — pure-function defect-class tests for LadderLogic.swift
/// (web/src/pro/ladder.ts, web/src/pro/errors.ts, web/src/shell/
/// FirstRun.tsx's groupByEmail/sessionPercent). Hermetic: no network, no
/// daemon, no dates read from the real clock (chargeInstant takes `now`
/// explicitly).
///
/// Ground truth is the SHIPPED web source, not spec prose — plans/SPEC-127's
/// 2026-08-06 amendment (pair-fold, back-arrows, 62→100@50ms) is
/// unimplemented in web/src, so these pin the OLD (shipped) behavior.
final class ProLadderLogicTests: XCTestCase {
    private let quote = LadderQuote(
        trialDays: 4,
        chargeDate: Date(timeIntervalSince1970: 1_784_707_200),
        pricesFull: ["gbp": 999, "usd": 1299],
        pricesDiscount: ["gbp": 599, "usd": 799])

    // MARK: - duplicate-folder collapse
    // web twin: firstrun.spec.ts "duplicate folders collapse into one
    // identity row; a separate account is named as the switch target"

    func testGroupByEmailCollapsesDuplicateFoldersUnderOneRow() {
        let dirs = [
            DetectedDir(configDir: "/Users/x/.claude", email: "same@example.dev", registered: false),
            DetectedDir(configDir: "/Users/x/.claude-alt", email: "same@example.dev", registered: false),
            DetectedDir(configDir: "/Users/x/.claude-two", email: "other@example.dev", registered: false),
        ]
        let groups = LadderLogic.groupByEmail(dirs)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].email, "same@example.dev")
        XCTAssertEqual(groups[0].dirs.count, 2)
        // Primary prefers the dir literally ending "/.claude".
        XCTAssertEqual(groups[0].primary.configDir, "/Users/x/.claude")
        XCTAssertEqual(groups[1].email, "other@example.dev")
        XCTAssertEqual(groups[1].dirs.count, 1)
    }

    /// The fail case of the SAME guard: ground truth is CASE-SENSITIVE
    /// (FirstRun.tsx:24-36's `Map` keys on the literal `d.email`) — a
    /// same-person-different-case pair is NOT collapsed here (that fold
    /// happens one level up, in OnboardingModel.identities). Pinning this
    /// stops a future "helpful" case-fold from silently changing which
    /// folder becomes `primary`.
    func testGroupByEmailDoesNotCaseFold() {
        let dirs = [
            DetectedDir(configDir: "/Users/x/.claude", email: "Real@Example.dev", registered: false),
            DetectedDir(configDir: "/Users/x/.claude-alt", email: "real@example.dev", registered: false),
        ]
        XCTAssertEqual(LadderLogic.groupByEmail(dirs).count, 2)
    }

    // MARK: - real-gauge fill derivation
    // web twin: firstrun.spec.ts "the problem is taught first, then
    // accounts, then the ask; the add fills a real gauge" (the 42% assertion)

    func testSessionPercentReadsTheAddedAccountsRealBucket() {
        let group = EmailGroup(
            email: "real-adopted@example.dev",
            dirs: [DetectedDir(configDir: "/Users/x/.claude", email: "real-adopted@example.dev", registered: false)],
            primary: DetectedDir(configDir: "/Users/x/.claude", email: "real-adopted@example.dev", registered: false))
        let accounts = [
            AccountState(
                id: "real-1", label: "real", email: "real-adopted@example.dev", pinned: false,
                snapshot: UsageSnapshot(asOf: Date(), buckets: [Bucket(kind: "session", scope: nil, percent: 42, resetsAt: nil, severity: nil, active: nil)]),
                tokenNote: nil, stale: nil, configDir: "/Users/x/.claude"),
        ]
        XCTAssertEqual(LadderLogic.sessionPercent(accounts: accounts, group: group), 42)
    }

    func testSessionPercentIsNilBeforeTheAccountExistsAndZeroWithNoBucket() {
        let group = EmailGroup(
            email: "x@example.dev",
            dirs: [DetectedDir(configDir: "/Users/x/.claude", email: "x@example.dev", registered: false)],
            primary: DetectedDir(configDir: "/Users/x/.claude", email: "x@example.dev", registered: false))
        XCTAssertNil(LadderLogic.sessionPercent(accounts: [], group: group))

        let noBucketAccount = AccountState(
            id: "a", label: "a", email: "x@example.dev", pinned: false,
            snapshot: UsageSnapshot(asOf: Date(), buckets: []), tokenNote: nil, stale: nil,
            configDir: "/Users/x/.claude")
        XCTAssertEqual(LadderLogic.sessionPercent(accounts: [noBucketAccount], group: group), 0)
    }

    // MARK: - money copy (supporting coverage the defect-class tests lean on)

    func testFormatAmountRendersGBPAndUSDForEnGB() {
        XCTAssertEqual(LadderLogic.formatAmount(locale: "en-GB", currency: "gbp", amountMinor: 999), "£9.99")
        XCTAssertEqual(LadderLogic.formatAmount(locale: "en-GB", currency: "usd", amountMinor: 1299), "US$12.99")
    }

    func testLocalAmountPicksTheExactCurrencyForTheLocale() {
        let gb = LadderLogic.localAmount(quote.pricesFull, locale: "en-GB")
        XCTAssertEqual(gb?.text, "£9.99")
        XCTAssertFalse(gb?.approx ?? true)
        XCTAssertEqual(gb?.echo, QuoteEcho(trialDays: nil, currency: "gbp", amountMinor: 999))

        // A locale with neither an exact match nor "gbp" present falls back
        // approximate (F7: never promise a number the payment page can't
        // guarantee).
        let jp = LadderLogic.localAmount(["usd": 1299], locale: "ja-JP")
        XCTAssertEqual(jp?.text, "$12.99") // ja_JP's own currency-symbol resolution for USD
        XCTAssertTrue(jp?.approx ?? false)
    }

    /// Review 2026-08-08 P0-2: production call sites pass
    /// `Locale.current.identifier`, which is ICU-form ("en_GB", underscored,
    /// possibly with an @-keyword tail) — NOT the BCP-47 hyphens the earlier
    /// tests use. The matcher must treat both shapes identically, or every
    /// real buyer falls through to approx-gbp.
    func testLocalAmountAcceptsICUFormLocaleIdentifiers() {
        let gb = LadderLogic.localAmount(quote.pricesFull, locale: "en_GB")
        XCTAssertEqual(gb?.echo.currency, "gbp")
        XCTAssertFalse(gb?.approx ?? true, "en_GB is an exact gbp locale — no ≈")

        let us = LadderLogic.localAmount(quote.pricesFull, locale: "en_US")
        XCTAssertEqual(us?.echo.currency, "usd")
        XCTAssertEqual(us?.echo.amountMinor, 1299)
        XCTAssertFalse(us?.approx ?? true, "en_US is an exact usd locale — no ≈")

        // An @-keyword tail must not defeat the region match.
        let usRg = LadderLogic.localAmount(quote.pricesFull, locale: "en_US@rg=gbzzzz")
        XCTAssertEqual(usRg?.echo.currency, "usd")

        // Non-GB/US stays the approx-gbp fallback in either form.
        let de = LadderLogic.localAmount(quote.pricesFull, locale: "de_DE")
        XCTAssertEqual(de?.echo.currency, "gbp")
        XCTAssertTrue(de?.approx ?? false)

        // Degenerate input must not crash the matcher.
        XCTAssertNotNil(LadderLogic.localAmount(quote.pricesFull, locale: ""))
    }

    func testRungCopyNeverStrikesAnEqualPrice() {
        // Under an active launch window both rungs quote the same amount —
        // striking a price equal to the offer would be a fake markdown.
        let equalQuote = LadderQuote(
            trialDays: 4, chargeDate: quote.chargeDate,
            pricesFull: ["gbp": 599], pricesDiscount: ["gbp": 599])
        let copy = LadderLogic.rungCopy(.discountTrial, quote: equalQuote, locale: "en-GB")
        XCTAssertNil(copy?.strikeAmount)
    }

    func testRungCopyStrikesTheHigherFullPrice() {
        let copy = LadderLogic.rungCopy(.discountTrial, quote: quote, locale: "en-GB")
        XCTAssertEqual(copy?.amount, "£5.99")
        XCTAssertEqual(copy?.strikeAmount, "£9.99")
        XCTAssertEqual(copy?.headline, "Same trial, lower price")
    }

    func testRungCopyNocardTrialIsNeverRendered() {
        XCTAssertNil(LadderLogic.rungCopy(.nocardTrial, quote: quote, locale: "en-GB"))
    }

    func testHasLowerOfferRequiresAGenuinelyLowerSameCurrencyPrice() {
        // the win-back rung only exists while the discount is
        // genuinely lower in the buyer's OWN resolved currency.
        XCTAssertTrue(LadderLogic.hasLowerOffer(quote: quote, locale: "en-GB"))
        XCTAssertTrue(LadderLogic.hasLowerOffer(quote: quote, locale: "en-US"))

        // Fail case: an active launch window sells full AT the discount —
        // an equal price is no offer.
        let launch = LadderQuote(
            trialDays: 4, chargeDate: quote.chargeDate,
            pricesFull: ["gbp": 599], pricesDiscount: ["gbp": 599])
        XCTAssertFalse(LadderLogic.hasLowerOffer(quote: launch, locale: "en-GB"))

        // Fail case: rungs resolving to DIFFERENT currencies for one locale
        // cannot honestly compare minor units — no offer, never a guess.
        let mismatched = LadderQuote(
            trialDays: 4, chargeDate: quote.chargeDate,
            pricesFull: ["usd": 1299], pricesDiscount: ["gbp": 599])
        XCTAssertFalse(LadderLogic.hasLowerOffer(quote: mismatched, locale: "en-US"))
    }

    func testTermsSigIsStableUnderEqualContentAndChangesOnDrift() {
        let same = LadderQuote(
            trialDays: quote.trialDays, chargeDate: Date(), // charge_date is NOT part of the signature
            pricesFull: quote.pricesFull, pricesDiscount: quote.pricesDiscount)
        XCTAssertEqual(LadderLogic.termsSig(quote), LadderLogic.termsSig(same))

        let drifted = LadderQuote(
            trialDays: quote.trialDays, chargeDate: quote.chargeDate,
            pricesFull: ["gbp": 1099, "usd": 1299], pricesDiscount: quote.pricesDiscount)
        XCTAssertNotEqual(LadderLogic.termsSig(quote), LadderLogic.termsSig(drifted))
    }

    func testLicenseErrorCopyMapAndTheQuoteStaleOmission() {
        XCTAssertEqual(
            LadderLogic.licenseErrorCopy("seat_limit_reached"),
            "Seat limit reached — this license is already on its maximum number of Macs. Restore by email to move Pro to this one.")
        XCTAssertEqual(
            LadderLogic.licenseErrorCopy("invalid_input"),
            "This version shows outdated terms. Update llmpilot from the menu bar, then try again.")
        // quote_stale never renders through this map — AskMachine.pressCheckout
        // handles it as its own branch with its own remedy line.
        XCTAssertNil(LadderLogic.licenseErrorCopy("quote_stale"))
        XCTAssertNil(LadderLogic.licenseErrorCopy(nil))
        XCTAssertNil(LadderLogic.licenseErrorCopy("something_unmapped"))
    }

    func testChargeInstantUsesTheInjectedClockNeverTheQuotesChargeDate() {
        let renderTime = Date(timeIntervalSince1970: 0)
        let staleQuote = LadderQuote(
            trialDays: 4, chargeDate: Date(timeIntervalSince1970: 999_999_999), // deliberately stale
            pricesFull: quote.pricesFull, pricesDiscount: quote.pricesDiscount)
        let charge = LadderLogic.chargeInstant(quote: staleQuote, now: renderTime)
        XCTAssertEqual(charge, renderTime.addingTimeInterval(4 * 24 * 60 * 60))
    }

    func testQuoteValidationRefusesMalformedTerms() throws {
        // Mirrors api.ts fetchQuote's guard — a price-less rung must never
        // render as a paywall (would state "Invalid Date" or an invented
        // price). Built via the real decode path (LicenseQuote has no
        // memberwise init once it defines `init(from:)`), exactly as the
        // wire would deliver it.
        let missingDiscount = try DaemonDates.decoder().decode(
            LicenseQuote.self,
            from: Data(#"{"trial_days":4,"charge_date":"2026-07-23T12:00:00Z","prices":{"full":{"gbp":999},"discount":{}}}"#.utf8))
        XCTAssertNil(LadderQuote.validated(from: missingDiscount))

        let missingChargeDate = try DaemonDates.decoder().decode(
            LicenseQuote.self,
            from: Data(#"{"trial_days":4,"prices":{"full":{"gbp":999},"discount":{"gbp":599}}}"#.utf8))
        XCTAssertNil(LadderQuote.validated(from: missingChargeDate))

        let happy = try DaemonDates.decoder().decode(
            LicenseQuote.self,
            from: Data(#"{"trial_days":4,"charge_date":"2026-07-23T12:00:00Z","prices":{"full":{"gbp":999},"discount":{"gbp":599}}}"#.utf8))
        XCTAssertNotNil(LadderQuote.validated(from: happy))
    }

    // MARK: - QuoteEcho wire shape (the checkout body's "quote" field,
    // license.go:261-262,668-682 forward it to the worker verbatim)

    func testQuoteEchoOmitsUnresolvedFieldsRatherThanEncodingNull() throws {
        let full = try JSONEncoder().encode(QuoteEcho(trialDays: 4, currency: "gbp", amountMinor: 999))
        let fullObj = try XCTUnwrap(try JSONSerialization.jsonObject(with: full) as? [String: Any])
        XCTAssertEqual(Set(fullObj.keys), ["trial_days", "currency", "amount_minor"])

        // A field that never resolved (no price for this currency) must be
        // OMITTED, not sent as `null` — mirrors JS's `JSON.stringify`
        // dropping `undefined` keys.
        let partial = try JSONEncoder().encode(QuoteEcho(trialDays: nil, currency: "gbp", amountMinor: 999))
        let partialObj = try XCTUnwrap(try JSONSerialization.jsonObject(with: partial) as? [String: Any])
        XCTAssertEqual(Set(partialObj.keys), ["currency", "amount_minor"])
    }
}
