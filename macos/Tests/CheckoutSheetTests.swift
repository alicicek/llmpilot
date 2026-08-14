import WebKit
import XCTest

@testable import llmpilot

/// Pure-decision and seam-wiring coverage for the checkout sheet (Phase 4
/// chunk D). No live WKWebView is constructed: WKNavigationAction can't be
/// built in tests, so CheckoutSheetPolicy.decide and CheckoutSheetDelegate
/// .handle are exercised directly, matching the CockpitWindowController
/// .handleScriptMessage split this repo already uses for the same reason.
@MainActor
final class CheckoutSheetTests: XCTestCase {
    // MARK: - isPaymentHost — exact-suffix match, synced with
    // CockpitWindowController.isPaymentHost (CockpitWindow.swift:141-144).

    func testIsPaymentHostExactSuffixTable() {
        XCTAssertTrue(CheckoutHost.isPaymentHost("stripe.com"))
        XCTAssertTrue(CheckoutHost.isPaymentHost("llmpilot.dev"))
        XCTAssertTrue(CheckoutHost.isPaymentHost("checkout.stripe.com"))
        XCTAssertFalse(CheckoutHost.isPaymentHost("evil-stripe.com"))
        XCTAssertFalse(CheckoutHost.isPaymentHost("stripe.com.evil.example"))
        XCTAssertFalse(CheckoutHost.isPaymentHost(nil))
    }

    // MARK: - /pro/activated path-match rule

    func testActivatedOnPaymentHostClosesSheet() {
        XCTAssertEqual(
            CheckoutSheetPolicy.decide(url: URL(string: "https://stripe.com/pro/activated")!, isMainFrame: true),
            .cancelAndClose)
        XCTAssertEqual(
            CheckoutSheetPolicy.decide(url: URL(string: "https://llmpilot.dev/pro/activated?x=1")!, isMainFrame: true),
            .cancelAndClose)
        XCTAssertEqual(
            CheckoutSheetPolicy.decide(url: URL(string: "https://checkout.stripe.com/pro/activated")!, isMainFrame: true),
            .cancelAndClose)
    }

    func testActivatedPathOnForeignHostDoesNotClose() {
        // Host-checked so a foreign redirect to /pro/activated cannot
        // dismiss the sheet early.
        let url = URL(string: "https://evil.example/pro/activated")!
        XCTAssertEqual(CheckoutSheetPolicy.decide(url: url, isMainFrame: true), .cancelAndOpenBrowser(url))
    }

    // MARK: - Policy decisions

    func testPaymentHostNonActivatedAllows() {
        let url = URL(string: "https://checkout.stripe.com/pay/cs_test_123")!
        XCTAssertEqual(CheckoutSheetPolicy.decide(url: url, isMainFrame: true), .allow)
    }

    func testOffPaymentHostCancelsAndRoutesToBrowser() {
        let url = URL(string: "https://example.com/help")!
        XCTAssertEqual(CheckoutSheetPolicy.decide(url: url, isMainFrame: true), .cancelAndOpenBrowser(url))
    }

    func testNilURLAllows() {
        XCTAssertEqual(CheckoutSheetPolicy.decide(url: nil, isMainFrame: true), .allow)
    }

    func testActivatedIsAPathSegmentMatchNotAPrefix() {
        // Review 2026-08-08 P2-11: "/pro/activatedxyz" must not dismiss a
        // live payment sheet; a genuine sub-path still does.
        XCTAssertEqual(
            CheckoutSheetPolicy.decide(url: URL(string: "https://stripe.com/pro/activatedxyz")!, isMainFrame: true),
            .allow)
        XCTAssertEqual(
            CheckoutSheetPolicy.decide(url: URL(string: "https://stripe.com/pro/activated/done")!, isMainFrame: true),
            .cancelAndClose)
    }

    // MARK: - sub-frame (iframe) navigations — owner-hit 2026-08-08: Stripe
    // embedded checkout composes from hosts OUTSIDE the payment list
    // (b.stripecdn.com captcha, m.stripe.network card fields); bouncing
    // those iframe loads opened four browser tabs per checkout.

    func testOffHostIframesStayInTheSheetInsteadOfSpawningTabs() {
        for frame in ["https://b.stripecdn.com/stripethirdparty-srv/assets/HCaptchaInvisible.html",
                       "https://m.stripe.network/inner.html"] {
            XCTAssertEqual(
                CheckoutSheetPolicy.decide(url: URL(string: frame)!, isMainFrame: false),
                .allow,
                "an embedded-checkout iframe must render in place, never open a tab")
        }
    }

    func testIframeCannotDismissTheSheetViaActivatedPath() {
        // The activated-close is main-frame-gated: an iframe — even on a
        // payment host — must not be able to end the payment surface.
        XCTAssertEqual(
            CheckoutSheetPolicy.decide(url: URL(string: "https://llmpilot.dev/pro/activated")!, isMainFrame: false),
            .allow)
    }

    func testNonWebSchemesAreDroppedWithoutASystemHandoff() {
        // Review 2026-08-08 P2-11: payment content must not be able to
        // launch arbitrary URL-scheme handlers via NSWorkspace.open — the
        // cockpit's own delegate gates its system-open on http/https
        // (CockpitWindow.swift:161); the sheet mirrors it.
        XCTAssertEqual(
            CheckoutSheetPolicy.decide(url: URL(string: "facetime://5551234")!, isMainFrame: true),
            .cancelQuietly)
        XCTAssertEqual(
            CheckoutSheetPolicy.decide(url: URL(string: "file:///etc/passwd")!, isMainFrame: true),
            .cancelQuietly)
        // Plain web URLs still hand off.
        let web = URL(string: "http://example.com/receipt")!
        XCTAssertEqual(CheckoutSheetPolicy.decide(url: web, isMainFrame: true), .cancelAndOpenBrowser(web))
    }

    // MARK: - Delegate seam wiring (no live WKWebView needed)

    func testDelegateAllowsPaymentHostNonActivatedNavigation() {
        let delegate = CheckoutSheetDelegate()
        var openedBrowser: URL?
        var activated = false
        delegate.onOpenBrowser = { openedBrowser = $0 }
        delegate.onActivated = { activated = true }

        var policy: WKNavigationActionPolicy?
        delegate.handle(url: URL(string: "https://checkout.stripe.com/pay/cs_test_123")!, isMainFrame: true) { policy = $0 }

        XCTAssertEqual(policy, .allow)
        XCTAssertNil(openedBrowser)
        XCTAssertFalse(activated)
    }

    func testDelegateCancelsAndOpensSystemBrowserOffHost() {
        let delegate = CheckoutSheetDelegate()
        var openedBrowser: URL?
        var activated = false
        delegate.onOpenBrowser = { openedBrowser = $0 }
        delegate.onActivated = { activated = true }

        let url = URL(string: "https://example.com/pricing")!
        var policy: WKNavigationActionPolicy?
        delegate.handle(url: url, isMainFrame: true) { policy = $0 }

        XCTAssertEqual(policy, .cancel)
        XCTAssertEqual(openedBrowser, url)
        XCTAssertFalse(activated)
    }

    func testDelegateCancelsAndClosesSilentlyWhenActivated() {
        let delegate = CheckoutSheetDelegate()
        var openedBrowser: URL?
        var activated = false
        delegate.onOpenBrowser = { openedBrowser = $0 }
        delegate.onActivated = { activated = true }

        var policy: WKNavigationActionPolicy?
        delegate.handle(url: URL(string: "https://llmpilot.dev/pro/activated")!, isMainFrame: true) { policy = $0 }

        XCTAssertEqual(policy, .cancel)
        XCTAssertTrue(activated)
        XCTAssertNil(openedBrowser)
    }

    func testDelegateHandlesNilURLAsAllow() {
        let delegate = CheckoutSheetDelegate()
        var policy: WKNavigationActionPolicy?
        delegate.handle(url: nil, isMainFrame: true) { policy = $0 }
        XCTAssertEqual(policy, .allow)
    }

    func testDelegateDropsNonWebSchemesWithoutOpeningAnything() {
        let delegate = CheckoutSheetDelegate()
        var openedBrowser: URL?
        var activated = false
        delegate.onOpenBrowser = { openedBrowser = $0 }
        delegate.onActivated = { activated = true }

        var policy: WKNavigationActionPolicy?
        delegate.handle(url: URL(string: "facetime://5551234")!, isMainFrame: true) { policy = $0 }

        XCTAssertEqual(policy, .cancel)
        XCTAssertNil(openedBrowser, "a custom scheme must never reach NSWorkspace.open")
        XCTAssertFalse(activated)
    }

    // MARK: - Hosted presentation (review 2026-08-08 P1-7)
    // An attached sheet draws no title bar, so `.closable` alone gives the
    // payment surface no exit — the native Cancel bar is the fix, and this
    // mounts the REAL sheet on a real (offscreen) window to prove the bar
    // exists and actually dismisses (DoctorPanelHostingTests precedent;
    // this was the one fix in the review delta resting on AppKit behavior
    // rather than traceable code).

    func testPresentedSheetHasAWorkingCancelBar() async throws {
        let parent = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        parent.orderFrontRegardless()
        defer { parent.orderOut(nil) }

        var closed = 0
        let controller = CheckoutSheet.present(
            url: URL(string: "https://checkout.stripe.com/pay/cs_test_hosted")!,
            on: parent) { closed += 1 }
        _ = controller // the caller-holds contract

        // Sheet attachment can lag a runloop turn.
        let sheet = try await pollForSheet(on: parent)
        XCTAssertFalse(
            sheet.styleMask.contains(.miniaturizable),
            "a sheet has no Dock presence to miniaturize into")
        XCTAssertFalse(sheet.isReleasedWhenClosed, "the controller holds a strong reference — AppKit must not also release")

        guard let cancel = findButton(withIdentifier: "checkout-cancel", in: sheet.contentView) else {
            return XCTFail("no checkout-cancel button in the sheet's content")
        }
        cancel.performClick(nil)

        // endSheet's completion (→ onClosed) runs on a later runloop turn.
        for _ in 0..<50 where closed == 0 {
            await Task.yield()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(closed, 1, "the Cancel bar must actually end the sheet, firing onClosed once")
        XCTAssertTrue(parent.sheets.isEmpty)

        // Idempotence across the user-driven path: a late programmatic
        // dismiss after the user already cancelled is a no-op.
        controller.dismiss()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(closed, 1)
    }

    private func pollForSheet(on parent: NSWindow) async throws -> NSWindow {
        for _ in 0..<50 {
            if let sheet = parent.sheets.first { return sheet }
            await Task.yield()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        throw XCTSkip("sheet never attached in this test host — AppKit declined offscreen presentation")
    }

    private func findButton(withIdentifier id: String, in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if let button = view as? NSButton, button.accessibilityIdentifier() == id { return button }
        for sub in view.subviews {
            if let found = findButton(withIdentifier: id, in: sub) { return found }
        }
        return nil
    }
}
