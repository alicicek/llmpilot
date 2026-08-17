import AppKit
import SwiftUI
import XCTest

@testable import llmpilot

/// Phase 4 chunk 4C — VIEW-WIRING tests for PaywallViews.swift. Model
/// sequencing (screen selection, the decline ladder, the corridor) is
/// already pinned by ProAskMachineTests — these tests pin the layer this
/// chunk adds on top: which screen/dots/copy the VIEW resolves to render
/// for a given `AskMachine` snapshot, plus crash-safety mounting every
/// screen actually produces.
///
/// NOTE ON METHOD (see AXTestSupport.swift): an in-process
/// `NSAccessibilityProtocol` walk was tried for button-PRESS-driven
/// assertions and does not work in this XCTest host (confirmed against both
/// a SwiftUI `Button` and a plain `NSButton`) — this repo also has no
/// ViewInspector dependency. So the SELECTION/derivation logic these
/// screens render from is factored out as pure functions
/// (`PaywallDots.position`, `PriceBottomControl.resolve`, `PausedCTA
/// .resolve`, `PaywallActiveFacts.build`, `ReceiptHeadline.build`) and
/// tested directly here; hosting tests separately assert that mounting
/// every machine state never crashes (DoctorPanelHostingTests' pattern).
@MainActor
final class PaywallViewsTests: XCTestCase {
    private let fourDayQuote = LadderQuote(
        trialDays: 4, chargeDate: Date(timeIntervalSince1970: 1_784_707_200),
        pricesFull: ["gbp": 999, "usd": 1299], pricesDiscount: ["gbp": 599, "usd": 799])

    private func license(status: String, active: Bool = false) -> LicenseInfo {
        try! DaemonDates.decoder().decode(
            LicenseInfo.self,
            from: Data(#"{"available":true,"active":\#(active),"status":"\#(status)","nocard_trial_used":false}"#.utf8))
    }

    // MARK: - PaywallDots.position — the ✕-corridor step numbering

    func testDotsPositionOffsetsPerScreen() {
        let dots = PaywallDots(base: 3, total: 10)
        XCTAssertEqual(PaywallDots.position(for: .receipt, base: dots), StepPosition(step: 3, total: 10))
        XCTAssertEqual(PaywallDots.position(for: .remind, base: dots), StepPosition(step: 4, total: 10))
        XCTAssertEqual(PaywallDots.position(for: .price, base: dots), StepPosition(step: 5, total: 10))
        XCTAssertEqual(PaywallDots.position(for: .active, base: dots), StepPosition(step: 6, total: 10))
        XCTAssertEqual(PaywallDots.position(for: .paused, base: dots), StepPosition(step: 3, total: 10))
        XCTAssertEqual(PaywallDots.position(for: .noTerms, base: dots), StepPosition(step: 3, total: 10))
    }

    func testDotsPositionIsNilWhenNotGuided() {
        XCTAssertNil(PaywallDots.position(for: .price, base: nil))
    }

    // MARK: - PriceBottomControl — the bottom-left control on ⑧

    func testPriceBottomControlChooseReminderWhenUnanswered() {
        XCTAssertEqual(
            PriceBottomControl.resolve(remindDays: nil, remindOffsets: [2, 1]), .chooseReminder)
    }

    // F11 (2026-08-16 audit, owner decision: no reminder-day control on the
    // price screen): once
    // the reminder is answered, the price screen's footer settles to
    // nothing here — "Restore a purchase" is the only control left.
    func testPriceBottomControlNoneWhenAlreadyAnswered() {
        XCTAssertEqual(
            PriceBottomControl.resolve(remindDays: 1, remindOffsets: [2, 1]), .none)
    }

    func testPriceBottomControlNoneWithNoOffsets() {
        XCTAssertEqual(PriceBottomControl.resolve(remindDays: 1, remindOffsets: []), .none)
    }

    // MARK: - PausedCTA — the paused screen's primary button

    func testPausedCTATriesFreeWhenOfferCopyAndQuoteExist() {
        XCTAssertEqual(PausedCTA.resolve(hasOfferCopy: true, quote: fourDayQuote), .tryFree(days: 4))
        XCTAssertEqual(PausedCTA.resolve(hasOfferCopy: true, quote: fourDayQuote).label, "Try it free for 4 days")
    }

    func testPausedCTAFallsBackToTurnOnWithoutAnOffer() {
        XCTAssertEqual(PausedCTA.resolve(hasOfferCopy: false, quote: fourDayQuote), .turnOn)
        XCTAssertEqual(PausedCTA.resolve(hasOfferCopy: true, quote: nil), .turnOn)
        XCTAssertEqual(PausedCTA.resolve(hasOfferCopy: false, quote: nil).label, "Turn on the autopilot")
    }

    // MARK: - ReceiptHeadline — Receipt.tsx:39-48

    func testReceiptHeadlineNeverInventsAStatisticBelowTwoSwitchable() {
        let h0 = ReceiptHeadline.build(accountsSwitchable: 0)
        XCTAssertEqual(h0.lead, "What the ")
        XCTAssertEqual(h0.key, "autopilot")
        let h1 = ReceiptHeadline.build(accountsSwitchable: 1)
        XCTAssertEqual(h1.key, "autopilot")
    }

    func testReceiptHeadlineStatesTheMultipleAtTwoAndAbove() {
        XCTAssertEqual(ReceiptHeadline.build(accountsSwitchable: 2).key, "Twice the headroom.")
        XCTAssertEqual(ReceiptHeadline.build(accountsSwitchable: 3).key, "3× the headroom.")
        XCTAssertEqual(ReceiptHeadline.build(accountsSwitchable: 3).lead, "3 accounts. ")
    }

    // MARK: - PaywallActiveFacts — Paywall.tsx:206-212, never an invented fact

    func testActiveFactsOmitEachMissingInputRow() {
        let facts = PaywallActiveFacts.build(
            accountsWatched: nil, chargeDate: nil, remindDays: nil, committedAmount: nil, locale: "en-GB")
        XCTAssertEqual(facts, ["Switches you before the wall"])
    }

    func testActiveFactsIncludeEveryRowWhenEveryInputIsPresent() {
        let charge = Date(timeIntervalSince1970: 1_784_707_200)
        let facts = PaywallActiveFacts.build(
            accountsWatched: 3, chargeDate: charge, remindDays: 2, committedAmount: "£9.99", locale: "en-GB")
        XCTAssertEqual(facts.count, 4)
        XCTAssertEqual(facts[0], "Watching 3 accounts")
        XCTAssertEqual(facts[1], "Switches you before the wall")
        XCTAssertTrue(facts[2].hasPrefix("Reminder email — "))
        XCTAssertTrue(facts[3].hasPrefix("£9.99 once — "))
    }

    func testActiveFactsSingularAccountWording() {
        let facts = PaywallActiveFacts.build(
            accountsWatched: 1, chargeDate: nil, remindDays: nil, committedAmount: nil, locale: "en-GB")
        XCTAssertEqual(facts.first, "Watching 1 account")
    }

    func testActiveFactsStateTheWatchOnlySplitOnlyWhenItExists() {
        // Owner 2026-08-12, layer 1: "Watching 2 accounts" alone reads as
        // "the autopilot can use both" — false while any lane is pinned.
        let split = PaywallActiveFacts.build(
            accountsWatched: 2, chargeDate: nil, remindDays: nil, committedAmount: nil, locale: "en-GB",
            watchOnly: 1)
        XCTAssertEqual(split.first, "Watching 2 accounts · 1 watch-only")

        let none = PaywallActiveFacts.build(
            accountsWatched: 2, chargeDate: nil, remindDays: nil, committedAmount: nil, locale: "en-GB",
            watchOnly: 0)
        XCTAssertEqual(none.first, "Watching 2 accounts", "no split, no clause — never a zero brag")
    }

    // MARK: - hosting: mounting every AskScreen state never crashes
    // (DoctorPanelHostingTests' pattern — see AXTestSupport.swift for why
    // this chunk cannot go further and assert on rendered content).

    private func mountAndTeardown(_ ask: AskMachine, dots: PaywallDots? = nil) {
        let window = AXTestSupport.host(PaywallView(ask: ask, dots: dots))
        defer { window.orderOut(nil) }
        XCTAssertNotNil(window.contentView)
    }

    func testMountsReceiptScreenWithoutCrashing() {
        let ask = AskMachine(
            license: license(status: "none"), quote: fourDayQuote, guided: true, locale: "en-GB",
            winback: freshWinback(), api: StubCockpitAPI(), onDismiss: {})
        mountAndTeardown(ask, dots: PaywallDots(base: 0, total: 9))
    }

    func testMountsRemindScreenWithoutCrashing() {
        let ask = AskMachine(
            license: license(status: "none"), quote: fourDayQuote, guided: true, locale: "en-GB",
            winback: freshWinback(), api: StubCockpitAPI(), onDismiss: {})
        ask.askReminder()
        mountAndTeardown(ask, dots: PaywallDots(base: 0, total: 9))
    }

    func testMountsPriceScreenWithoutCrashing() {
        let ask = AskMachine(
            license: license(status: "none"), quote: fourDayQuote, guided: true, locale: "en-GB",
            winback: freshWinback(), api: StubCockpitAPI(), onDismiss: {})
        ask.askReminder()
        ask.remindDays = 1
        ask.remindContinue()
        mountAndTeardown(ask, dots: PaywallDots(base: 0, total: 9))
    }


    func testMountsPausedScreenWithoutCrashingIncludingNoOfferState() {
        let ask = AskMachine(
            license: license(status: "lapsed"), quote: nil, guided: false, locale: "en-GB",
            winback: freshWinback(), api: StubCockpitAPI(), onDismiss: {})
        mountAndTeardown(ask)
        let askWithQuote = AskMachine(
            license: license(status: "lapsed"), quote: fourDayQuote, guided: false, locale: "en-GB",
            winback: freshWinback(), api: StubCockpitAPI(), onDismiss: {})
        mountAndTeardown(askWithQuote)
    }

    func testMountsNoTermsScreenWithoutCrashing() {
        let ask = AskMachine(
            license: license(status: "none"), quote: nil, guided: true, locale: "en-GB",
            winback: freshWinback(), api: StubCockpitAPI(), onDismiss: {})
        mountAndTeardown(ask, dots: PaywallDots(base: 0, total: 9))
    }

    func testMountsActiveScreenWithoutCrashing() {
        let ask = AskMachine(
            license: license(status: "trialing", active: true), quote: fourDayQuote, guided: true, locale: "en-GB",
            winback: freshWinback(), api: StubCockpitAPI(), onDismiss: {})
        ask.accountsWatched = 2
        mountAndTeardown(ask, dots: PaywallDots(base: 0, total: 9))
    }

    @MainActor
    func testMountsActiveScreenWithWatchOnlyPromoteSectionWithoutCrashing() {
        // Owner 2026-08-12, layer 1 — the ⑨ promote list, armed-confirm
        // state included (the warning row changes the layout).
        let ask = AskMachine(
            license: license(status: "trialing", active: true), quote: fourDayQuote, guided: true, locale: "en-GB",
            winback: freshWinback(), api: StubCockpitAPI(), onDismiss: {})
        ask.accountsWatched = 2
        let move = ActivationMoveModel(api: StubCockpitAPI())
        move.requestMove("/u/.claude-work") // armed → warning visible
        let window = AXTestSupport.host(PaywallView(
            ask: ask, dots: PaywallDots(base: 0, total: 9),
            watchOnly: [WatchOnlyLane(configDir: "/u/.claude-work", email: "work@x.dev")],
            activationMove: move))
        defer { window.orderOut(nil) }
        XCTAssertNotNil(window.contentView)
    }
}
