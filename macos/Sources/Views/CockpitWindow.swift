import AppKit
import Security
import WebKit

/// The no-card-trial marker: a NATIVE-owned generic-password Keychain item under
/// its OWN service — NEVER dev.llmpilot.entitlement (the daemon must never see or
/// write it; advisor verdict 2026-07-12). Written synchronizable so it rides
/// iCloud Keychain across the user's Macs. It is a BEST-EFFORT effort bar, not an
/// authoritative gate: it raises friction on a normal user repeating the no-card
/// rung across their own Macs, but a determined local user can reset it (the
/// daemon can only self-report it). The no-card rung is the accepted-risk bottom
/// of the ladder (W8-MONEY-PLAN-REVIEW #1). The value is a presence flag, never a
/// credential — no secret is ever stored or reported.
protocol TrialMarkerStore: Sendable {
    func isPresent() -> Bool
    @discardableResult func mark() -> Bool
}

struct KeychainTrialMarker: TrialMarkerStore {
    static let service = "dev.llmpilot.trial-marker"
    static let account = "current"

    func isPresent() -> Bool {
        // SynchronizableAny matches both a synced and a local marker, so one
        // written before the sync entitlement landed still counts.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult func mark() -> Bool {
        if isPresent() { return true }
        // Prefer a synchronizable item (iCloud, cross-Mac). If the write is
        // refused for lack of a keychain-access-groups entitlement, fall back to
        // a local item so the same-Mac friction bar still holds (owner enables
        // sync at signing — a close-out errand, not a blocker).
        for synchronizable in [true, false] {
            let attrs: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: Self.service,
                kSecAttrAccount as String: Self.account,
                kSecUseDataProtectionKeychain as String: true,
                kSecAttrSynchronizable as String: synchronizable,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
                kSecValueData as String: Data([1]),
            ]
            let status = SecItemAdd(attrs as CFDictionary, nil)
            if status == errSecSuccess || status == errSecDuplicateItem { return true }
        }
        return false
    }
}

/// The app owns the cockpit window: a native NSWindow hosting a WKWebView onto
/// the daemon's embedded UI on loopback — never a browser tab. A navigation
/// delegate keeps the checkout handoff OFF this window: the web's off-origin
/// navigation to the checkout URL is cancelled here and handed to the clean
/// CheckoutWindow, so the cockpit's WKWebView never hosts Stripe.
/// Standard behaviors: ⌘W, remembered position. The size is FIXED at the
/// designed 1180×760: the board is a dense 24 h timeline and a shrunken
/// window cuts it into an unmanageable strip (owner call, 2026-07-15).
final class CockpitWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate,
    WKScriptMessageHandler
{
    static let shared = CockpitWindowController()

    private var webView: WKWebView?
    private var origin: (host: String?, port: Int?)?
    private var lastLoaded: URL?
    /// Injectable so tests never touch the real Keychain.
    var trialMarker: TrialMarkerStore = KeychainTrialMarker()
    /// Injectable so the bridge wiring is testable without a webview.
    var openLogin: () -> Void = { LoginWindowController.shared.open() }

    /// On screen AND at least partially unoccluded. Cooperative activation
    /// can refuse to surface a window (fullscreen Space in front), in which
    /// case isVisible alone still reads true while nobody can see it.
    var isWindowVisible: Bool {
        guard let w = window else { return false }
        return w.isVisible && w.occlusionState.contains(.visible)
    }

    func open(url: URL) {
        origin = (url.host, url.port)
        if window == nil {
            // EditableWindow, not NSWindow: this hosts the cockpit's own
            // paste targets (the add-account code field, the licence
            // recovery field), and the app-wide menu cannot be relied on to
            // deliver ⌘V here — same reasoning as the sign-in window.
            let win = EditableWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered, defer: false)
            win.title = "llmpilot"
            win.setFrameAutosaveName("cockpit")
            // The autosave remembers position AND size; installs that saved a
            // resized frame before the size was fixed must snap back.
            win.setContentSize(NSSize(width: 1180, height: 760))
            win.isReleasedWhenClosed = false
            win.delegate = self
            let config = WKWebViewConfiguration()
            // The cockpit (NOT the checkout window) may host message handlers:
            // the web signals a no-card-trial start so the native marker is
            // set, and Add account opens the seamless native login window
            // instead of the browser+paste fallback.
            config.userContentController.add(self, name: "trialMarker")
            config.userContentController.add(self, name: "startLogin")
            let web = WKWebView(frame: win.contentView!.bounds, configuration: config)
            web.autoresizingMask = [.width, .height]
            web.navigationDelegate = self
            win.contentView?.addSubview(web)
            webView = web
            window = win
            win.center()
        }
        // Reload only when the target moved: a daemon restart changes the
        // port and/or the install-token fragment. Compare the URL we loaded,
        // not webView.url — the SPA strips the fragment via replaceState.
        if lastLoaded != url {
            webView?.load(URLRequest(url: url))
            lastLoaded = url
        }
        // Accessory apps can't bring a window frontmost without becoming a
        // regular app for the duration of the window's life.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in
            self?.window?.orderFrontRegardless()
        }
    }

    /// Payment hosts (Stripe's checkout, our llmpilot.dev host page) go to the
    /// clean checkout window; every other off-origin link opens in the browser.
    static func isPaymentHost(_ host: String?) -> Bool {
        guard let host else { return false }
        return ["stripe.com", "llmpilot.dev"].contains { host == $0 || host.hasSuffix("." + $0) }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        // The cockpit's own loopback origin stays in-window (SPA navigation).
        if url.host == origin?.host, url.port == origin?.port {
            decisionHandler(.allow)
            return
        }
        // Non-web schemes (mailto:, etc.) and every off-origin link leave the
        // window: checkout to the clean window, anything else to the browser.
        decisionHandler(.cancel)
        if url.scheme == "http" || url.scheme == "https", Self.isPaymentHost(url.host) {
            CheckoutWindowController.shared.open(url: url)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        handleScriptMessage(name: message.name, body: message.body)
    }

    /// The delegate's core, split out because WKScriptMessage cannot be
    /// constructed in tests.
    func handleScriptMessage(name: String, body: Any?) {
        switch name {
        case "trialMarker" where (body as? String) == "nocard":
            trialMarker.mark()
        case "startLogin":
            openLogin()
        default:
            break
        }
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

/// The clean checkout window: a SEPARATE NSWindow + WKWebView with NO injected
/// user scripts and NO evaluateJavaScript — Apple Pay / Touch ID die otherwise
/// (webkit.org/blog/9674). navigationDelegate only. The page's OWN inline
/// scripts (Stripe.js) run normally; only APP-injected scripts are forbidden.
/// On reaching /pro/activated the daemon's background poller has completed (or
/// will complete) activation silently, so the window just closes — no key shown.
final class CheckoutWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate {
    static let shared = CheckoutWindowController()
    private var webView: WKWebView?

    func open(url: URL) {
        if window == nil {
            // Card details get pasted here too.
            let win = EditableWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 720),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered, defer: false)
            win.title = "Checkout"
            win.isReleasedWhenClosed = false
            win.delegate = self
            // A bare configuration — no userContentController scripts, ever.
            let web = WKWebView(frame: win.contentView!.bounds, configuration: WKWebViewConfiguration())
            web.autoresizingMask = [.width, .height]
            web.navigationDelegate = self
            win.contentView?.addSubview(web)
            webView = web
            window = win
            win.center()
        }
        webView?.load(URLRequest(url: url))
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if let url = navigationAction.request.url, url.path.hasPrefix("/pro/activated"),
           CockpitWindowController.isPaymentHost(url.host) {
            // Success reached on our own success page — activation completes in
            // the daemon poller; close. Host-checked so a foreign redirect to
            // /pro/activated cannot dismiss the window early.
            decisionHandler(.cancel)
            window?.close()
            return
        }
        decisionHandler(.allow)
    }

    func windowWillClose(_ notification: Notification) {
        webView?.stopLoading()
    }
}
