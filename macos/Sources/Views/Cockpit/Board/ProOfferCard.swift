import SwiftUI

/// Native port of App.tsx's `proPrompt` banner: a tier boundary (402
/// pro_required/pro_unavailable) is an OFFER, not a failure — role status,
/// NEVER warn/red styling, one bold fact line rendered from the daemon's own
/// copy. The CTA is an injected closure: Phase 4 wires the real paywall, but
/// for now it may just open the web cockpit URL — this view has no opinion
/// on what "buy" does.
struct ProOfferCard: View {
    /// Kept for the accessibility label; the VISIBLE headline is the web's
    /// fixed fact line for BOTH codes (App.tsx:450) — rendering the daemon
    /// message as the headline duplicated the body sentence for
    /// pro_unavailable (its 402 message IS that body line).
    let message: String

    private static let headline = "Fresh windows run on your schedule — that is the autopilot's job." 
    /// "Try it free for 4 days" — shown ONLY when the refusal was
    /// pro_required.
    let showCTA: Bool
    /// The machine code — selects the explanatory paragraph, exactly the
    /// two-paragraph tree App.tsx:449-457 renders (headline + body); the
    /// web never shows the headline alone.
    var code: String? = nil

    private var bodyCopy: String {
        code == "pro_unavailable"
            ? "This build was compiled without it. Watching, switching, the statusline, and history keep working here — the app at llmpilot.dev adds the autopilot."
            : "Watching every account, switching by hand, the statusline, and history stay free. The autopilot books your windows and moves you before a wall, unattended."
    }
    let onCTA: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.headline)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(CockpitTheme.text)
                Text(bodyCopy)
                    .font(.system(size: 11.5))
                    .foregroundStyle(CockpitTheme.sec)
            }
            .frame(maxWidth: 640, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            HStack(spacing: 12) {
                if showCTA {
                    Button("Try it free for 4 days", action: onCTA)
                        .buttonStyle(.borderedProminent)
                        .tint(CockpitTheme.accent)
                        .controlSize(.small)
                }
                Button("Not now", action: onDismiss)
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(CockpitTheme.sec)
            }
            .layoutPriority(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(CockpitTheme.panel)
        .overlay(Rectangle().fill(CockpitTheme.hair).frame(height: 1), alignment: .bottom)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(message))
    }
}
