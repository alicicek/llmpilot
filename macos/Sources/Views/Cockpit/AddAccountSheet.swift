import AppKit
import SwiftUI

// Native port of web/src/shell/AddAccountDialog.tsx — three zero-terminal
// "Sign in with Claude" paths (zero-paste browser, in-app window, terminal
// fallback) plus the "already signed in on this Mac" detected-dirs section
// (adopt-as-watched / move-into-fleet, two-click confirm).
//
// Native ALWAYS has the in-app login bridge (LoginWindowController's own
// WKWebView) — the web's plain-browser fallback for "Sign in in this
// window" (the hosted-callback + paste-code phases, AddAccountDialog.tsx:
// 321-340) exists only for a browser tab with no native bridge, so it is
// deliberately NOT ported here: `windowSignIn()` always takes the bridge
// branch (close the sheet, open the in-app window).

/// Copy pinned verbatim against AddAccountDialog.tsx so a future edit to
/// either side is a one-line diff, not a silent drift.
enum AddAccountCopy {
    // MARK: sheet chrome (AddAccountDialog.tsx:368, 434-458)
    static let title = "Add account"
    static let intro = "Sign in with your Claude account and it joins the fleet — no terminal needed."
    // "(faster)" carries what the deleted helper paragraph used to say
    // (owner 2026-08-12: the explainer read as noise; the label states the
    // one fact that matters).
    static let browserButton = "Sign in with your browser (faster)"
    static let browserButtonStarting = "Starting…"
    static let windowButton = "Sign in in this window"

    // MARK: browserWait (AddAccountDialog.tsx:382-401)
    static let browserWaitBody =
        "Finish signing in in your browser — your password manager works there. This updates " +
        "on its own the moment you're done."
    static let reopenBrowser = "Reopen browser"
    static let cancel = "Cancel"

    // MARK: done (AddAccountDialog.tsx:378-381)
    static let done = "Signed in — the account is joining your fleet now."

    // MARK: errors (AddAccountDialog.tsx:284, 295)
    static let signInFailedFallback = "Sign-in failed — try again."
    static let pollTimeout = "Didn't detect a completed sign-in — finish it in your browser, or try again."
    // F8 (2026-08-16 fresh-user audit): the token-endpoint 429 on sign-in
    // start read as an unrecoverable dead end — same primary button, no
    // stated wait. States what happened and how long to wait.
    static let rateLimitedSignIn = "The sign-in server is rate-limited — wait a minute, then try again."
    // VOICE.md: verb+object — replaces the default browser-button label
    // while a rate-limited error is showing, so the retry path is explicit.
    static let tryAgain = "Try again"

    // (The "Prefer the terminal?" fallback block was removed 2026-08-12 —
    // owner: users should never be pointed at the CLI, and its disclosure
    // chevron was the sheet's confusing third Tab stop.)

    // MARK: detected section (AddAccountDialog.tsx:121-224)
    static let detectedHeader = "Already signed in on this Mac"
    static let moved = "Already moved into the fleet."
    static let registeredElsewhere =
        "A second folder for an account llmpilot already watches. One account means one " +
        "limit, so adding this folder would add no headroom."
    // No CLI in the remedy (owner 2026-08-12) — the sheet's own sign-in IS
    // the remedy, offered as a button on the row.
    static let signedOut =
        "Signed out — this folder remembers the account, but its sign-in is gone."
    static let signInAgain = "Sign in again"
    static let unregisteredSub =
        "Add as watched keeps its usage visible without ever switching to it. Move into the " +
        "fleet makes it switchable."
    static let registeredSub =
        "llmpilot already knows this account. Moving this copy leaves one sign-in — it won't " +
        "refresh the account while two exist."
    static let addAsWatched = "Add as watched"
    static let adding = "Adding…"
    static let moveIntoFleet = "Move into the fleet"
    static let moveConfirm = "Move it — confirm"
    static let moving = "Moving…"
    static let cloneSuspectFallback =
        "A second copy of this sign-in may still exist — llmpilot will not switch to it until that's resolved."

    static func moveWarning(_ configDir: String) -> String {
        "The sign-in leaves \(configDir) — a terminal using that folder will need to sign in again."
    }
}

/// Per-row classification (AddAccountDialog.tsx:130-201), pulled out as a
/// pure function so it is independently testable against a classification
/// table. Order matters: `moved` wins over everything, then the confirmed-
/// empty (`signed_in == false`) branch, then the normal adopt/move branch.
enum DetectedRowClass: Equatable {
    case moved
    /// signed_in == false AND the account is already watched from another
    /// folder — telling this folder to "sign in again" would be wrong, the
    /// account is live elsewhere (AddAccountDialog.tsx:146-150).
    case registeredElsewhere
    /// signed_in == false and the account is not watched anywhere else.
    case signedOut
    case unregistered
    /// Registered (pinned) but not yet moved — keeps the migration verb
    /// only (AddAccountDialog.tsx:161-163, 166).
    case registered
}

/// Native port of AddAccountDialog.tsx's Phase — "awaiting"/"completing"
/// never apply here (see the file header): native always has the bridge.
enum AddAccountPhase: Equatable {
    case idle
    case starting
    case browserWait
    case done
}

@MainActor
final class AddAccountModel: ObservableObject {
    struct RowBusy: Equatable {
        enum Action: Equatable { case adopt, move }
        let dir: String
        let action: Action
    }

    @Published private(set) var phase: AddAccountPhase = .idle
    @Published var error: String?
    /// F8: set alongside `error` when the current `error` is specifically
    /// the sign-in server's 429 — drives `browserButtonTitle`'s retry copy
    /// while (and only while) that error is showing.
    @Published private(set) var signInRateLimited = false
    @Published private(set) var detected: [DetectedDir] = []
    @Published private(set) var rowBusy: RowBusy?
    @Published var rowError: String?
    @Published private(set) var confirmMove: String?
    @Published private(set) var moveNotes: [String: String] = [:]

    /// The fleet's own config dir — never listed (AddAccountDialog.tsx:78)
    /// — and every email the fleet already watches. Set by the integrator
    /// from the live daemon state before/while the sheet is open.
    var fleetDir: String
    var fleetEmails: [String]

    private let api: CockpitDaemonAPI & DaemonAPI

    // MARK: - injectable seams (tests: virtual clock, no real webview/pasteboard)

    /// Wall clock for the poll-loop timeout; a test fake drives it without
    /// real waits.
    var now: () -> Date = Date.init
    /// Sleeps `seconds`; the default really sleeps. A test fake can advance
    /// a virtual clock and return instantly.
    var sleep: (TimeInterval) async -> Void = { seconds in
        try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
    }
    var openExternal: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// Wired by the integrator to `LoginWindowController.shared.open()`.
    var openLoginWindow: () -> Void = {}
    /// Wired by the integrator to flip the sheet's `open` binding to false.
    var onRequestClose: () -> Void = {}

    /// Poll every 2s (AddAccountDialog.tsx:293,299).
    var pollInterval: TimeInterval = 2
    /// Self-timeout at 5 minutes — deliberately shorter than the daemon's
    /// 10-minute attempt TTL (AddAccountDialog.tsx:292; internal/daemon/
    /// login.go loginAttemptTTL).
    var pollTimeout: TimeInterval = 5 * 60
    /// Linger on "done" before auto-closing (AddAccountDialog.tsx:280).
    var doneLingerDelay: TimeInterval = 1.2
    /// Move-confirm auto-disarm — same precedent as StashPanelModel's
    /// discard confirm (native analog of the web's onBlur reset).
    var confirmResetDelay: TimeInterval = 3
    private var attemptID = ""
    private var authorizeURL: URL?
    /// The cancellable browser sign-in + poll sequence — cancelling this is
    /// what "closing/Cancel stops the poll" means.
    private var signInTask: Task<Void, Never>?
    private var confirmResetTask: Task<Void, Never>?

    init(api: CockpitDaemonAPI & DaemonAPI, fleetDir: String = "", fleetEmails: [String] = []) {
        self.api = api
        self.fleetDir = fleetDir
        self.fleetEmails = fleetEmails
    }

    // MARK: - lifecycle (sheet open/close)

    /// Call when the sheet's `open` binding flips to true — the web
    /// refetches detected dirs on every open (AddAccountDialog.tsx:260-262,
    /// a shipped bug fix for a list that only ever loaded once).
    func opened() {
        Task { await self.refreshDetected() }
    }

    /// Call when the sheet's `open` binding flips to false. Mirrors
    /// AddAccountDialog.tsx's `reset()` (phase/url/error) PLUS the
    /// detected-row local state: in the web, DetectedSection is a child
    /// component that unmounts with the rest of the dialog tree when Radix
    /// Dialog.Content stops rendering, discarding its `useState` — a
    /// persistent native model must clear that state explicitly to match.
    func closed() {
        signInTask?.cancel()
        signInTask = nil
        reset()
        clearDetectedRowState()
        // The web's DetectedSection unmounts with the dialog, so a re-open
        // starts EMPTY until the refetch lands — a persistent native model
        // must drop the old rows too, or the first frame renders stale rows
        // against the next open's fleetDir/fleetEmails snapshot.
        detected = []
    }

    private func reset() {
        phase = .idle
        authorizeURL = nil
        error = nil
        signInRateLimited = false
    }

    /// F8: the primary browser sign-in button's title — a pure function of
    /// phase plus whether the error currently showing is a rate-limited
    /// sign-in, mirroring `PriceBottomControl.resolve`'s style (pulled out
    /// so it's testable without rendering).
    var browserButtonTitle: String {
        if phase == .starting { return AddAccountCopy.browserButtonStarting }
        return signInRateLimited ? AddAccountCopy.tryAgain : AddAccountCopy.browserButton
    }

    private func clearDetectedRowState() {
        confirmResetTask?.cancel()
        confirmResetTask = nil
        rowBusy = nil
        rowError = nil
        confirmMove = nil
        moveNotes = [:]
    }

    // MARK: - detected dirs (AddAccountDialog.tsx:50-225)

    func refreshDetected() async {
        detected = (try? await api.detect()) ?? []
    }

    /// AddAccountDialog.tsx:78 — every folder except the fleet's own slot.
    var candidates: [DetectedDir] {
        detected.filter { $0.configDir != fleetDir }
    }

    /// AddAccountDialog.tsx:83 — the section (and its outcome notes) only
    /// disappears once there is nothing left to show.
    var isDetectedSectionEmpty: Bool {
        candidates.isEmpty && moveNotes.isEmpty
    }

    static func classify(_ d: DetectedDir, fleetEmails: [String]) -> DetectedRowClass {
        if d.moved { return .moved }
        if d.signedIn == false {
            // Case-folded: .claude.json can hold "Alex@Example.dev" for an
            // account the fleet knows as "alex@example.dev"
            // (AddAccountDialog.tsx:142-145).
            let inFleet = fleetEmails.contains { $0.caseInsensitiveCompare(d.email) == .orderedSame }
            return inFleet ? .registeredElsewhere : .signedOut
        }
        return d.registered ? .registered : .unregistered
    }

    /// AddAccountDialog.tsx:85-92 `runAdopt` — `disabled={busy !== null}`
    /// blocks EVERY row while any one row's action is in flight.
    func adoptRow(_ dir: String) {
        guard rowBusy == nil else { return }
        rowBusy = RowBusy(dir: dir, action: .adopt)
        rowError = nil
        Task {
            do {
                try await self.api.adopt(configDir: dir)
                await self.refreshDetected()
            } catch {
                self.rowError = error.localizedDescription
            }
            self.rowBusy = nil
        }
    }

    /// The two-click confirm (AddAccountDialog.tsx:175-192): first click
    /// arms it, second click (while still armed for THIS dir) fires the
    /// move.
    func requestMove(_ dir: String) {
        guard rowBusy == nil else { return }
        if confirmMove == dir {
            confirmResetTask?.cancel()
            confirmMove = nil
            runMove(dir)
        } else {
            confirmMove = dir
            scheduleConfirmReset(for: dir)
        }
    }

    /// Disarms an armed move confirm — the timeout below calls this in
    /// production; tests call it directly for the web's `onBlur` equivalent
    /// (AddAccountDialog.tsx:184, StashPanelModel's `resetConfirm`
    /// precedent).
    func resetMoveConfirm(for dir: String) {
        guard confirmMove == dir else { return }
        confirmResetTask?.cancel()
        confirmMove = nil
    }

    private func scheduleConfirmReset(for dir: String) {
        confirmResetTask?.cancel()
        let delay = confirmResetDelay
        confirmResetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(delay, 0) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.resetMoveConfirm(for: dir)
        }
    }

    private func runMove(_ dir: String) {
        rowBusy = RowBusy(dir: dir, action: .move)
        rowError = nil
        Task {
            do {
                let res = try await self.api.adoptMove(configDir: dir, label: nil)
                if res.outcome == "clone_suspect" {
                    self.moveNotes[dir] = res.note.isEmpty ? AddAccountCopy.cloneSuspectFallback : res.note
                } else {
                    // A later clean move of the same dir resolves the
                    // earlier warning — a note that is no longer true must
                    // not linger (AddAccountDialog.tsx:106-109).
                    self.moveNotes.removeValue(forKey: dir)
                }
                await self.refreshDetected()
            } catch {
                self.rowError = error.localizedDescription
            }
            self.rowBusy = nil
        }
    }

    // MARK: - sign-in paths

    /// Button-facing entry point for the zero-paste browser flow — launches
    /// the cancellable sign-in + poll sequence. Tests call
    /// `runBrowserSignIn()` directly for a single awaitable chain with no
    /// detached Task (AddAccountDialog.tsx:306-319).
    func browserSignIn() {
        guard phase == .idle else { return }
        signInTask?.cancel()
        signInTask = Task { [weak self] in
            await self?.runBrowserSignIn()
        }
    }

    func runBrowserSignIn() async {
        // closed() may have cancelled us before this body even ran (its
        // reset() already put phase back to .idle) — don't resurrect
        // .starting on a sign-in the user already abandoned.
        guard !Task.isCancelled else { return }
        clearDetectedRowState()
        error = nil
        signInRateLimited = false
        phase = .starting
        do {
            let s = try await api.startBrowserLogin()
            // The sheet may have closed while the start call was in flight —
            // opening a browser tab the user gave up on (and parking phase
            // at .starting/.browserWait for the next open) would be pure
            // confusion.
            guard !Task.isCancelled else { phase = .idle; return }
            attemptID = s.attemptID
            let url = URL(string: s.authorizeURL)
            authorizeURL = url
            if let url { openExternal(url) }
            phase = .browserWait
            await pollLoop(id: s.attemptID, startedAt: now())
        } catch {
            if Task.isCancelled { return }
            self.error = message(for: error)
            self.signInRateLimited = Self.isRateLimited(error)
            phase = .idle
        }
    }

    /// F8: true for the daemon's 429 on the sign-in start call itself; the
    /// poll's "failed" status carries its own `code == "rate_limited"` for
    /// the exchange 429 (the audit's actual case). A poll timeout or any
    /// other failure resets the flag.
    private static func isRateLimited(_ error: Error) -> Bool {
        if let e = error as? DaemonError, case .http(429, _) = e { return true }
        return false
    }

    /// Mirrors AddAccountDialog.tsx:268-304's polling effect: an initial
    /// 2s delay, then fetch, then either schedule the next 2s tick or (past
    /// the self-timeout) surface the timeout copy. Transient fetch errors
    /// are swallowed — the poll keeps going.
    private func pollLoop(id: String, startedAt: Date) async {
        while true {
            await sleep(pollInterval)
            if Task.isCancelled { return }
            do {
                let s = try await api.browserLoginStatus(attempt: id)
                if Task.isCancelled { return }
                if s.status == "done" {
                    phase = .done
                    await sleep(doneLingerDelay)
                    if !Task.isCancelled { onRequestClose() }
                    return
                }
                if s.status == "failed" {
                    let msg = s.error
                    error = (msg?.isEmpty == false) ? msg! : AddAccountCopy.signInFailedFallback
                    // The REAL exchange 429 arrives here, not on the start
                    // call: /v1/login/browser succeeds, the code exchange
                    // fails later, and the status poll carries the outcome
                    // with a stable failure code (found in review —
                    // this branch used to clear the flag unconditionally,
                    // so Try again never showed for an actual 429).
                    signInRateLimited = s.code == "rate_limited"
                    phase = .idle
                    return
                }
            } catch {
                // transient (daemon busy) — keep polling.
            }
            if Task.isCancelled { return }
            if now().timeIntervalSince(startedAt) >= pollTimeout {
                error = AddAccountCopy.pollTimeout
                signInRateLimited = false
                phase = .idle
                return
            }
        }
    }

    func reopenBrowser() {
        guard let url = authorizeURL else { return }
        openExternal(url)
    }

    /// Cancel button in browserWait (AddAccountDialog.tsx:396-400) — the
    /// same `reset()` the dialog-close path uses.
    func cancelBrowserWait() {
        signInTask?.cancel()
        signInTask = nil
        reset()
    }

    /// Native always has the in-app login bridge, so this is always the
    /// "close the sheet + open the in-app window" branch
    /// (AddAccountDialog.tsx:321-328). The web's non-bridge fallback (the
    /// hosted-callback + paste flow, :329-340) never applies natively —
    /// there is no plain-browser cockpit surface to fall back through.
    func windowSignIn() {
        clearDetectedRowState()
        openLoginWindow()
        onRequestClose()
    }

    private func message(for error: Error) -> String {
        if let e = error as? DaemonError {
            if case .down = e {
                return "The llmpilot daemon isn't reachable — open the menu bar app, then try again."
            }
            // F8: states what happened and the wait, instead of whatever
            // raw text rode the 429 up from the token endpoint.
            if case .http(429, _) = e {
                return AddAccountCopy.rateLimitedSignIn
            }
        }
        return error.localizedDescription
    }
}

// MARK: - view

struct AddAccountSheet: View {
    @ObservedObject var model: AddAccountModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(AddAccountCopy.title)
                .font(.system(size: 15, weight: .bold))
            if model.phase == .idle {
                AddAccountDetectedSection(model: model)
            }
            phaseBody
            if let error = model.error {
                CockpitWarnBox {
                    Text(error).font(.system(size: 11)).foregroundColor(CockpitTheme.warn)
                }
            }
        }
        // No root padding/frame: SheetChrome (NativeCockpitWindow.swift) is
        // the single inset owner for every cockpit sheet — the old
        // `.padding(20)` here inside the wrapper's own ring read 36pt on
        // the top/left against 16pt under Close (owner 2026-08-13).
        .onAppear { model.opened() }
        .onDisappear { model.closed() }
    }

    @ViewBuilder
    private var phaseBody: some View {
        switch model.phase {
        case .done:
            Text(AddAccountCopy.done)
                .font(.system(size: 12))
                .foregroundColor(CockpitTheme.sec)
        case .browserWait:
            VStack(alignment: .leading, spacing: 8) {
                Text(AddAccountCopy.browserWaitBody)
                    .font(.system(size: 12))
                    .foregroundColor(CockpitTheme.sec)
                HStack(spacing: 8) {
                    Button(AddAccountCopy.reopenBrowser) { model.reopenBrowser() }
                        .buttonStyle(.plain)
                        .foregroundColor(CockpitTheme.sec)
                        .accessibilityIdentifier("add-account-reopen-browser")
                        .accessibilityLabel(AddAccountCopy.reopenBrowser)
                    Button(AddAccountCopy.cancel) { model.cancelBrowserWait() }
                        .buttonStyle(.plain)
                        .foregroundColor(CockpitTheme.ter)
                        .accessibilityIdentifier("add-account-cancel")
                        .accessibilityLabel(AddAccountCopy.cancel)
                }
            }
        case .idle, .starting:
            VStack(alignment: .leading, spacing: 8) {
                Text(AddAccountCopy.intro)
                    .font(.system(size: 12))
                    .foregroundColor(CockpitTheme.sec)
                VStack(alignment: .leading, spacing: 8) {
                    Button(action: { model.browserSignIn() }) {
                        Text(model.browserButtonTitle)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            // actionFill, not accTx (owner 2026-08-12): accTx
                            // is the light text-safe blue — white on it fails
                            // contrast and it didn't match the corridor's
                            // primary CTA, which moved to actionFill on
                            // 2026-08-09. One blue for every primary action.
                            .background(CockpitTheme.actionFill)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .opacity(model.phase == .starting ? 0.5 : 1)
                    .disabled(model.phase == .starting)
                    .accessibilityIdentifier("add-account-browser-signin")
                    .accessibilityLabel(model.browserButtonTitle)

                    Button(action: { model.windowSignIn() }) {
                        Text(AddAccountCopy.windowButton)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundColor(CockpitTheme.sec)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(CockpitTheme.hair, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .opacity(model.phase == .starting ? 0.5 : 1)
                    .disabled(model.phase == .starting)
                    .accessibilityIdentifier("add-account-window-signin")
                    .accessibilityLabel(AddAccountCopy.windowButton)
                }
            }
        }
    }

}

/// AddAccountDialog.tsx:50-225's DetectedSection — the "already signed in
/// on this Mac" list.
private struct AddAccountDetectedSection: View {
    @ObservedObject var model: AddAccountModel

    var body: some View {
        if model.isDetectedSectionEmpty {
            EmptyView()
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(AddAccountCopy.detectedHeader)
                .font(.system(size: 11.5, weight: .bold))
            if !model.candidates.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(model.candidates.enumerated()), id: \.element.id) { idx, dir in
                        AddAccountDetectedRow(dir: dir, model: model)
                        if idx != model.candidates.count - 1 {
                            Divider().overlay(CockpitTheme.hairSoft)
                        }
                    }
                }
            }
            // Outcome notes live at SECTION level, not the row: a completed
            // move drops its dir from `candidates`, and a warning tied to
            // the row would vanish with it — a partial retirement reported
            // as success (AddAccountDialog.tsx:206-209). Sorted for a
            // stable render order (Dictionary has none).
            ForEach(model.moveNotes.keys.sorted(), id: \.self) { dir in
                if let note = model.moveNotes[dir] {
                    CockpitWarnBox {
                        Text(note).font(.system(size: 10.5)).foregroundColor(CockpitTheme.warn)
                    }
                }
            }
            if let err = model.rowError {
                CockpitWarnBox {
                    Text(err).font(.system(size: 11)).foregroundColor(CockpitTheme.warn)
                }
            }
        }
        .padding(12)
        .background(CockpitTheme.panel)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(CockpitTheme.hairSoft, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct AddAccountDetectedRow: View {
    let dir: DetectedDir
    @ObservedObject var model: AddAccountModel

    private var cls: DetectedRowClass { AddAccountModel.classify(dir, fleetEmails: model.fleetEmails) }
    private var busy: AddAccountModel.RowBusy? { model.rowBusy }
    private var anyBusy: Bool { model.rowBusy != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 2) {
                Text(dir.email)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(dir.configDir)
                    .font(.system(size: 10))
                    .foregroundColor(CockpitTheme.ter)
                    .lineLimit(1)
            }
            switch cls {
            case .moved:
                Text(AddAccountCopy.moved)
                    .font(.system(size: 10.5))
                    .foregroundColor(CockpitTheme.ter)
            case .registeredElsewhere:
                Text(AddAccountCopy.registeredElsewhere)
                    .font(.system(size: 10.5))
                    .foregroundColor(CockpitTheme.ter)
            case .signedOut:
                Text(AddAccountCopy.signedOut)
                    .font(.system(size: 10.5))
                    .foregroundColor(CockpitTheme.ter)
                    .fixedSize(horizontal: false, vertical: true)
                // The row's remedy, as a control (owner 2026-08-12: an
                // un-pressable explanation left nothing to DO) — the
                // sheet's own browser sign-in is the fix for a dead
                // sign-in, same affordance the menu bar row offers.
                Button(action: { model.browserSignIn() }) {
                    Text(AddAccountCopy.signInAgain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(CockpitTheme.sec)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(CockpitTheme.hair, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .opacity(anyBusy ? 0.5 : 1)
                .disabled(anyBusy)
                .accessibilityIdentifier("add-account-signin-again-\(dir.configDir)")
                .accessibilityLabel(AddAccountCopy.signInAgain)
            case .unregistered, .registered:
                Text(cls == .registered ? AddAccountCopy.registeredSub : AddAccountCopy.unregisteredSub)
                    .font(.system(size: 10))
                    .foregroundColor(CockpitTheme.ter)
                HStack(spacing: 8) {
                    if cls == .unregistered {
                        adoptButton
                    }
                    moveButton
                }
                if model.confirmMove == dir.configDir {
                    Text(AddAccountCopy.moveWarning(dir.configDir))
                        .font(.system(size: 10))
                        .foregroundColor(CockpitTheme.warn)
                }
            }
        }
        .padding(.vertical, 8)
    }

    private var adoptButton: some View {
        let label = busy?.dir == dir.configDir && busy?.action == .adopt ? AddAccountCopy.adding : AddAccountCopy.addAsWatched
        return Button(action: { model.adoptRow(dir.configDir) }) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(CockpitTheme.sec)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(CockpitTheme.hair, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .opacity(anyBusy ? 0.5 : 1)
        .disabled(anyBusy)
        .accessibilityIdentifier("add-account-adopt-\(dir.configDir)")
        .accessibilityLabel(label)
    }

    private var moveButton: some View {
        let confirming = model.confirmMove == dir.configDir
        let label = busy?.dir == dir.configDir && busy?.action == .move
            ? AddAccountCopy.moving
            : (confirming ? AddAccountCopy.moveConfirm : AddAccountCopy.moveIntoFleet)
        return Button(action: { model.requestMove(dir.configDir) }) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(confirming ? CockpitTheme.warn : CockpitTheme.sec)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(CockpitTheme.hairSoft, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .opacity(anyBusy ? 0.5 : 1)
        .disabled(anyBusy)
        .accessibilityIdentifier("add-account-move-\(dir.configDir)")
        .accessibilityLabel(label)
    }
}
