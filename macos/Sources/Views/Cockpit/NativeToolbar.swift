import SwiftUI

// Phase 2 chunk A: the native cockpit toolbar row + its error flash.
// Native port of web/src/shell/Toolbar.tsx (app name, daemon pill, add
// account, settings) and web/src/App.tsx's transient flash (App.tsx:
// 429-439). Wired into NativeCockpitRootView (NativeCockpitWindow.swift),
// which binds FlashBanner's dismiss to clearing FleetViewModel.lastError so
// a repeated identical error still re-surfaces.

// MARK: - error flash (App.tsx:206-212, 429-439)

/// Pure dismiss-state predicate for the toolbar's error flash: a message is
/// visible unless it exactly matches the last-dismissed one. A FRESH error
/// (even one that repeats earlier text after a dismiss+retry) must still
/// surface — which is why dismissal clears the SOURCE
/// (FleetViewModel.lastError = nil, the setFlash(null) twin) instead of
/// remembering dismissed text locally: a local memory would swallow a
/// repeated identical error forever.

/// One dismissible warn strip — native port of App.tsx's flash banner
/// (App.tsx:429-439): the daemon's error text (e.g. the 409-pinned copy from
/// internal/daemon/server.go handleSwitch) shown verbatim, manual dismiss
/// only. The web has no auto-dismiss timer, so neither does this.
struct FlashBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(message)
                .font(.system(size: 11.5))
                .foregroundColor(CockpitTheme.warn)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(action: onDismiss) {
                Text("✕").font(.system(size: 11.5, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundColor(CockpitTheme.warn)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CockpitTheme.warnBg)
        .overlay(Rectangle().fill(CockpitTheme.warnBd).frame(height: 1), alignment: .bottom)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - toolbar row (Toolbar.tsx)

/// Native port of the toolbar chrome: app name + ConnectivityPill (currently
/// inlined in NativeCockpitWindow.swift's `content(_:)`, lines 58-68) plus
/// Toolbar.tsx's add-account button (Toolbar.tsx:43-53) and settings gear
/// (Toolbar.tsx:95-101). Deliberately excludes Toolbar.tsx's "＋ Fresh
/// window" dropdown — deferred to Phase 3 with the scheduling system.
/// Add/settings are injected closures; this view wires no dialogs itself.
///
/// Header order per audit F15 (2026-08-16, owner decision: drop the healthy
/// pill; ? first, then ⚙, both left of Add account): [llmpilot] … [pill, only when not
/// live] [?] [⚙] [＋ Add account]; "＋ Fresh window" is appended by the
/// caller (NativeCockpitWindow.swift) after this row, still last.
struct NativeToolbarRow: View {
    let status: FleetViewModel.Status
    let asOfAge: String?
    /// Toolbar.tsx:43-53 / App.tsx:422 — `detected.filter { !$0.registered
    /// }.count`; 0 hides the badge.
    let unregisteredDetectedCount: Int
    let onAddAccount: () -> Void
    let onSettings: () -> Void
    /// Toolbar.tsx:16 — replays the guided tour; nil hides the control
    /// (App.tsx:426's `canGuide ? () => setTourOpen(true) : undefined` —
    /// "nothing to point at").
    var onGuide: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            Text("llmpilot")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            // F15: the permanently-green "Daemon active" pill is gone —
            // this slot now shows only the non-healthy states (connecting/
            // starting/down); nothing renders while the daemon is live.
            if status != .live {
                ConnectivityPill(status: status, asOfAge: asOfAge)
            }
            if let onGuide {
                guideButton(onGuide)
            }
            settingsButton
            addAccountButton
        }
    }

    /// Toolbar.tsx:85-94 "Show me around" — a plain "?" affordance next to
    /// the settings gear.
    private func guideButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("?")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(CockpitTheme.sec)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show me around")
        .accessibilityIdentifier("tour-show-me-around")
    }

    private var addAccountButton: some View {
        Button(action: onAddAccount) {
            HStack(spacing: 6) {
                Text("＋ Add account")
                    .font(.system(size: 11.5))
                    .foregroundColor(CockpitTheme.sec)
                if unregisteredDetectedCount > 0 {
                    Text("\(unregisteredDetectedCount)")
                        .font(CockpitTheme.numeric(9.5, weight: .bold))
                        .foregroundColor(CockpitTheme.text)
                        .frame(minWidth: 15, minHeight: 15)
                        .padding(.horizontal, 4)
                        .background(CockpitTheme.rail, in: Capsule())
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(CockpitTheme.hair, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var settingsButton: some View {
        Button(action: onSettings) {
            Image(systemName: "gearshape")
                .font(.system(size: 13))
                .foregroundColor(CockpitTheme.sec)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Settings")
        // The real-click gate (scripts/e2e-real-click.sh) locates the gear
        // by identifier: SwiftUI exposes no AXDescription for an
        // image-only plain button, so the label alone is not addressable
        // from System Events.
        .accessibilityIdentifier("cockpit-settings")
    }
}

// MARK: - previews

#Preview("Toolbar row — badge") {
    NativeToolbarRow(
        status: .live, asOfAge: nil, unregisteredDetectedCount: 2,
        onAddAccount: {}, onSettings: {})
        .padding()
        .frame(width: 640)
}

#Preview("Toolbar row — no badge, down") {
    NativeToolbarRow(
        status: .down, asOfAge: "9 min ago", unregisteredDetectedCount: 0,
        onAddAccount: {}, onSettings: {})
        .padding()
        .frame(width: 640)
}

#Preview("Flash banner") {
    FlashBanner(
        message: "mira signs in from its own folder (~/.claude-mira), so llmpilot watches it instead of switching to it",
        onDismiss: {})
        .frame(width: 640)
}
