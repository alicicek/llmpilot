import SwiftUI

// Native port of web/src/shell/Toolbar.tsx's daemon pill (lines 19-26) and
// web/src/App.tsx's daemon-down / connecting full-page states (lines
// 504-527). Copy is preserved verbatim against App.tsx — a future edit to
// either side is a one-line diff, not silent drift.

/// web/src/App.tsx `ageLabel` (App.tsx:70-74), ported pure so it is
/// independently vector-testable: minutes rounded (never negative), under an
/// hour reads "N min ago", otherwise a one-decimal hour figure that drops
/// its trailing ".0" exactly like JS `Number#toString` does (`10 h ago`, not
/// `10.0 h ago`).
func ageLabel(from date: Date, now: Date) -> String {
    let mins = max(0, Int((now.timeIntervalSince(date) / 60).rounded()))
    if mins < 60 { return "\(mins) min ago" }
    let tenths = (Double(mins) / 6).rounded() / 10
    return "\(jsNumberString(tenths)) h ago"
}

// jsNumberString (the shared JS Number→string twin) lives in
// FleetLanesView.swift — Swift's `String(Double)` prints the shortest
// round-tripping decimal, the same rule JS uses, so one helper serves both
// the runway percent readout and ageLabel's tenths.

/// web/src/shell/Toolbar.tsx `pillLabel` (Toolbar.tsx:19-26). `FleetViewModel
/// .Status` has a fourth case, `.starting` (ensure-running in flight), that
/// the web's 3-value `Connection` type has no equivalent for — DEVIATION:
/// treated as `.connecting` here (both are transient, pre-live, ageless
/// states; neither is an error).
func connectivityPillLabel(status: FleetViewModel.Status, asOfAge: String?) -> String {
    switch status {
    case .live: return "Daemon active"
    case .connecting, .starting: return "Connecting"
    case .down: return asOfAge.map { "Daemon down — as of \($0)" } ?? "Daemon not running"
    }
}

/// The toolbar's daemon pill: dot + label, mirroring Toolbar.tsx's
/// `<i className={... bg-ok shadow ... : bg-graydot}>` (live glows green,
/// everything else is a flat gray dot — down is not red here, matching the
/// web exactly).
struct ConnectivityPill: View {
    let status: FleetViewModel.Status
    let asOfAge: String?

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(status == .live ? CockpitTheme.ok : CockpitTheme.grayDot)
                .frame(width: 7, height: 7)
                .shadow(color: status == .live ? CockpitTheme.ok.opacity(0.6) : .clear, radius: 3)
            Text(connectivityPillLabel(status: status, asOfAge: asOfAge))
                .font(.system(size: 11))
                .foregroundColor(CockpitTheme.sec)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .overlay(Capsule().stroke(CockpitTheme.hair, lineWidth: 1))
        // Toolbar.tsx:33 `data-tour="daemon"` — the tour's "it keeps running
        // without this window" step spotlights this pill.
        .tourAnchor("daemon")
        // The status dot has no text of its own — without combining, VO
        // would read it as an unlabeled image ahead of the label. One
        // element, one announcement, matching the visible pill.
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("connectivity-pill")
    }
}

/// web/src/App.tsx's two pre-board states (App.tsx:504-527): a hard-down
/// state before any state has ever loaded, and the connecting placeholder.
/// Once `state` exists at all, the caller keeps showing the board (staleness
/// is a lane-level concern, not a full-page one) — this view is only for
/// "nothing has ever loaded".
struct ConnectivityFullPageView: View {
    let status: FleetViewModel.Status

    var body: some View {
        Group {
            if status == .down {
                downState
            } else {
                Text("Connecting to the daemon…")
                    .font(.system(size: 12.5))
                    .foregroundColor(CockpitTheme.ter)
            }
        }
        .padding(24)
    }

    private var downState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Daemon not running — nothing here is live.")
                .font(.system(size: 12.5, weight: .semibold))
            (Text("Start it: ")
                + Text("llmpilot daemon install").font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                + Text(" (or foreground: ")
                + Text("llmpilot daemon run").font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                + Text("), then reload."))
                .font(.system(size: 12.5))
                .foregroundColor(CockpitTheme.sec)
        }
        .frame(maxWidth: 440, alignment: .leading)
    }
}

#Preview("Pill — live") {
    ConnectivityPill(status: .live, asOfAge: nil).padding()
}

#Preview("Pill — down with age") {
    ConnectivityPill(status: .down, asOfAge: "12 min ago").padding()
}

#Preview("Full page — down") {
    ConnectivityFullPageView(status: .down).frame(width: 480)
}

#Preview("Full page — connecting") {
    ConnectivityFullPageView(status: .connecting).frame(width: 480)
}
