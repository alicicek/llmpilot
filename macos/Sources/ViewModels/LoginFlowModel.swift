import Foundation

/// State machine for the in-app "Sign in with Claude" window. The daemon
/// owns the OAuth attempt (PKCE, CSRF table, exchange, credential write);
/// this model only drives the UI legs: load the approval page, intercept the
/// hosted callback (code+state ride its URL query — never scraped from the
/// page), verify the state matches the attempt THIS window started, and fall
/// back to browser+paste ("<code>#<state>", the CLI's own format) if the
/// embedded login is blocked. Codes and tokens never touch logs.
@MainActor
final class LoginFlowModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case starting
        /// The webview is showing the approval page.
        case web(URL)
        /// Browser fallback: the user pastes the code shown after approval.
        case paste
        case exchanging
        case done
        case failed(String)
    }

    enum NavDecision: Equatable {
        case allow
        case intercept
    }

    @Published private(set) var phase: Phase = .idle
    @Published var pasteInput = ""
    @Published private(set) var pasteError: String?

    /// The CSRF state of the attempt this window started; callbacks carrying
    /// any other state are rejected before the daemon is even asked.
    private(set) var expectedState: String?
    private var authorizeURL: URL?
    private var pending: (code: String, state: String)?

    private let api: DaemonAPI
    /// Injectable seams — tests drive the model with no webview or browser.
    var openExternal: (URL) -> Void
    var loadInWeb: (URL) -> Void = { _ in }
    var onFinished: () -> Void = {}

    init(api: DaemonAPI, openExternal: @escaping (URL) -> Void = { _ in }) {
        self.api = api
        self.openExternal = openExternal
    }

    func start() async {
        phase = .starting
        pasteInput = ""
        pasteError = nil
        pending = nil
        do {
            let s = try await api.startLogin()
            guard let url = URL(string: s.authorizeURL) else {
                phase = .failed("The daemon returned an unusable sign-in URL — restart it and try again.")
                return
            }
            expectedState = s.state
            authorizeURL = url
            phase = .web(url)
            loadInWeb(url)
        } catch {
            phase = .failed(message(for: error))
        }
    }

    /// True for Anthropic's hosted callback — the URL whose query carries the
    /// code. Everything else (the login page itself, its redirects) loads.
    /// HTTPS is pinned so a plaintext downgrade of the callback host never
    /// reaches the interception path (the state check is the real backstop).
    nonisolated static func isCallback(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "platform.claude.com"
            && url.path.hasPrefix("/oauth/code/callback")
    }

    /// Feed every navigation URL here; .intercept means cancel the load (the
    /// callback never renders) and call completePending().
    func handleNavigation(_ url: URL) -> NavDecision {
        guard Self.isCallback(url) else { return .allow }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first(where: { $0.name == name })?.value }
        if let err = value("error"), !err.isEmpty {
            phase = .failed("Claude refused the sign-in (\(err)). Try again.")
            return .intercept
        }
        guard let code = value("code"), !code.isEmpty,
              let state = value("state"), !state.isEmpty
        else {
            phase = .failed("The sign-in came back without a code — try again.")
            return .intercept
        }
        guard state == expectedState else {
            phase = .failed("The sign-in belongs to a different attempt than this window started — try again.")
            return .intercept
        }
        pending = (code, state)
        phase = .exchanging
        return .intercept
    }

    /// Exchange the intercepted code via the daemon. Separate from
    /// handleNavigation so the (synchronous) navigation delegate can decide
    /// first and await the exchange after.
    func completePending() async {
        guard let p = pending else { return }
        pending = nil
        await complete(code: p.code, state: p.state)
    }

    /// Browser fallback: open the approval page externally, collect a paste.
    func openInBrowser() {
        guard let url = authorizeURL else { return }
        openExternal(url)
        pasteError = nil
        phase = .paste
    }

    func submitPaste() async {
        let raw = pasteInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = raw.split(separator: "#", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            pasteError = "That's not the full code — copy everything shown, including the part after #."
            return
        }
        pasteError = nil
        phase = .exchanging
        await complete(code: parts[0], state: parts[1])
    }

    func retry() async {
        await start()
    }

    private func complete(code: String, state: String) async {
        do {
            try await api.completeLogin(code: code, state: state)
            phase = .done
            onFinished()
        } catch {
            phase = .failed(message(for: error))
        }
    }

    private func message(for error: Error) -> String {
        if let e = error as? DaemonError, case .down = e {
            return "The llmpilot daemon isn't reachable — open the menu bar app, then try again."
        }
        return error.localizedDescription
    }
}
