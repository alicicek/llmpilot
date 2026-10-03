import Foundation

/// The "Install statusline" button's state machine — ONE for the doctor
/// note, the Settings row and the statusline editor, so every surface asks
/// the same question the same way. The daemon does the write (POST
/// /v1/statusline/install, the CLI verb's own code), which is what lets an
/// app-only install wire Claude Code without `llmpilot` on PATH.
///
/// The consent rule is the CLI's and lives in the daemon: a foreign
/// statusline is never replaced or wrapped until the user picks. This model
/// only ever RELAYS that — the first press sends no mode, and `.needsConsent`
/// is the only state that can send one.
@MainActor
final class StatuslineInstallModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case busy
        /// A foreign statusline is present and untouched; the user decides.
        case needsConsent
        case done(StatuslineInstallOutcome)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    private let api: CockpitDaemonAPI
    /// Fired after a write landed — the doctor re-sweeps so a resolved note
    /// does not linger; Settings has nothing to refresh.
    private let onInstalled: () -> Void

    init(api: CockpitDaemonAPI, onInstalled: @escaping () -> Void = {}) {
        self.api = api
        self.onInstalled = onInstalled
    }

    /// The button press. Never carries a mode: consent is a separate,
    /// visible step (`keep()` / `replace()`), not a default.
    func install() {
        guard phase != .busy else { return }
        send(mode: nil)
    }

    /// "Keep both" — the existing line renders above ours.
    func keep() {
        guard phase == .needsConsent else { return }
        send(mode: .keep)
    }

    /// "Replace it" — backed up, revertible with `llmpilot statusline uninstall`.
    func replace() {
        guard phase == .needsConsent else { return }
        send(mode: .replace)
    }

    func cancel() {
        if phase == .needsConsent { phase = .idle }
    }

    /// Back to the button. The doctor calls this when the statusline note
    /// comes BACK after an earlier install (the user removed the line, a
    /// reinstall moved the binary) — otherwise the row would read
    /// "Installed —" with nothing to press until the app restarted.
    func reset() {
        if case .done = phase { phase = .idle }
    }

    private func send(mode: StatuslineInstallMode?) {
        phase = .busy
        Task { [weak self] in
            guard let self else { return }
            do {
                let outcome = try await self.api.installStatusline(mode: mode)
                switch outcome {
                case .foreign:
                    self.phase = .needsConsent
                default:
                    self.phase = .done(outcome)
                    self.onInstalled()
                }
            } catch {
                let msg = error.localizedDescription
                self.phase = .failed(msg.isEmpty ? StatuslineInstallCopy.failed : msg)
            }
        }
    }
}

enum StatuslineInstallCopy {
    static let button = "Install statusline"
    static let working = "Installing…"
    static let keepBoth = "Keep both"
    static let replaceIt = "Replace it"
    static let cancel = "Cancel"
    static let failed = "Install failed — the daemon didn't take it."

    /// Shown with the two consent buttons. Names the rule, not the tool:
    /// the doctor note beside it already says whose line it is. Names the
    /// BACKUP FILE, never a terminal command — the person this button
    /// exists for has no `llmpilot` on PATH (review 2026-10-03 P1).
    static let consent = "Claude Code already runs a statusline. Keep both — it renders above the llmpilot line — or replace it; the old line is saved to ~/.llmpilot/statusline-replaced.json and settings.json.orig."

    static func result(_ outcome: StatuslineInstallOutcome) -> String {
        switch outcome {
        case .installed, .updated:
            return "Installed — Claude Code shows the line on its next prompt."
        case .already:
            return "Already installed — nothing to do."
        case .kept:
            return "Installed — your existing statusline renders above the llmpilot line."
        case .replaced:
            return "Installed — the previous statusline is saved in ~/.llmpilot/statusline-replaced.json."
        case .foreign:
            return consent
        }
    }
}
