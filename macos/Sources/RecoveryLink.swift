import AppKit

/// llmpilot://recover?token=… — the recovery email's one-click path (owner
/// 2026-08-29): the site's /recover page offers "Open llmpilot", handing the
/// one-time token straight to the app instead of making the buyer ferry it
/// by eye into Settings → License. This changes TRANSPORT, never trust: the
/// same hashed single-use 15-minute token, the same daemon claim
/// (POST /v1/license/recover/claim, Bearer-authed, install-bound), and a
/// link can only ever restore onto a Mac that runs the app — exactly like
/// the typed code it replaces as the primary path.
enum RecoveryLink {
    /// The worker's recovery token is 32 CSPRNG bytes rendered as 64 hex
    /// chars (worker/src/routes/api.ts randomToken). A URL is untrusted
    /// input from any browser — anything that isn't exactly our shape is
    /// refused here, before it can reach the wire.
    static func token(from url: URL) -> String? {
        // LaunchServices matches schemes case-insensitively but Foundation
        // does NOT normalize url.scheme, so lowercase before comparing (a
        // LLMPILOT://… link would otherwise route here and silently no-op).
        guard url.scheme?.lowercased() == "llmpilot" else { return nil }
        // Both llmpilot://recover?… (host) and llmpilot:/recover?… (path)
        // arrive depending on how the opener normalized the URL. Either way
        // the target is EXACTLY "recover" — a trailing path segment is some
        // other link, not a sloppier spelling of this one.
        let target: String
        if let host = url.host {
            guard url.path.isEmpty || url.path == "/" else { return nil }
            target = host
        } else {
            target = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        guard target.lowercased() == "recover" else { return nil }
        guard
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
            let raw = items.first(where: { $0.name == "token" })?.value
        else { return nil }
        let token = raw.lowercased()
        guard token.count == 64, token.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            return nil
        }
        return token
    }
}

/// Routes a parsed recovery link to the daemon's claim call and shows the
/// outcome.
///
/// A claim MUTATES this Mac's license — it overwrites the stored grant and
/// seats this install (persistLicense → Store.Save; the worker seats the
/// claimer and can evict the stalest seat). The daemon's claim route is
/// Bearer-gated precisely so no other local actor can mutate the
/// entitlement — but a URL scheme's initiator is anything on the machine
/// (a web page the user visits, another app), NOT a human inside the app
/// the way the typed-code path is. So the deep link must re-supply that
/// missing authorization gesture: `handle` confirms IN-APP before it claims
/// (owner + adversarial money review 2026-08-29, F1). This is the one place
/// the "changes transport, not trust" framing broke down.
@MainActor
final class RecoveryLinkHandler {
    static let shared = RecoveryLinkHandler()

    /// Wired by LLMPilotApp.init so a successful claim can open the cockpit
    /// on the fleet the app already holds.
    var fleet: FleetViewModel?
    /// Injectable for tests; the token itself is never logged either way.
    var api: CockpitDaemonAPI & DaemonAPI = HTTPDaemonClient()
    /// The consent gate — true to proceed with the claim. Production shows a
    /// two-button NSAlert; tests inject a decision. Default-refuse: an
    /// unrecognized environment must never silently claim.
    var confirm: () -> Bool = { RecoveryLinkHandler.runConfirmAlert() }
    /// Seam for tests — production shows a real NSAlert.
    var presentFailure: (String) -> Void = { message in
        let alert = NSAlert()
        alert.messageText = "Restore didn't complete"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
    /// Success acknowledgement, to match the typed path's "Restored — Pro is
    /// back on." (a cockpit already frontmost would otherwise show nothing).
    var presentSuccess: () -> Void = {
        let alert = NSAlert()
        alert.messageText = "Pro is on"
        alert.informativeText = "This Mac is restored."
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
    /// Cold-launch retry: the recovery email exists because this Mac lost
    /// Pro, so the app is likely being launched BY the link and its daemon
    /// is still coming up. Retry the claim while the connection is refused,
    /// not the raw "daemon not running". Overridable in tests.
    var retryDelay: TimeInterval = 1.0
    var maxRetries = 10

    private var inFlight = false
    /// The last token this handler successfully claimed. A recovery page
    /// never changes after a successful claim, so "click Open llmpilot
    /// again" is expected — a repeat of an already-claimed token is a no-op
    /// success, never a second claim against a now-spent token (F3).
    private var lastClaimed: String?

    func handle(_ url: URL) {
        guard let token = RecoveryLink.token(from: url) else { return }
        // Re-click of the link that already worked: show the outcome again,
        // never re-claim a spent token.
        if token == lastClaimed {
            openCockpit()
            return
        }
        // Set the gate BEFORE the modal confirm so repeated fires during the
        // dialog (a page hammering the scheme) are dropped, not queued.
        guard !inFlight else { return }
        inFlight = true
        guard confirm() else { inFlight = false; return }
        Task { [weak self] in
            guard let self else { return }
            defer { self.inFlight = false }
            await self.claim(token)
        }
    }

    private func claim(_ token: String) async {
        var attempt = 0
        while true {
            do {
                _ = try await api.licenseClaim(token: token)
                lastClaimed = token
                presentSuccess()
                openCockpit()
                return
            } catch {
                if case DaemonError.down = error, attempt < maxRetries {
                    attempt += 1
                    try? await Task.sleep(nanoseconds: UInt64(max(retryDelay, 0) * 1_000_000_000))
                    continue
                }
                presentFailure(Self.failureCopy(for: error))
                return
            }
        }
    }

    private func openCockpit() {
        if let fleet {
            NativeCockpitWindowController.shared.open(fleet: fleet)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Recovery-specific copy — NOT LadderLogic.licenseErrorCopy, whose
    /// codes are written for the checkout surface (its auth_required speaks
    /// of "this page", its invalid_input of "outdated terms" — both wrong
    /// here). Every branch says what happened and what to do next (F2).
    static func failureCopy(for error: Error) -> String {
        if case DaemonError.down = error {
            return "llmpilot is still starting up. Open the recovery link again in a few seconds."
        }
        if let api = error as? ApiError {
            switch api.code {
            case "seat_limit_reached":
                return "This license is already on its maximum number of Macs. Remove one from another Mac, then open the link again."
            case "auth_required", "install_not_activated":
                return "llmpilot couldn't authorize this Mac. Reopen it from the menu bar, then open the recovery link again."
            default:
                break
            }
        }
        return "This recovery link is invalid or expired. Request a fresh one from Settings → License → Restore by email."
    }

    /// The production consent dialog. Non-oracle: it reveals nothing about
    /// the token; it only asks the human whether they meant to restore here.
    private static func runConfirmAlert() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Restore Pro on this Mac?"
        alert.informativeText =
            "A recovery link asked to turn Pro on here. Only continue if you requested it — this replaces any license already on this Mac."
        let restore = alert.addButton(withTitle: "Restore Pro")
        let cancel = alert.addButton(withTitle: "Cancel")
        // Restore stays the visually primary (rightmost) button, but the
        // keyboard default is Cancel: a page can pop this modal unprompted
        // and a reflexive Return must NOT proceed — that reflex is the exact
        // confused-deputy this gate exists to stop (review 2026-08-29 P2).
        restore.keyEquivalent = ""
        cancel.keyEquivalent = "\r"
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}
