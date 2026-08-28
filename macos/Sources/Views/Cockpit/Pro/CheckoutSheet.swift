import AppKit
import WebKit

/// The canonical exact-suffix payment-host check (stripe.com / llmpilot.dev).
/// Chunk 6A cutover: CockpitWindowController — the interim web-cockpit
/// window this was originally duplicated from, pre-cutover — is gone, so
/// this is now the only copy.
enum CheckoutHost {
    static func isPaymentHost(_ host: String?) -> Bool {
        guard let host else { return false }
        return ["stripe.com", "llmpilot.dev"].contains { host == $0 || host.hasSuffix("." + $0) }
    }
}

/// What a checkout-sheet navigation should do, decided BEFORE any WebKit
/// call — a pure function of the URL so it is testable without a live
/// WKNavigationAction (WebKit doesn't let tests construct one).
enum CheckoutSheetDecision: Equatable {
    case allow
    case cancelAndOpenBrowser(URL)
    case cancelAndClose
    /// The hosted session's cancel_url chain ended on /pro/declined (1.3.4
    /// fallback sheet): the back-out is already recorded — the recording hop
    /// (api.llmpilot.dev/checkout/declined, a payment host) was ALLOWED
    /// through so the worker write happened before this redirect — and the
    /// sheet just closes. The decider (`CheckoutDecider.watch`) reads the
    /// verdict from the daemon; nothing is decided here.
    case cancelAndCloseDeclined
    /// Blocked without a hand-off: non-web schemes never reach
    /// NSWorkspace.open from payment content (mirrors the retired
    /// web-cockpit delegate's http/https gate on its own system-open path).
    case cancelQuietly
}

enum CheckoutSheetPolicy {
    /// Mirrors the retired CheckoutWindowController's /pro/activated → close
    /// rule, and adds the sheet's own off-payment-host → system-browser rule
    /// per the Phase 4 chunk D brief (the retired controller just allowed
    /// every non-activated navigation; the sheet is stricter because it has
    /// no separate top-level window chrome to signal "you've left checkout").
    ///
    /// MAIN-FRAME ONLY: Stripe's embedded checkout composes the page from
    /// sub-frames on hosts OUTSIDE the payment-host list (b.stripecdn.com
    /// captcha frames, m.stripe.network card fields) — treating those iframe
    /// loads as "leaving checkout" bounced every one of them to the system
    /// browser as a tab (owner hit four at once, 2026-08-08). Sub-frame
    /// content is allowed unconditionally: it renders INSIDE the page and
    /// can neither take the user off checkout nor dismiss the sheet (the
    /// activated-close is main-frame-gated for the same reason — an iframe
    /// must not be able to end the payment surface).
    static func decide(url: URL?, isMainFrame: Bool) -> CheckoutSheetDecision {
        guard let url else { return .allow }
        guard isMainFrame else { return .allow }
        let onPaymentHost = CheckoutHost.isPaymentHost(url.host)
        // Path-SEGMENT match, not a bare prefix: "/pro/activatedxyz" must
        // not dismiss the sheet (review 2026-08-08 P2-11).
        let path = url.path
        if onPaymentHost, path == "/pro/activated" || path.hasPrefix("/pro/activated/") {
            // Host-checked so a foreign redirect to /pro/activated cannot
            // dismiss the sheet early — same guard as the retired controller.
            return .cancelAndClose
        }
        // Same path-segment discipline for the declined landing (1.3.4): the
        // recording hop before it (/checkout/declined on the API host) falls
        // through to the payment-host allow below — cancelling THAT request
        // would eat the back-out signal.
        if onPaymentHost, path == "/pro/declined" || path.hasPrefix("/pro/declined/") {
            return .cancelAndCloseDeclined
        }
        if onPaymentHost {
            return .allow
        }
        // Only real web URLs leave for the system browser — the retired
        // cockpit delegate gated its system-open on http/https the same way;
        // anything else from payment content (custom schemes, file:, etc.)
        // is dropped without a hand-off (review 2026-08-08 P2-11).
        if url.scheme == "http" || url.scheme == "https" {
            return .cancelAndOpenBrowser(url)
        }
        return .cancelQuietly
    }
}

/// The navigation delegate's core, split out from the WKNavigationDelegate
/// method for the same reason CockpitWindowController splits out
/// handleScriptMessage (CockpitWindow.swift:174-176): the WebKit type
/// (WKNavigationAction there, here too) cannot be constructed in tests, so
/// the decision + seam wiring lives in a plain method tests can call
/// directly with just a URL and a decision-handler closure.
final class CheckoutSheetDelegate: NSObject, WKNavigationDelegate {
    /// Off-payment-host navigations leave the sheet for the system browser.
    var onOpenBrowser: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// Fires once, when a payment host serves /pro/activated. The daemon's
    /// background poll (internal/daemon/license.go activationPoll) completes
    /// the actual activation; this only closes the sheet.
    var onActivated: () -> Void = {}
    /// Fires when the cancel_url chain lands on /pro/declined — the back-out
    /// is recorded by then; this only closes the sheet.
    var onDeclined: () -> Void = {}

    func handle(url: URL?, isMainFrame: Bool, decisionHandler: (WKNavigationActionPolicy) -> Void) {
        switch CheckoutSheetPolicy.decide(url: url, isMainFrame: isMainFrame) {
        case .allow:
            decisionHandler(.allow)
        case .cancelAndOpenBrowser(let openURL):
            decisionHandler(.cancel)
            onOpenBrowser(openURL)
        case .cancelAndClose:
            decisionHandler(.cancel)
            onActivated()
        case .cancelAndCloseDeclined:
            decisionHandler(.cancel)
            onDeclined()
        case .cancelQuietly:
            decisionHandler(.cancel)
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // A nil targetFrame is a new-window request (target="_blank" links,
        // e.g. Stripe's terms links) — main-frame rules apply, which routes
        // real links to the system browser instead of nowhere.
        handle(
            url: navigationAction.request.url,
            isMainFrame: navigationAction.targetFrame?.isMainFrame ?? true,
            decisionHandler: decisionHandler)
    }
}

/// Presents the existing native checkout surface as a SHEET on a caller-
/// supplied window (Phase 4 chunk D: the native paywall/ladder calling into
/// checkout without popping a whole separate top-level window).
///
/// Every Apple-Pay and security constraint from CheckoutWindowController
/// (CockpitWindow.swift:200-254) carries over unchanged:
///  - `WKWebViewConfiguration()` is BARE — zero handlers, zero injected user
///    scripts, ever. Apple Pay / Touch ID die otherwise:
///    https://webkit.org/blog/9674. The page's own inline scripts (Stripe.js)
///    still run fine; only APP-injected scripts are forbidden.
///  - isPaymentHost is the same exact-suffix host check (CheckoutHost, kept
///    in sync with CockpitWindow.swift:141-144 by comment).
///  - Reaching /pro/activated on a payment host cancels the navigation and
///    closes the sheet silently — no key is ever shown here; activation
///    completes via the daemon's background poll
///    (internal/daemon/license.go handleLicenseCheckout/activationPoll).
///
/// Deliberately does NOT touch NSApp.setActivationPolicy. CockpitWindowController
/// and CheckoutWindowController each flip accessory↔regular because each is a
/// free-standing top-level window with its own show/close lifecycle (CockpitWindow
/// .swift:129-133, and the reciprocal windowWillClose guards at 187-197). A sheet
/// has no independent lifecycle: it rides its parent window's frontmost/activation
/// state for as long as it is attached, and the parent already owns (or doesn't
/// need) that flip. Duplicating it here would be redundant at best and could race
/// the parent's own close-driven demotion at worst.
final class CheckoutSheetController: NSObject {
    private var webView: WKWebView?
    private var sheetWindow: NSWindow?
    private weak var parent: NSWindow?
    private var onClosed: (() -> Void)?
    private let delegate = CheckoutSheetDelegate()

    /// The caller MUST hold the returned controller for as long as the sheet
    /// may be showing: WKWebView.navigationDelegate is a weak reference, and
    /// this controller is the only strong owner of the delegate instance.
    @discardableResult
    static func present(url: URL, on parent: NSWindow, onClosed: @escaping () -> Void) -> CheckoutSheetController {
        let controller = CheckoutSheetController()
        controller.present(url: url, on: parent, onClosed: onClosed)
        return controller
    }

    private func present(url: URL, on parent: NSWindow, onClosed: @escaping () -> Void) {
        self.parent = parent
        self.onClosed = onClosed

        // Card details get pasted here too (same reasoning as
        // CheckoutWindowController — CockpitWindow.swift:212). Not
        // miniaturizable: a sheet has no independent Dock presence.
        let sheet = EditableWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 720),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        sheet.title = "Checkout"
        // The controller keeps a strong `sheetWindow` reference, so AppKit
        // must not also release-on-close — same explicit opt-out
        // CheckoutWindowController sets (review 2026-08-08 P1-7: any
        // close()/performClose: path was the classic ARC over-release, on
        // the payment window).
        sheet.isReleasedWhenClosed = false

        // An attached sheet never draws its title bar, so `.closable` alone
        // yields NO visible exit — a window-modal payment surface with no
        // way out (review 2026-08-08 P1-7; the free-standing
        // CheckoutWindowController it replaces had real window chrome). A
        // native Cancel bar above the webview restores the exit; it is
        // app chrome, not page content — the WKWebViewConfiguration below
        // stays bare.
        let bar = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        let cancel = NSButton(
            title: "Cancel", target: self, action: #selector(cancelPressed))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}" // Escape
        cancel.setAccessibilityIdentifier("checkout-cancel")
        cancel.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(cancel)

        // A bare configuration — no userContentController scripts, ever.
        let web = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        web.translatesAutoresizingMaskIntoConstraints = false
        web.navigationDelegate = delegate

        let content = sheet.contentView!
        content.addSubview(bar)
        content.addSubview(web)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 40),
            cancel.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 12),
            cancel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            web.topAnchor.constraint(equalTo: bar.bottomAnchor),
            web.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            web.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        webView = web
        sheetWindow = sheet

        delegate.onOpenBrowser = { NSWorkspace.shared.open($0) }
        delegate.onActivated = { [weak self] in self?.dismiss() }
        delegate.onDeclined = { [weak self] in self?.dismiss() }

        web.load(URLRequest(url: url))
        parent.beginSheet(sheet) { [weak self] _ in
            self?.cleanupAfterEndSheet()
        }
    }

    /// The Cancel bar's action — the user-driven dismissal path.
    @objc private func cancelPressed() {
        dismiss()
    }

    /// Ends the sheet from code — the activated-close path above, and the
    /// ask machine's "start again here" path (swap in a fresh checkout by
    /// dismissing whatever sheet is already up first). Idempotent: a second
    /// call, or a call after the user already closed the sheet via its own
    /// close button, is a no-op. onClosed fires exactly once, from
    /// cleanupAfterEndSheet, on ANY dismissal path.
    func dismiss() {
        guard let sheetWindow, let parent, parent.sheets.contains(sheetWindow) else { return }
        parent.endSheet(sheetWindow)
    }

    /// NSWindow.beginSheet's completion handler runs on every dismissal —
    /// our own endSheet(_:) call above, AND the user closing the sheet via
    /// its titlebar close button (NSWindow.close() on an attached sheet is
    /// equivalent to endSheet(_:)) — so this is the single place that tears
    /// the webview down and fires onClosed, never leaving a dangling webview.
    private func cleanupAfterEndSheet() {
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        webView = nil
        sheetWindow = nil
        let closed = onClosed
        onClosed = nil
        closed?()
    }
}

/// Presentation entry point for the paywall/ladder chunk.
enum CheckoutSheet {
    /// onClosed fires on ANY dismissal — activated or user-cancelled — so
    /// the ask machine can clear its handoffURL state without caring which.
    @discardableResult
    static func present(url: URL, on window: NSWindow, onClosed: @escaping () -> Void) -> CheckoutSheetController {
        CheckoutSheetController.present(url: url, on: window, onClosed: onClosed)
    }
}
