import AppKit
import SwiftUI
import WebKit

/// The in-app "Sign in with Claude" window: a WKWebView on the official
/// authorize URL whose navigation delegate intercepts the hosted callback —
/// the code rides the URL query, so it is captured before the page renders
/// and the exchange runs in the daemon. A bare configuration, like the
/// checkout window: no injected scripts on a login page, ever. If Anthropic
/// blocks embedded webviews, the bottom bar falls back to browser + paste.
final class LoginWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate {
    static let shared = LoginWindowController()

    private var webView: WKWebView?
    private var model: LoginFlowModel?

    func open(api: DaemonAPI = HTTPDaemonClient()) {
        // Always build a FRESH window + webview per sign-in. A multi-account
        // tool must let you add a second or third account cleanly: a
        // NON-PERSISTENT (ephemeral) data store means each sign-in starts with
        // no cookies, so it never inherits the previous account's login, never
        // touches Safari's session, and leaves nothing on disk. Reusing one
        // webview would carry the first account's cookies into the second add.
        window?.close()
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 680),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        win.title = "Sign in with Claude"
        win.isReleasedWhenClosed = false
        win.delegate = self
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        webView = web
        let m = LoginFlowModel(api: api, openExternal: { NSWorkspace.shared.open($0) })
        m.loadInWeb = { [weak web] url in web?.load(URLRequest(url: url)) }
        m.onFinished = { [weak self, weak win] in
            // Linger on the confirmation, then close; the fleet updates
            // over SSE on its own. Close only the window THIS attempt owns —
            // dereferencing self.window at fire time would close a newer
            // attempt's replacement window opened during the linger.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                guard let self, let win, self.window === win else { return }
                win.close()
            }
        }
        model = m
        // Host SwiftUI as the contentVIEW (not contentViewController):
        // a hosting controller shrinks the window to its fitting size, and
        // the webview has no intrinsic size, so the window collapsed to a
        // tiny blank frame. A pinned content view keeps the 500×680 size.
        let hosting = NSHostingView(rootView: LoginView(model: m, webView: web))
        hosting.frame = NSRect(x: 0, y: 0, width: 500, height: 680)
        hosting.autoresizingMask = [.width, .height]
        win.contentView = hosting
        win.setContentSize(NSSize(width: 500, height: 680))
        window = win
        win.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        Task { @MainActor in await m.start() }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url, let model else {
            decisionHandler(.allow)
            return
        }
        if model.handleNavigation(url) == .intercept {
            decisionHandler(.cancel)
            Task { @MainActor in await model.completePending() }
        } else {
            decisionHandler(.allow)
        }
    }

    func windowWillClose(_ notification: Notification) {
        webView?.stopLoading()
    }
}

/// Hosts the controller-owned webview inside the SwiftUI layout.
private struct LoginWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct LoginView: View {
    @ObservedObject var model: LoginFlowModel
    let webView: WKWebView

    var body: some View {
        content
            .frame(minWidth: 500, minHeight: 620)
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle, .starting:
            centered { ProgressView("Contacting Claude…") }
        case .web:
            VStack(spacing: 0) {
                LoginWebView(webView: webView)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                HStack {
                    Text("Trouble signing in here?")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open in browser instead") { model.openInBrowser() }
                        .font(.system(size: 11))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        case .paste:
            centered {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Approve the sign-in in your browser, then paste the code it shows you.")
                        .font(.system(size: 12))
                    HStack {
                        TextField("Paste code here", text: $model.pasteInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .onSubmit { Task { await model.submitPaste() } }
                        Button("Add account") { Task { await model.submitPaste() } }
                            .disabled(model.pasteInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if let err = model.pasteError {
                        Text(err)
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: 380)
            }
        case .exchanging:
            centered { ProgressView("Adding account…") }
        case .done:
            centered {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 28))
                    Text("Signed in — the account is joining your fleet.")
                        .font(.system(size: 12))
                }
            }
        case .failed(let message):
            centered {
                VStack(spacing: 10) {
                    Text(message)
                        .font(.system(size: 12))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                    HStack {
                        Button("Try again") { Task { await model.retry() } }
                        Button("Open in browser instead") { model.openInBrowser() }
                    }
                }
            }
        }
    }

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack { content() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(20)
    }
}
