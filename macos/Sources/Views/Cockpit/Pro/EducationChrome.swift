import AppKit
import SwiftUI

// Shared presentational chrome for Education.tsx's three screens
// (WallScreen/BlindSpotScreen/WindowsScreen, all built in EducationViews.
// swift): the per-screen `Frame` wrapper and the demo lane row. Pure
// rendering, parameter-driven, no timing — the beat models live in
// EducationTimingModels.swift. The progress dots and the corridor's shared
// stage/footer scaffold (`OnboardingStage`, `OnboardingProgressRow`) live
// in PaywallViews.swift — `EducationFrame` below renders through them so
// every corridor screen (education, accounts/switch, paywall) shares one
// geometry (design critique 2026-08-09).

/// Native `bg-acc-tx dark:bg-accent` — a CROSSED token swap (light fill =
/// `accTx`, dark fill = `accent`, not `accTx`'s own dark variant, which is
/// the lighter text-safe blue used elsewhere for text-on-tint) used by
/// both the primary Continue button and the SWITCH pill. Duplicated as raw
/// hexes rather than composed from `CockpitTheme.accTx`/`.accent` (SwiftUI
/// has no supported way to re-derive an `NSColor` from an already-built
/// dynamic `Color`) — same trade `FleetLanesView.avatarColor` already
/// makes for `CockpitTheme.accent`'s hexes. Keep in lockstep with
/// CockpitTheme.accTx (light) / CockpitTheme.accent (dark) if theme.css
/// ever changes.
let eduFilledAccentBackground: Color = {
    Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return dark
            ? NSColor(red: 0x0a / 255, green: 0x84 / 255, blue: 0xff / 255, alpha: 1) // CockpitTheme.accent (dark)
            : NSColor(red: 0x0a / 255, green: 0x6a / 255, blue: 0xe0 / 255, alpha: 1) // CockpitTheme.accTx (light)
    }))
}()

/// Education.tsx's `Frame` — the shared per-screen wrapper: headline (its
/// `keyPhrase` span carries emphasis as WEIGHT, never a decorative color —
/// design/DESIGN-SYSTEM.md reserves accent blue for booked/charging state
/// and actions, design critique 2026-08-09), lede, the screen's own
/// content, an optional illustrative-numbers note, the closing note, and
/// the single Continue control — laid out on the corridor's shared
/// `OnboardingStage` scaffold (PaywallViews.swift): progress row pinned at
/// the top, ONE flexible spacer, fixed-height footer.
struct EducationFrame<Content: View>: View {
    let step: Int
    let total: Int
    let headline: String
    let keyPhrase: String
    var tail: String = ""
    let lede: String
    var example = false
    let note: String
    /// Per-screen verb+object CTA (design critique 2026-08-09, VOICE.md:
    /// buttons are verb+object) — each education screen names its own next
    /// step rather than sharing a bare "Continue".
    var continueLabel = "Continue"
    let onContinue: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        OnboardingStage(position: StepPosition(step: step, total: total)) {
            VStack(alignment: .leading, spacing: 0) {
                // Each segment sets its own font (rather than one shared
                // `.font()` after concatenation) so the emphasis clause's
                // heavier weight survives — and every segment routes
                // through `CockpitTheme.numeric`-backed tokens, so a digit
                // landing in ANY of the three (e.g. BlindSpotScreen's
                // "N accounts" keyPhrase) renders tabular by construction,
                // not by the caller remembering to ask for it.
                (Text(headline).font(CockpitTheme.Onboarding.headline)
                    + Text(keyPhrase).font(CockpitTheme.Onboarding.headlineEmphasis)
                    + Text(tail).font(CockpitTheme.Onboarding.headline))
                    .tracking(CockpitTheme.Onboarding.headlineTracking)
                    .lineSpacing(CockpitTheme.Onboarding.headlineLineSpacing)
                    .foregroundColor(CockpitTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text(lede)
                    .font(CockpitTheme.Onboarding.lede)
                    .lineSpacing(CockpitTheme.Onboarding.ledeLineSpacing)
                    .foregroundColor(CockpitTheme.sec)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, FlowLayout.headlineToLede)
                content()
                    .padding(.top, FlowLayout.ledeToVisual)
                if example {
                    Text(EducationMath.exampleNote)
                        .font(CockpitTheme.Onboarding.annotation)
                        .lineSpacing(CockpitTheme.Onboarding.annotationLineSpacing)
                        .foregroundColor(CockpitTheme.ter)
                        .padding(.top, FlowLayout.visualToDisclosure)
                }
                Text(note)
                    .font(CockpitTheme.Onboarding.body)
                    .lineSpacing(CockpitTheme.Onboarding.bodyLineSpacing)
                    .foregroundColor(CockpitTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, FlowLayout.disclosureToClosing)
            }
        } footer: {
            HStack(spacing: FlowLayout.footerControlSpacing) {
                Spacer()
                Button(continueLabel, action: onContinue)
                    .pwPrimary()
                    // Return advances — the whole flow is walkable from the
                    // keyboard, no mouse (owner 2026-08-09).
                    .keyboardShortcut(.defaultAction)
                    // OnboardingPrimaryButtonStyle's custom ButtonStyle
                    // strips SwiftUI's default AX exposure (measured: no
                    // AXTitle/Description/Value/Help survives it) — restore
                    // a real name plus a stable identifier the e2e AX walk
                    // can locate directly, in place of the old "the one
                    // AXButton with no AXSubrole" fallback locator
                    // (scripts/e2e-pro-native.sh).
                    .accessibilityIdentifier("edu-continue")
                    .accessibilityLabel(continueLabel)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// Education.tsx's `DemoLane` — the identity row a shipped `LaneHeader`
/// renders: avatar disc (reusing `FleetLanesView.avatarColor`, the shipped
/// avatar.ts port), email, an optional ACTIVE/SWITCH badge, the status
/// dot + line, then arbitrary bar content.
struct EduDemoLane<Content: View>: View {
    enum Badge { case active, switchVerb }
    enum StatusTone {
        case calm, warn, crit, idle

        var dotColor: Color {
            switch self {
            case .crit: return CockpitTheme.crit
            case .warn: return CockpitTheme.warnRaw
            case .calm: return CockpitTheme.ok
            case .idle: return CockpitTheme.grayDot
            }
        }
    }

    let id: String
    let email: String
    var badge: Badge?
    let status: String
    let statusTone: StatusTone
    /// The `className={reveal}` treatment BlindSpotScreen's second lane
    /// carries — every other caller leaves this `true` (no animation).
    var revealed = true
    @ViewBuilder var content: () -> Content

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(avatarColor(id: id, dark: colorScheme == .dark))
                .frame(width: 26, height: 26)
                .overlay(
                    Text(String((email.first.map(String.init) ?? "?")).uppercased())
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                )
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(email)
                        .font(CockpitTheme.Onboarding.controlLabel)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    // Sentence case (design/VOICE.md: "Case: sentence case
                    // for all copy" — no all-caps badges) — was "ACTIVE"/
                    // "SWITCH".
                    if badge == .active {
                        Text("Active")
                            .font(.system(size: 8.5, weight: .bold))
                            .tracking(0.2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(CockpitTheme.okBg))
                            .foregroundColor(CockpitTheme.okTx)
                    }
                    if badge == .switchVerb {
                        Text("Switch")
                            .font(.system(size: 9, weight: .bold))
                            .tracking(0.2)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(eduFilledAccentBackground))
                            .foregroundColor(.white)
                    }
                }
                HStack(spacing: 5) {
                    Circle().fill(statusTone.dotColor).frame(width: 6, height: 6)
                    Text(status)
                        .font(CockpitTheme.Onboarding.status)
                        .foregroundColor(CockpitTheme.sec)
                        .lineLimit(1)
                }
                content()
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .background(RoundedRectangle(cornerRadius: 10).fill(CockpitTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(CockpitTheme.hairSoft, lineWidth: 1))
        .opacity(revealed ? 1 : 0)
        .offset(y: revealed ? 0 : 8)
        .animation(.easeOut(duration: 0.5), value: revealed)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("edu-lane-\(id)")
    }
}
