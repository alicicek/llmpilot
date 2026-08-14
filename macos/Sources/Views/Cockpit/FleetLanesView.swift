import SwiftUI

// Native port of web/src/board/LaneHeader.tsx + web/src/board/RunwayBar.tsx —
// the fleet lanes: identity column (avatar, email, ACTIVE badge, SWITCH
// verb, pinned/watched copy) plus the runway-bar stack per account. Phase 1
// chunk B shipped this read-only; Phase 2 chunk A adds the SWITCH button
// (LaneHeader.tsx:68-96) wired to FleetViewModel.switchTo.
//
// Every date-bearing field on `AccountState`/`Bucket` already decodes to a
// Swift `Date` (API/Models.swift), but BoardTime's severity.ts port takes
// RFC3339 STRINGS — it re-derives local wall-clock fields from the string
// itself. `isoOut` bridges back: the daemon always marshals as_of in UTC
// (internal/daemon/daemon.go `time.Now().UTC()`), and re-encoding a decoded
// Date through the same UTC convention reproduces an equivalent wire string,
// so BoardTime's local-time reads (via the parsed instant) and its literal
// same-day prefix compare (via two values re-encoded through this one
// convention) both stay correct.
private let isoOut = ISO8601DateFormatter()

/// Converts a decoded `Date` back to an RFC3339 string for BoardTime's
/// string-based helpers. See the file header for why this round-trip is safe.
func boardTimeISOString(from date: Date) -> String { isoOut.string(from: date) }

// MARK: - avatar color (web/src/board/avatar.ts port)

/// Pure hash-math port of avatar.ts's `avatarStyle`: same id → same shift,
/// spread across 5 hues (0/72/144/216/288°) × 3 saturation multipliers
/// (85/100/115%). Split from `avatarColor` so the hash math is directly
/// unit-testable without a `Color`/`NSColor` round trip.
struct AvatarShift: Equatable {
    let hueDegrees: Double
    let saturationPercent: Double
}

func avatarShift(for id: String) -> AvatarShift {
    // JS: `hash = (hash * 31 + id.charCodeAt(i)) >>> 0` — UTF-16 code units,
    // unsigned 32-bit wraparound. `&*`/`&+` on UInt32 mirror `>>> 0` exactly.
    var hash: UInt32 = 0
    for unit in id.utf16 {
        hash = hash &* 31 &+ UInt32(unit)
    }
    let hue = Double((hash % 5) * 72)
    let sat = 85.0 + Double((hash % 3) * 15)
    return AvatarShift(hueDegrees: hue, saturationPercent: sat)
}

/// Applies the shift to the resolved `--accent` token (CockpitTheme.accent's
/// own light/dark hexes), appearance-aware. avatar.ts applies the shift as a
/// CSS `filter: hue-rotate(...) saturate(...)` on `var(--accent)`; CSS
/// hue-rotate is technically a rotation matrix, not a literal HSB hue add,
/// but an HSB hue-add + saturation-multiply is the documented "close, not
/// exact" native trade already used elsewhere (CockpitTheme's shadow-radius
/// mapping) and keeps this pure and testable.
/// JS's default Number→string: integral values print with no fraction
/// ("14"), fractional ones print as-is ("14.25") — how RunwayBar.tsx shows
/// `{bucket.percent}`.
func jsNumberString(_ n: Double) -> String {
    n == n.rounded() && abs(n) < 1e15
        ? String(Int64(n))
        : String(n)
}

func avatarColor(id: String, dark: Bool) -> Color {
    let shift = avatarShift(for: id)
    // CockpitTheme.accent: light #0a7aff, dark #0a84ff.
    let base = dark
        ? NSColor(red: 0x0a / 255, green: 0x84 / 255, blue: 0xff / 255, alpha: 1)
        : NSColor(red: 0x0a / 255, green: 0x7a / 255, blue: 0xff / 255, alpha: 1)
    var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    (base.usingColorSpace(.deviceRGB) ?? base).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
    let rotatedHue = ((h * 360 + shift.hueDegrees).truncatingRemainder(dividingBy: 360) + 360)
        .truncatingRemainder(dividingBy: 360) / 360
    let saturated = min(1, s * shift.saturationPercent / 100)
    return Color(nsColor: NSColor(hue: rotatedHue, saturation: saturated, brightness: b, alpha: 1))
}

// MARK: - status line derivation (LaneHeader.tsx lines 30-46)

/// Mirrors LaneHeader.tsx's `tokenNoteSevere`: a dead/expired sign-in reads
/// critical; anything else naming a token note (e.g. "expiring soon") reads
/// warn.
func tokenNoteSevere(_ note: String) -> Bool {
    note.contains("expired") || note.contains("sign-in")
}

/// Mirrors LaneHeader.tsx line 26: the daemon's authoritative stale mark OR
/// a snapshot old enough that BoardTime.isStale says so — either drains the
/// lane. `nowMinutes` is injected so tests can pin "now" without a clock.
func laneStale(accountStale: Bool?, snapshotAsOf: Date?, nowMinutes: Int) -> Bool {
    if accountStale == true { return true }
    guard let snapshotAsOf else { return false }
    return BoardTime.isStale(boardTimeISOString(from: snapshotAsOf), nowMinutes)
}

struct LaneStatusLine: Equatable {
    enum Dot: Equatable { case ok, warn, gray }
    var dot: Dot
    var text: String
    var progressPercent: Double?
    var timeLeft: String?
}

/// Mirrors LaneHeader.tsx lines 30-46 exactly, including the trailing
/// "stale always wins the dot" override on line 46.
func laneStatusLine(session: Bucket?, stale: Bool, nowMinutes: Int) -> LaneStatusLine {
    guard let session else {
        return LaneStatusLine(dot: .gray, text: "Nothing scheduled")
    }
    var line: LaneStatusLine
    if session.active == true, let resetsAt = session.resetsAt {
        let iso = boardTimeISOString(from: resetsAt)
        line = LaneStatusLine(
            dot: stale ? .gray : .warn,
            text: "Mid-window — resets \(BoardTime.fmtHMFromIso(iso))",
            progressPercent: session.percent,
            timeLeft: BoardTime.fmtDurationLeft(BoardTime.minutesUntil(iso, nowMinutes))
        )
    } else {
        line = LaneStatusLine(dot: stale ? .gray : .ok, text: "Idle — no active window")
    }
    if stale { line.dot = .gray }
    return line
}

private extension LaneStatusLine.Dot {
    var color: Color {
        switch self {
        case .ok: return CockpitTheme.ok
        case .warn: return CockpitTheme.warnRaw
        case .gray: return CockpitTheme.grayDot
        }
    }
}

// MARK: - runway row derivation (RunwayBar.tsx lines 22-28)

/// Mirrors RunwayBar.tsx's `resetText` derivation: same calendar day shows
/// just the time, otherwise the day name is prefixed.
func runwayResetText(resetsAt: Date?, refAsOf: Date) -> String? {
    guard let resetsAt else { return nil }
    let resetIso = boardTimeISOString(from: resetsAt)
    let refIso = boardTimeISOString(from: refAsOf)
    let hm = BoardTime.fmtHMFromIso(resetIso)
    if BoardTime.isSameDay(resetIso, refIso) { return "resets \(hm)" }
    return "resets \(BoardTime.fmtDowFromIso(resetIso)) \(hm)"
}

/// Mirrors LaneHeader.tsx:68's `!active && !account.pinned` guard: a switch
/// affordance renders only for a lane that is neither already active nor
/// pinned (pinned lanes show the pin icon and the daemon's 409-pinned copy
/// stays unreachable from here — see FleetLaneRow.showSwitch).
func switchButtonVisible(active: Bool, pinned: Bool) -> Bool {
    !active && !pinned
}

// MARK: - views

/// The read-only fleet lanes list: one `FleetLaneRow` per account, in the
/// order the daemon reports them (schedule-grid lanes are a separate
/// component, not part of this chunk).
struct FleetLanesView: View {
    let accounts: [AccountState]
    let activeID: String?
    let nowMinutes: Int
    /// The account currently mid-switch (FleetViewModel.switchingID) — every
    /// SWITCH button disables while this is non-nil (double-click race
    /// guard); the matching lane also swaps its label to "Switching…".
    /// Defaulted so the existing NativeCockpitRootView call site (owned by
    /// another chunk) keeps compiling unchanged.
    var switchingID: String? = nil
    var onSwitch: (String) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(accounts) { account in
                FleetLaneRow(
                    account: account, active: account.id == activeID, nowMinutes: nowMinutes,
                    switchingID: switchingID, onSwitch: onSwitch)
                if account.id != accounts.last?.id {
                    Divider().overlay(CockpitTheme.hairSoft)
                }
            }
        }
    }
}

/// One lane's identity column + runway stack (LaneHeader.tsx), including the
/// SWITCH verb (LaneHeader.tsx:68-96).
struct FleetLaneRow: View {
    let account: AccountState
    let active: Bool
    let nowMinutes: Int
    var switchingID: String? = nil
    var onSwitch: (String) -> Void = { _ in }

    @Environment(\.colorScheme) private var colorScheme

    /// LaneHeader.tsx:68 — a switch affordance renders only for a
    /// non-active, non-pinned lane; a pinned lane shows the pin icon and
    /// nothing else (the daemon's 409-pinned copy stays server-side only).
    private var showSwitch: Bool { switchButtonVisible(active: active, pinned: account.pinned) }
    private var isSwitching: Bool { switchingID == account.id }

    private var stale: Bool {
        laneStale(accountStale: account.stale, snapshotAsOf: account.snapshot?.asOf, nowMinutes: nowMinutes)
    }

    private var session: Bucket? {
        account.snapshot?.buckets.first { $0.kind == "session" }
    }

    private var statusLine: LaneStatusLine {
        laneStatusLine(session: session, stale: stale, nowMinutes: nowMinutes)
    }

    /// LaneHeader.tsx line 28: `(account.label || account.email || "?")`.
    private var avatarInitial: String {
        let source = account.label.isEmpty ? account.email : account.label
        return String((source.isEmpty ? "?" : source).prefix(1)).uppercased()
    }

    /// BEHAVIOR: email with a label fallback when empty (the web always
    /// renders `account.email` verbatim, but a blank lane identity is a
    /// worse failure mode natively — fall back to the label).
    private var displayEmail: String {
        account.email.isEmpty ? account.label : account.email
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(avatarColor(id: account.id, dark: colorScheme == .dark))
                .frame(width: 26, height: 26)
                .overlay(
                    Text(avatarInitial)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(displayEmail)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if active {
                        Text("ACTIVE")
                            .font(.system(size: 8.5, weight: .bold))
                            .tracking(0.4)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(CockpitTheme.okBg))
                            .foregroundColor(CockpitTheme.okTx)
                    }
                    if showSwitch {
                        Button(action: { onSwitch(account.id) }) {
                            Text(isSwitching ? "Switching…" : "Switch")
                                .textCase(.uppercase)
                                .font(.system(size: 9, weight: .bold))
                                .tracking(0.4)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 1)
                                .foregroundColor(CockpitTheme.accTx)
                                .background(Capsule().fill(CockpitTheme.accA))
                                .overlay(Capsule().stroke(CockpitTheme.accBd, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        // NATIVE IMPROVEMENT (deviation from LaneHeader.tsx,
                        // which has no in-flight guard): disable every
                        // switch button while ANY switch is in flight, not
                        // just this lane's — closes the double-click race
                        // the web leaves open. FleetViewModel.switchTo
                        // already no-ops a second call; this just surfaces
                        // that guard in the button state.
                        .disabled(switchingID != nil)
                        .opacity(switchingID != nil && !isSwitching ? 0.5 : 1)
                        .accessibilityIdentifier("switch-\(account.id)")
                        .accessibilityLabel("Switch to \(account.label.isEmpty ? account.email : account.label)")
                        // LaneHeader.tsx:73 `data-tour="switch"` — the tour's
                        // "move to an account with room" step.
                        .tourAnchor("switch")
                    }
                    if account.pinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9))
                            .foregroundColor(CockpitTheme.ter)
                            .accessibilityLabel("pinned")
                    }
                }

                HStack(spacing: 5) {
                    Circle().fill(statusLine.dot.color).frame(width: 6, height: 6)
                    Text(statusLine.text)
                        .font(.system(size: 10.5))
                        .foregroundColor(CockpitTheme.sec)
                        .lineLimit(1)
                }
                // The status dot alone carries no information for VO —
                // combine it into the same stop as the text it decorates.
                .accessibilityElement(children: .combine)

                if let note = account.tokenNote, !note.isEmpty {
                    Text(note)
                        .font(.system(size: 10))
                        .foregroundColor(tokenNoteSevere(note) ? CockpitTheme.crit : CockpitTheme.warn)
                }

                if let progressPercent = statusLine.progressPercent {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(CockpitTheme.hairSoft)
                        .frame(width: 128, height: 4)
                        .overlay(alignment: .leading) {
                            GeometryReader { geo in
                                RoundedRectangle(cornerRadius: 1)
                                    .fill(stale ? CockpitTheme.grayDot : CockpitTheme.warnRaw)
                                    .frame(width: geo.size.width * CGFloat(min(100, max(0, progressPercent))) / 100)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 1))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Time until reset")
                        .accessibilityValue(statusLine.timeLeft ?? "\(Int(progressPercent.rounded()))%")
                    if let timeLeft = statusLine.timeLeft {
                        Text(timeLeft)
                            .font(CockpitTheme.numeric(9.5))
                            .foregroundColor(CockpitTheme.ter)
                    }
                }

                if let snap = account.snapshot {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(snap.buckets.enumerated()), id: \.offset) { _, bucket in
                            CockpitRunwayBar(bucket: bucket, refAsOf: snap.asOf, stale: stale)
                        }
                    }
                    .padding(.top, 2)
                    // LaneHeader.tsx:119 `data-tour={active ? "runway" :
                    // undefined}` — only the ACTIVE lane's own numbers are
                    // the tour's "this is your real usage" target.
                    .tourAnchor("runway", when: active)
                    if stale {
                        Text(BoardTime.staleStamp(boardTimeISOString(from: snap.asOf), nowMinutes))
                            .font(.system(size: 9.5))
                            .foregroundColor(CockpitTheme.ter)
                    }
                }

                if !active, account.pinned {
                    Text("Watched — signs in from its own folder, usage only. Move it into the fleet " +
                        "from Add account to make it switchable.")
                        .font(.system(size: 10))
                        .foregroundColor(CockpitTheme.ter)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

/// One bucket row (RunwayBar.tsx): label · bar (with terminus tick from
/// warn up) · "N% · resets HH:MM". Richer than the popover's `RunwayBar`
/// (Views/RunwayBar.swift, untouched) — this is a new, cockpit-only
/// component; the popover bar is not reused or modified.
struct CockpitRunwayBar: View {
    let bucket: Bucket
    let refAsOf: Date
    let stale: Bool

    private var band: CockpitTheme.SeverityBand {
        CockpitTheme.severityBand(percent: bucket.percent, severity: bucket.severity)
    }

    private var fill: Color {
        stale ? CockpitTheme.ter : bandColor(band)
    }

    private func bandColor(_ band: CockpitTheme.SeverityBand) -> Color {
        switch band {
        case .calm: return CockpitTheme.ter
        case .warn: return CockpitTheme.warnRaw
        case .crit: return CockpitTheme.crit
        }
    }

    private var resetText: String? { runwayResetText(resetsAt: bucket.resetsAt, refAsOf: refAsOf) }

    var body: some View {
        HStack(spacing: 7) {
            Text(BoardTime.bucketLabel(kind: bucket.kind, scope: bucket.scope))
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(CockpitTheme.ter)
                .frame(width: 18, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .trailing) {
                    RoundedRectangle(cornerRadius: 1).fill(CockpitTheme.rail)
                    if bucket.percent >= 70 {
                        Rectangle()
                            .fill(CockpitTheme.ter.opacity(0.7))
                            .frame(width: 1.5)
                    }
                    HStack {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(fill)
                            .opacity(stale ? 0.4 : 1)
                            .frame(width: geo.size.width * CGFloat(min(100, max(0, bucket.percent))) / 100)
                        Spacer(minLength: 0)
                    }
                }
            }
            .frame(height: 8)

            // RunwayBar.tsx:49 renders the RAW percent — fractional values
            // like 14.25 are real (Bucket.percent's own doc) and the two
            // cockpits must agree on screen while both ship.
            Text("\(jsNumberString(bucket.percent))%\(resetText.map { " · \($0)" } ?? "")")
                .font(CockpitTheme.numeric(9.5))
                .foregroundColor(CockpitTheme.ter)
                .frame(width: 104, alignment: .trailing)
                .lineLimit(1)
        }
        // Same fix as the popover's RunwayBar: the fill/tick shapes carry
        // no text, so without combining, VO would land on an unlabeled
        // bar ahead of the label/percent stops.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(BoardTime.bucketLabel(kind: bucket.kind, scope: bucket.scope))
        .accessibilityValue("\(jsNumberString(bucket.percent))%\(resetText.map { ", \($0)" } ?? "")")
    }
}

// MARK: - previews

#Preview("Fleet lanes") {
    FleetLanesView(
        accounts: [
            AccountState.previewStub(
                id: "a1", label: "Ada", email: "ada@example.com", pinned: false, stale: false,
                sessionActive: true, sessionPercent: 62, weeklyPercent: 41
            ),
            AccountState.previewStub(
                id: "a2", label: "Watched", email: "watched@example.com", pinned: true, stale: false,
                sessionActive: false, sessionPercent: 0, weeklyPercent: 12
            ),
            AccountState.previewStub(
                id: "a3", label: "Stale", email: "stale@example.com", pinned: false, stale: true,
                sessionActive: true, sessionPercent: 91, weeklyPercent: 95
            ),
        ],
        activeID: "a1",
        nowMinutes: 14 * 60 + 32
    )
    .frame(width: 420)
    .padding()
}

/// Preview-only fixture builder — decodes through the real JSON path
/// (Models.swift has no memberwise `AccountState` init) so previews exercise
/// the same code production does.
private extension AccountState {
    static func previewStub(
        id: String, label: String, email: String, pinned: Bool, stale: Bool,
        sessionActive: Bool, sessionPercent: Double, weeklyPercent: Double
    ) -> AccountState {
        let resets = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3 * 3600))
        let json = """
        {"id":"\(id)","label":"\(label)","email":"\(email)","pinned":\(pinned),"stale":\(stale),
         "snapshot":{"as_of":"\(ISO8601DateFormatter().string(from: Date()))","buckets":[
           {"kind":"session","percent":\(sessionPercent),"resets_at":"\(resets)","active":\(sessionActive)},
           {"kind":"weekly_all","percent":\(weeklyPercent),"resets_at":"\(resets)"}
         ]}}
        """
        return try! DaemonDates.decoder().decode(AccountState.self, from: json.data(using: .utf8)!)
    }
}
