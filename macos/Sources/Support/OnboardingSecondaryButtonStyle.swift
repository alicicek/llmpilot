import SwiftUI

// Audit 2026-08-16 F4: the accounts screen's "Add account" control was bare
// 12pt grey text (PaywallViews.swift's PWGhostButtonStyle — no icon, no
// border) while the menu bar renders the same verb as
// `Label("Add account", systemImage: "person.badge.plus")`. The ask: an
// icon and a thin border, consistent with the other secondary buttons —
// one design system rather than a one-off. This is that one grammar: icon + label inside a
// 1px hairline border, 150ms hover/press feedback (pack rule: state-only
// motion, 150-250ms). PWGhostButtonStyle is untouched and stays for
// genuinely ghost links ("I'll do this later", "Restore a purchase") — this
// style is for a secondary action that deserves to read as a real control.

/// A recognisable secondary button: `Label(icon + text)` content, a 1px
/// hairline border, no fill. Pairs with `OnboardingPrimaryButtonStyle`
/// (PaywallViews.swift) as the corridor's two button grammars — primary
/// (filled) and secondary (hairline) — plus `PWGhostButtonStyle` for plain
/// text links.
struct OnboardingSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        OnboardingSecondaryButtonLabel(configuration: configuration)
    }
}

private struct OnboardingSecondaryButtonLabel: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(CockpitTheme.numeric(12, weight: .semibold))
            .foregroundColor(CockpitTheme.text)
            .lineLimit(1)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(CockpitTheme.hair, lineWidth: 1)
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : (hovering ? 0.85 : 1)) : 0.45)
            .onHover { isHovering in hovering = isEnabled && isHovering }
            .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

extension View {
    /// Icon + label + hairline border — the corridor's one secondary-button
    /// grammar (audit 2026-08-16 F4).
    func onboardingSecondary() -> some View { buttonStyle(OnboardingSecondaryButtonStyle()) }
}
