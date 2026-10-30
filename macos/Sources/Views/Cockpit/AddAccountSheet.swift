import AppKit
import SwiftUI

// The "Add account" surface, shared by the cockpit sheet and the standalone
// sign-in window (LoginWindow.swift). Sign-in runs through Claude Code
// itself: the daemon starts `claude auth login`, Claude Code opens the
// browser, and the account joins the fleet when the user approves. The
// "already signed in on this Mac" section below lists folders llmpilot can
// adopt or move without signing in at all.

/// Every string the sheet shows, in one place.
enum AddAccountCopy {
    static let title = "Add account"
    static let intro =
        "Sign in with your Claude account. Your browser opens, and the account joins the fleet " +
        "when you approve — adding an account never switches Claude Code."
    static let signInButton = "Sign in with Claude"
    static let starting = "Starting…"
    // VOICE.md: verb+object — replaces the sign-in label after a failure.
    static let tryAgain = "Try again"

    static let waitBody = "Finish signing in in your browser. This updates on its own the moment you approve."
    static let cancel = "Cancel"
    static let noBrowser = "Browser didn't open?"
    static let openSignInPage = "Open the sign-in page"
    static let pasteHint = "Approve there, then paste the code the page shows."
    static let pastePlaceholder = "Paste code"
    static let submitCode = "Add account"
    static let submitting = "Adding…"

    static func doneMessage(outcome: String?, email: String?) -> String {
        let who = (email?.isEmpty == false) ? email! : "The account"
        switch outcome {
        case "active": return "\(who) is signed in — Claude Code is using it."
        case "updated": return "\(who) is signed in again."
        default: return "\(who) joined your fleet — switch to it any time."
        }
    }

    /// "Sign in again" asked for one account and the browser approved another.
    static func wrongAccount(landed: String, requested: String) -> String {
        "You approved as \(landed), not \(requested). \(landed) is signed in; to fix \(requested), " +
            "sign in again and pick that account in your browser."
    }

    /// Add account landed on an account the fleet already has — usually the
    /// browser was still signed in to it.
    static func alreadyInFleet(_ email: String) -> String {
        "\(email) is already in your fleet — its sign-in is fresh now. To add a different account, " +
            "sign out of claude.ai in your browser first, then sign in again."
    }

    static let signInFailedFallback = "Sign-in didn't finish — try again."
    static let attemptGone = "This sign-in ended when llmpilot restarted — start it again."
    static let pollTimeout = "The sign-in timed out — start it again."
    static let daemonDown = "The llmpilot daemon isn't reachable — open the menu bar app, then try again."
    static let claudeMissing =
        "llmpilot signs you in through Claude Code, which isn't installed on this Mac. Install it, then try again."
    static let getClaudeCode = "Install Claude Code"
    static let claudeCodeSetupURL = URL(string: "https://code.claude.com/docs/en/setup")!

    // MARK: detected section
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

/// Per-row classification, pulled out as a pure function so it is
/// independently testable against a classification table. Order matters:
/// `moved` wins over everything, then the confirmed-empty
/// (`signed_in == false`) branch, then the normal adopt/move branch.
enum DetectedRowClass: Equatable {
    case moved
    /// signed_in == false AND the account is already watched from another
    /// folder — telling this folder to "sign in again" would be wrong, the
    /// account is live elsewhere.
    case registeredElsewhere
    /// signed_in == false and the account is not watched anywhere else.
    case signedOut
    case unregistered
    /// Registered (pinned) but not yet moved — keeps the migration verb only.
    case registered
}

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
    /// Set with `error` when Claude Code isn't installed — the sheet then
    /// offers the install page instead of a plain retry.
    @Published private(set) var claudeMissing = false
    /// The sign-in link for a browser that didn't open (from the daemon).
    @Published private(set) var manualURL: URL?
    /// "Browser didn't open?" disclosure state.
    @Published var showPaste = false
    @Published var pasteInput = ""
    @Published private(set) var pasteBusy = false
    @Published private(set) var pasteError: String?
    @Published private(set) var doneMessage = ""
    /// The finished sign-in is not what was asked for (see doneMessage):
    /// shown as a warning, and the sheet stays open.
    @Published private(set) var doneIsWarning = false
    /// A follow-up the user needs (e.g. open Claude Code once) — shown under
    /// the done line, and the sheet stays open so it can be read.
    @Published private(set) var doneNote = ""
    @Published private(set) var detected: [DetectedDir] = []
    @Published private(set) var rowBusy: RowBusy?
    @Published var rowError: String?
    @Published private(set) var confirmMove: String?
    @Published private(set) var moveNotes: [String: String] = [:]

    /// The fleet's own config dir — never listed — and every email the fleet
    /// already watches. Set by the integrator from the live daemon state.
    var fleetDir: String
    var fleetEmails: [String]

    private let api: CockpitDaemonAPI & DaemonAPI

    // MARK: - injectable seams (tests: virtual clock, no real browser)

    var now: () -> Date = Date.init
    var sleep: (TimeInterval) async -> Void = { seconds in
        try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
    }
    var openExternal: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// Wired by the integrator to close the sheet or window.
    var onRequestClose: () -> Void = {}

    var pollInterval: TimeInterval = 1.5
    /// A little past the daemon's own 10-minute attempt limit, which reports
    /// a timed-out sign-in first; this only catches a daemon that went quiet.
    var pollTimeout: TimeInterval = 11 * 60
    /// Linger on "done" before auto-closing.
    var doneLingerDelay: TimeInterval = 1.8
    /// Move-confirm auto-disarm.
    var confirmResetDelay: TimeInterval = 3
    private var attemptID = ""
    /// The email the current sign-in was started for ("Sign in again").
    private var requestedEmail: String?
    /// The cancellable sign-in + poll sequence.
    private var signInTask: Task<Void, Never>?
    private var confirmResetTask: Task<Void, Never>?

    init(api: CockpitDaemonAPI & DaemonAPI, fleetDir: String = "", fleetEmails: [String] = []) {
        self.api = api
        self.fleetDir = fleetDir
        self.fleetEmails = fleetEmails
    }

    // MARK: - lifecycle (sheet open/close)

    /// Call when the sheet appears — refetches detected dirs on every open.
    func opened() {
        Task { await self.refreshDetected() }
    }

    /// Call when the sheet goes away. Stops watching the sign-in but leaves
    /// it running: approving in the browser after closing the sheet still
    /// adds the account. Cancel is the explicit stop.
    func closed() {
        signInTask?.cancel()
        signInTask = nil
        reset()
        requestedEmail = nil
        clearDetectedRowState()
        detected = []
    }

    private func reset() {
        phase = .idle
        attemptID = ""
        error = nil
        claudeMissing = false
        manualURL = nil
        showPaste = false
        pasteInput = ""
        pasteBusy = false
        pasteError = nil
        doneMessage = ""
        doneIsWarning = false
        doneNote = ""
    }

    /// The primary button's title.
    var signInButtonTitle: String {
        if phase == .starting { return AddAccountCopy.starting }
        return error != nil ? AddAccountCopy.tryAgain : AddAccountCopy.signInButton
    }

    private func clearDetectedRowState() {
        confirmResetTask?.cancel()
        confirmResetTask = nil
        rowBusy = nil
        rowError = nil
        confirmMove = nil
        moveNotes = [:]
    }

    // MARK: - detected dirs

    func refreshDetected() async {
        detected = (try? await api.detect()) ?? []
    }

    /// Every folder except the fleet's own slot.
    var candidates: [DetectedDir] {
        detected.filter { $0.configDir != fleetDir }
    }

    /// The section (and its outcome notes) only disappears once there is
    /// nothing left to show.
    var isDetectedSectionEmpty: Bool {
        candidates.isEmpty && moveNotes.isEmpty
    }

    static func classify(_ d: DetectedDir, fleetEmails: [String]) -> DetectedRowClass {
        if d.moved { return .moved }
        if d.signedIn == false {
            // Case-folded: .claude.json can hold "Alex@Example.dev" for an
            // account the fleet knows as "alex@example.dev".
            let inFleet = fleetEmails.contains { $0.caseInsensitiveCompare(d.email) == .orderedSame }
            return inFleet ? .registeredElsewhere : .signedOut
        }
        return d.registered ? .registered : .unregistered
    }

    /// Blocks EVERY row while any one row's action is in flight.
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

    /// The two-click confirm: first click arms it, second click (while
    /// still armed for THIS dir) fires the move.
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

    /// Disarms an armed move confirm.
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
                    // A later clean move of the same dir resolves the earlier
                    // warning — a note that is no longer true must not linger.
                    self.moveNotes.removeValue(forKey: dir)
                }
                await self.refreshDetected()
            } catch {
                self.rowError = error.localizedDescription
            }
            self.rowBusy = nil
        }
    }

    // MARK: - sign-in

    /// Button-facing entry point — launches the cancellable sign-in + poll
    /// sequence. `email` pre-fills the sign-in page ("Sign in again").
    /// Tests call `runBrowserSignIn(email:)` directly.
    func browserSignIn(email: String? = nil) {
        guard phase == .idle else { return }
        signInTask?.cancel()
        signInTask = Task { [weak self] in
            await self?.runBrowserSignIn(email: email)
        }
    }

    /// The primary button: a fresh Add account — or, after a failure, the
    /// same sign-in again, still for the account it was repairing.
    func primarySignIn() {
        browserSignIn(email: error != nil ? requestedEmail : nil)
    }

    func runBrowserSignIn(email: String? = nil) async {
        // closed() may have cancelled us before this body even ran — don't
        // resurrect .starting on a sign-in the user already abandoned.
        guard !Task.isCancelled else { return }
        clearDetectedRowState()
        reset()
        requestedEmail = email
        phase = .starting
        do {
            let s = try await api.startBrowserLogin(email: email)
            guard !Task.isCancelled else { phase = .idle; return }
            attemptID = s.attemptID
            phase = .browserWait
            await pollLoop(id: s.attemptID, startedAt: now())
        } catch {
            if Task.isCancelled { return }
            phase = .idle
            if let e = error as? ApiError, e.code == "claude_missing" {
                claudeMissing = true
                self.error = AddAccountCopy.claudeMissing
            } else {
                self.error = message(for: error)
            }
        }
    }

    /// Polls the attempt until it finishes. Transient fetch errors are
    /// swallowed — the poll keeps going.
    private func pollLoop(id: String, startedAt: Date) async {
        while true {
            await sleep(pollInterval)
            if Task.isCancelled { return }
            do {
                let s = try await api.browserLoginStatus(attempt: id)
                if Task.isCancelled { return }
                switch s.status {
                case "done":
                    phase = .done
                    pasteBusy = false
                    let landed = s.email ?? ""
                    if let want = requestedEmail, !want.isEmpty, !landed.isEmpty,
                       want.caseInsensitiveCompare(landed) != .orderedSame {
                        doneIsWarning = true
                        doneMessage = AddAccountCopy.wrongAccount(landed: landed, requested: want)
                        return
                    }
                    if (requestedEmail ?? "").isEmpty, s.existing == "true", !landed.isEmpty {
                        doneIsWarning = true
                        doneMessage = AddAccountCopy.alreadyInFleet(landed)
                        return
                    }
                    doneMessage = AddAccountCopy.doneMessage(outcome: s.outcome, email: s.email)
                    if let note = s.note, !note.isEmpty {
                        doneNote = note
                        return
                    }
                    await sleep(doneLingerDelay)
                    if !Task.isCancelled { onRequestClose() }
                    return
                case "failed":
                    let msg = s.error ?? ""
                    error = msg.isEmpty ? AddAccountCopy.signInFailedFallback : Self.sentence(msg)
                    phase = .idle
                    pasteBusy = false
                    return
                default:
                    if manualURL == nil, let raw = s.manualURL, !raw.isEmpty {
                        manualURL = URL(string: raw)
                    }
                }
            } catch let e as DaemonError {
                // The daemon restarted and forgot this attempt — waiting on
                // it can only time out.
                if case .http(404, _) = e {
                    error = AddAccountCopy.attemptGone
                    phase = .idle
                    pasteBusy = false
                    return
                }
                // otherwise transient (daemon busy) — keep polling.
            } catch {
                // transient — keep polling.
            }
            if Task.isCancelled { return }
            if now().timeIntervalSince(startedAt) >= pollTimeout {
                error = AddAccountCopy.pollTimeout
                phase = .idle
                return
            }
        }
    }

    /// Opens Claude Code's manual sign-in link (the page then shows a code).
    func openSignInPage() {
        guard let url = manualURL else { return }
        openExternal(url)
    }

    /// Hands the pasted code to Claude Code; the poll reports the outcome.
    func submitPastedCode() async {
        let code = pasteInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard phase == .browserWait, !attemptID.isEmpty, !code.isEmpty, !pasteBusy else { return }
        pasteBusy = true
        pasteError = nil
        do {
            try await api.submitLoginCode(attempt: attemptID, code: code)
        } catch {
            pasteBusy = false
            pasteError = message(for: error)
        }
    }

    /// Cancel button while waiting: stops the sign-in on the daemon too.
    func cancelBrowserWait() {
        signInTask?.cancel()
        signInTask = nil
        let id = attemptID
        if !id.isEmpty {
            Task { try? await self.api.cancelBrowserLogin(attempt: id) }
        }
        reset()
    }

    /// "Sign in again" from a finished-but-not-what-was-asked state.
    func signInAgainFromDone() {
        let email = requestedEmail
        signInTask?.cancel()
        reset()
        browserSignIn(email: email)
    }

    func openClaudeCodeSetup() {
        openExternal(AddAccountCopy.claudeCodeSetupURL)
    }

    private func message(for error: Error) -> String {
        if let e = error as? DaemonError, case .down = e {
            return AddAccountCopy.daemonDown
        }
        return Self.sentence(error.localizedDescription)
    }

    /// Daemon messages are lowercase clauses; the sheet shows sentences.
    static func sentence(_ s: String) -> String {
        guard let first = s.first else { return s }
        var out = first.uppercased() + s.dropFirst()
        if let last = out.last, !".?…".contains(last) { out += "." }
        return out
    }
}

// MARK: - view

struct AddAccountSheet: View {
    @ObservedObject var model: AddAccountModel
    @FocusState private var pasteFocused: Bool

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
                    VStack(alignment: .leading, spacing: 6) {
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundColor(CockpitTheme.warn)
                            .fixedSize(horizontal: false, vertical: true)
                        if model.claudeMissing {
                            Button(AddAccountCopy.getClaudeCode) { model.openClaudeCodeSetup() }
                                .buttonStyle(.link)
                                .font(.system(size: 11, weight: .semibold))
                                .accessibilityIdentifier("add-account-get-claude-code")
                        }
                    }
                }
            }
        }
        // No root padding/frame: SheetChrome (NativeCockpitWindow.swift) and
        // the standalone window each own the inset.
        .onAppear { model.opened() }
        .onDisappear { model.closed() }
    }

    @ViewBuilder
    private var phaseBody: some View {
        switch model.phase {
        case .done:
            if model.doneIsWarning {
                VStack(alignment: .leading, spacing: 10) {
                    CockpitWarnBox {
                        Text(model.doneMessage)
                            .font(.system(size: 11))
                            .foregroundColor(CockpitTheme.warn)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityIdentifier("add-account-done-warning")
                    Button(AddAccountCopy.signInAgain) { model.signInAgainFromDone() }
                        .accessibilityIdentifier("add-account-signin-again")
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(CockpitTheme.ok)
                            .accessibilityHidden(true)
                        Text(model.doneMessage)
                            .font(.system(size: 12))
                            .foregroundColor(CockpitTheme.sec)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !model.doneNote.isEmpty {
                        Text(model.doneNote)
                            .font(.system(size: 11))
                            .foregroundColor(CockpitTheme.ter)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("add-account-done")
            }
        case .browserWait:
            waitBody
        case .idle, .starting:
            VStack(alignment: .leading, spacing: 10) {
                Text(AddAccountCopy.intro)
                    .font(.system(size: 12))
                    .foregroundColor(CockpitTheme.sec)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: { model.primarySignIn() }) {
                    Text(model.signInButtonTitle)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        // actionFill (owner 2026-08-12): one blue for every
                        // primary action.
                        .background(CockpitTheme.actionFill)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .opacity(model.phase == .starting ? 0.5 : 1)
                .disabled(model.phase == .starting)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("add-account-browser-signin")
                .accessibilityLabel(model.signInButtonTitle)
            }
        }
    }

    private var waitBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
                Text(AddAccountCopy.waitBody)
                    .font(.system(size: 12))
                    .foregroundColor(CockpitTheme.sec)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                Button(AddAccountCopy.noBrowser) {
                    model.showPaste.toggle()
                    if model.showPaste { pasteFocused = true }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundColor(CockpitTheme.accTx)
                .accessibilityIdentifier("add-account-no-browser")
                Spacer()
                Button(AddAccountCopy.cancel) { model.cancelBrowserWait() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(CockpitTheme.ter)
                    .accessibilityIdentifier("add-account-cancel")
                    .accessibilityLabel(AddAccountCopy.cancel)
            }
            if model.showPaste {
                pasteBox
            }
        }
    }

    private var pasteBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: { model.openSignInPage() }) {
                Text(AddAccountCopy.openSignInPage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(CockpitTheme.sec)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(CockpitTheme.hair, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(model.manualURL == nil)
            .opacity(model.manualURL == nil ? 0.5 : 1)
            .accessibilityIdentifier("add-account-open-signin-page")
            Text(AddAccountCopy.pasteHint)
                .font(.system(size: 11))
                .foregroundColor(CockpitTheme.ter)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                TextField(AddAccountCopy.pastePlaceholder, text: $model.pasteInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11.5, design: .monospaced))
                    .focused($pasteFocused)
                    .disabled(model.pasteBusy)
                    .onSubmit { Task { await model.submitPastedCode() } }
                    .accessibilityIdentifier("add-account-paste-field")
                Button(model.pasteBusy ? AddAccountCopy.submitting : AddAccountCopy.submitCode) {
                    Task { await model.submitPastedCode() }
                }
                .disabled(model.pasteBusy || model.pasteInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("add-account-submit-code")
            }
            if let err = model.pasteError {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundColor(CockpitTheme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(CockpitTheme.panel)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(CockpitTheme.hairSoft, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// The "already signed in on this Mac" list.
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
                // sheet's own sign-in, pre-filled with this account.
                Button(action: { model.browserSignIn(email: dir.email) }) {
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
