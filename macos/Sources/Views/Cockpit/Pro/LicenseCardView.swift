import AppKit
import SwiftUI

// Native port of web/src/pro/LicenseSection.tsx's card — status line,
// one-click cancel, recover-by-email, claim-by-code, and (Phase 4 chunk 4E)
// the reveal/copy affordance for the license id. Every wire call goes
// through the ALREADY-BUILT `LicenseAccountModel` (AskMachine.swift); the
// confirm/keep toggle and the email/code text fields are plain view-local
// `@State`, matching LicenseSection.tsx's own `useState` (never wired
// through a model on the web side either).
//
// GAP CLOSED (Phase 4 chunk 4E, gap ①): chunk 4C's `LicenseAccountModel` had
// no `reveal()` wire method — added in AskMachine.swift alongside the
// `revealedID` published field this view now drives Show/Copy from.

/// LicenseSection.tsx's derived read state (`status`/`canCancel`/
/// `showTurnOn`/`statusLine`, LicenseSection.tsx:26-43,65-68), pulled out as
/// a pure, directly-testable value type — mirrors the `PriceBottomControl`/
/// `PausedCTA` pattern in PaywallViews.swift.
struct LicenseCardStatus: Equatable {
    let status: String
    let title: String
    let hint: String
    let canCancel: Bool
    let showTurnOn: Bool

    /// LicenseSection.tsx:65-68's fallback object, folded into this
    /// resolver rather than materialized as a fake `LicenseInfo` (that
    /// struct has no memberwise init — see this chunk's report).
    static func resolve(license: LicenseInfo?, offline: Bool, now: Date = Date(), dateStyle: DateFormatter.Style = .long)
        -> LicenseCardStatus
    {
        let status = license?.status ?? (offline ? "unknown" : "none")
        let canCancel = status == "trialing"
        let showTurnOn = status == "none" || status == "lapsed" || status == "revoked"
        func fmt(_ d: Date) -> String {
            let df = DateFormatter()
            df.dateStyle = dateStyle
            return df.string(from: d)
        }
        let (title, hint): (String, String)
        switch status {
        case "trialing":
            let days = license?.trial?.daysLeft ?? 0
            let left = "\(days) \(days == 1 ? "day" : "days") left"
            let charge = license?.trial?.chargeDate.map { " · charges \(fmt($0))" } ?? ""
            (title, hint) = ("Free trial", "\(left)\(charge). Cancel anytime below.")
        case "lifetime":
            (title, hint) = ("Pro — lifetime", "Bought once, yours for good.")
        case "lapsed":
            (title, hint) = ("Paused", "Your trial ended. Schedules are kept; nothing was deleted.")
        case "revoked":
            (title, hint) = ("Paused", "This purchase was refunded or disputed.")
        default:
            (title, hint) = ("Not active", "The autopilot is off. Turn it on to have it watch your windows.")
        }
        return LicenseCardStatus(status: status, title: title, hint: hint, canCancel: canCancel, showTurnOn: showTurnOn)
    }
}

struct LicenseCardView: View {
    let license: LicenseInfo?
    var offline = false
    @ObservedObject var model: LicenseAccountModel
    let onTurnOn: () -> Void

    @State private var confirming = false
    @State private var email = ""
    @State private var code = ""

    private var resolved: LicenseCardStatus { LicenseCardStatus.resolve(license: license, offline: offline) }
    private var canCancel: Bool { resolved.canCancel }
    private var showTurnOn: Bool { resolved.showTurnOn }
    private var statusLine: (title: String, hint: String) { (resolved.title, resolved.hint) }

    var body: some View {
        if let license, !license.available {
            unavailableCard
        } else {
            card
        }
    }

    /// LicenseSection.tsx:53-63.
    private var unavailableCard: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("llmpilot Pro").font(.system(size: 12, weight: .semibold))
            Text(
                "This is a source build — the autopilot is not included. Switching, statusline, cockpit, and analytics keep working. The official app at llmpilot.dev includes Pro."
            )
            .font(.system(size: 10.5))
            .foregroundColor(CockpitTheme.ter)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("license-unavailable")
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusLine.title).font(.system(size: 12, weight: .semibold))
                    Text(statusLine.hint).font(.system(size: 10.5)).foregroundColor(CockpitTheme.ter)
                }
                Spacer(minLength: 8)
                if showTurnOn {
                    Button("Turn on the autopilot", action: onTurnOn)
                        .pwGhost()
                        .accessibilityIdentifier("license-turn-on")
                }
                if canCancel, !confirming {
                    Button("Cancel trial", action: { confirming = true })
                        .pwGhost()
                        .accessibilityIdentifier("license-cancel-open")
                }
            }

            if confirming {
                confirmBox
            }

            if let masked = license?.licenseIDMasked {
                revealRow(masked: masked)
            }

            recoverForm
            claimForm

            Text("Stored on this Mac. Other Macs turn on Pro by email — enter the code from the email above.")
                .font(.system(size: 10))
                .foregroundColor(CockpitTheme.ter)

            if let note = model.note {
                Text(note).font(.system(size: 11)).foregroundColor(CockpitTheme.sec).accessibilityIdentifier("license-note")
            } else if let err = LadderLogic.licenseErrorCopy(license?.errorCode) {
                Text(err).font(.system(size: 11)).foregroundColor(CockpitTheme.sec).accessibilityIdentifier("license-note")
            }
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("license-card")
    }

    /// LicenseSection.tsx:145-161 — one click, no confirmation dance beyond
    /// this arm/confirm/keep toggle.
    private var confirmBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Cancel the trial? The autopilot pauses now and you are not charged.")
                .font(.system(size: 11.5))
            HStack(spacing: 12) {
                Button("Cancel the trial", action: {
                    Task {
                        // LicenseSection.tsx:75 clears inside the `try` —
                        // a failed cancel keeps the confirm box armed next
                        // to its remedy note.
                        if await model.cancel() { confirming = false }
                    }
                })
                .pwDanger()
                .disabled(model.busy)
                .accessibilityIdentifier("license-cancel-confirm")
                Button("Keep the trial", action: { confirming = false })
                    .pwGhost()
                    .disabled(model.busy)
                    .accessibilityIdentifier("license-cancel-keep")
            }
        }
        .padding(10)
        .background(CockpitTheme.panel)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(CockpitTheme.hair, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("license-cancel-confirm-box")
    }

    /// LicenseSection.tsx:163-179 — Show fetches the full id; once revealed,
    /// Show is replaced by Copy (never both at once, matching the web's
    /// `!revealed ? <Show/> : <Copy/>`). Copy writes straight to
    /// `NSPasteboard.general` — the web's `navigator.clipboard.writeText`
    /// twin.
    private func revealRow(masked: String) -> some View {
        HStack(spacing: 8) {
            Text("License \(model.revealedID ?? masked)")
                .font(.system(size: 10.5))
                .foregroundColor(CockpitTheme.ter)
            if let revealed = model.revealedID {
                Button("Copy", action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(revealed, forType: .string)
                })
                .pwGhost()
                .accessibilityIdentifier("license-copy")
            } else {
                Button("Show", action: { Task { await model.reveal() } })
                    .pwGhost()
                    .accessibilityIdentifier("license-reveal")
            }
        }
    }

    /// LicenseSection.tsx:181-194 — uniform copy regardless of whether the
    /// address is on file (the model, not this view, guarantees that).
    private var recoverForm: some View {
        HStack(spacing: 8) {
            TextField("you@example.com", text: $email)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
                .accessibilityLabel("Email to recover a purchase")
                .accessibilityIdentifier("license-recover-email")
            Button("Restore by email", action: {
                let value = email
                Task {
                    // LicenseSection.tsx:92 — clear only on success; a
                    // network blip must not erase the typed address.
                    if await model.recover(email: value) { email = "" }
                }
            })
            .pwGhost()
            .disabled(model.busy || email.isEmpty)
            .accessibilityIdentifier("license-recover-submit")
        }
    }

    /// LicenseSection.tsx:196-209.
    private var claimForm: some View {
        HStack(spacing: 8) {
            TextField("recovery code", text: $code)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
                .accessibilityLabel("Recovery code from your email")
                .accessibilityIdentifier("license-claim-code")
            Button("Restore with code", action: {
                let value = code
                Task {
                    // LicenseSection.tsx:106 — success-only clear.
                    if await model.claim(token: value) { code = "" }
                }
            })
            .pwGhost()
            .disabled(model.busy || code.isEmpty)
            .accessibilityIdentifier("license-claim-submit")
        }
    }
}
