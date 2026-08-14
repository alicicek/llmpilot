import AppKit
import SwiftUI

/// Pure derivation the view delegates to — a native port of
/// web/src/board/Inspector.tsx's inline math (dl-row values, the gap
/// ✓︎/⚠︎ split at MIN_GAP_MIN, the chain/catch-up labels) plus the five
/// independent boolean conditions that gate its state cards. Ported as
/// literal booleans, NOT re-derived "exclusivity" — Inspector.tsx's own
/// comment is explicit that the idle-dependency card and the ran card are
/// meant to co-occur, so this only reproduces each `{cond && <Card/>}` as
/// its own predicate.
enum BoardInspectorDerivation {
    struct Rows: Equatable {
        let autoNudge: String
        let chargesUnattended: String
        let freshAndFull: String
        /// nil exactly when `chainTarget == nil` (Inspector.tsx: the row is
        /// omitted, not blank).
        let gapToNextReset: String?
    }

    /// Inspector.tsx: `Row` values plus the "Gap to next reset" row, which
    /// only renders when `chainTarget != null`. `nextGap` is
    /// `circularGap(ls.reset, chainTarget)`; `✓︎` when it clears
    /// `MIN_GAP_MIN` (315), `⚠︎` otherwise — INCLUSIVE at exactly 315.
    static func rows(ls: BoardClassify.LaneSchedule, chainTarget: Int?) -> Rows {
        let trigger = BoardSchedule.fmtHM(ls.trigger)
        let reset = BoardSchedule.fmtHM(ls.reset)
        var gapRow: String?
        if let chainTarget {
            let nextGap = BoardSchedule.circularGap(ls.reset, chainTarget)
            let gapOk = nextGap >= BoardSchedule.minGapMin
            gapRow = "\(BoardSchedule.fmtHM(nextGap)) \(gapOk ? "✓︎" : "⚠︎")"
        }
        return Rows(
            autoNudge: trigger,
            chargesUnattended: "\(trigger) – \(reset)",
            freshAndFull: "from \(reset)",
            gapToNextReset: gapRow
        )
    }

    struct CardVisibility: Equatable {
        /// Inspector.tsx: `!ls.chained && cls !== "blocked"` — every
        /// standalone nudge carries the idle-dependency risk, missed-today
        /// or not; shown ALONGSIDE the ran card, never instead of it.
        let idleDependency: Bool
        /// Inspector.tsx: `cls === "blocked" && mid`.
        let blocked: Bool
        /// Inspector.tsx: `cls === "missed"`.
        let missed: Bool
        /// Inspector.tsx: `ls.chained`.
        let chained: Bool
        /// Inspector.tsx: `cls === "ran"`.
        let ran: Bool
    }

    static func cardVisibility(
        ls: BoardClassify.LaneSchedule,
        cls: BoardClassify.ChipClass,
        mid: BoardClassify.MidWindow?
    ) -> CardVisibility {
        CardVisibility(
            idleDependency: !ls.chained && cls != .blocked,
            blocked: cls == .blocked && mid != nil,
            missed: cls == .missed,
            chained: ls.chained,
            ran: cls == .ran
        )
    }

    /// Inspector.tsx: the headline dot — `cls === "blocked" || cls === "missed"`
    /// wins (amber/warnRaw), else chained (ok/green), else gray.
    static func dotColor(cls: BoardClassify.ChipClass, chained: Bool) -> Color {
        if cls == .blocked || cls == .missed { return CockpitTheme.warnRaw }
        if chained { return CockpitTheme.ok }
        return CockpitTheme.grayDot
    }

    /// Inspector.tsx `catchUp`: `fmtHM(nowMinutes + WINDOW_MIN)`.
    static func catchUpLabel(nowMinutes: Int) -> String {
        BoardSchedule.fmtHM(nowMinutes + BoardSchedule.windowHours * 60)
    }

    /// Inspector.tsx `chainResult`: `fmtHM((chainTarget + WINDOW_MIN) % DAY_MIN)`,
    /// nil when there is no chain target.
    static func chainResultLabel(chainTarget: Int?) -> String? {
        guard let chainTarget else { return nil }
        return BoardSchedule.fmtHM((chainTarget + BoardSchedule.windowHours * 60) % BoardSchedule.dayMin)
    }

    /// Inspector.tsx's blocked card: `mid.end` and `(mid.end + WINDOW_MIN) % DAY_MIN`.
    static func blockedLabels(mid: BoardClassify.MidWindow) -> (retries: String, landsAt: String) {
        let retries = BoardSchedule.fmtHM(mid.end)
        let landsAt = BoardSchedule.fmtHM((mid.end + BoardSchedule.windowHours * 60) % BoardSchedule.dayMin)
        return (retries, landsAt)
    }
}

/// Native port of web/src/board/Inspector.tsx — the board's contextual
/// panel: header email + "REPEATS DAILY", reset headline with the honesty
/// dot, the mini charge bar, the dl rows, the state cards, and the footer.
/// Slides in from the right (0.2s, cubic(0.4,0,0.2,1); duration 0 under
/// Reduce Motion) via `.transition`/`.animation` on this view itself, so the
/// integrator only needs to add/remove it from the tree (same shape as
/// Board.tsx's `{selected && <motion.div>…}`). Esc and outside-click both
/// close it, ported from Inspector.tsx's own document-level listeners as
/// local NSEvent monitors (AppKit has no DOM bubbling to hook instead).
struct BoardInspector: View {
    let email: String
    let ls: BoardClassify.LaneSchedule
    let cls: BoardClassify.ChipClass
    let mid: BoardClassify.MidWindow?
    let nowMinutes: Int
    let chainTarget: Int?
    let onChain: () -> Void
    let onDelete: () -> Void
    let onClose: () -> Void
    /// ±15-minute nudge. NATIVE ADDITION over the web Inspector, which only
    /// HINTS "← → move 15 min" at keyboard users: real buttons make the
    /// precise nudge reachable by mouse and by AX (AXPress on genuine
    /// buttons is the one invocation assistive drivers reliably deliver).
    var onNudge: (Int) -> Void = { _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var rows: BoardInspectorDerivation.Rows {
        BoardInspectorDerivation.rows(ls: ls, chainTarget: chainTarget)
    }
    private var visibility: BoardInspectorDerivation.CardVisibility {
        BoardInspectorDerivation.cardVisibility(ls: ls, cls: cls, mid: mid)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            header
            headline
            chargeBar
            dlRows
            cards
            Spacer(minLength: 0)
            footer
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: 302)
        .frame(maxHeight: .infinity)
        .background(CockpitTheme.panel)
        .overlay(Rectangle().fill(CockpitTheme.hair).frame(width: 1), alignment: .leading)
        .background(DismissMonitor(onClose: onClose))
        .transition(.move(edge: .trailing))
        .animation(reduceMotion ? nil : .timingCurve(0.4, 0, 0.2, 1, duration: 0.2), value: ls.schedule.id)
    }

    // MARK: - header / headline / charge bar

    private var header: some View {
        Text("\(email.uppercased()) — REPEATS DAILY")
            .font(.system(size: 9, weight: .bold))
            .tracking(0.7)
            .foregroundStyle(CockpitTheme.ter)
    }

    private var headline: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(BoardInspectorDerivation.dotColor(cls: cls, chained: ls.chained))
                .frame(width: 8, height: 8)
            Text("Fresh window at \(BoardSchedule.fmtHM(ls.reset))")
                .font(.system(size: 15, weight: .bold))
        }
    }

    private var chargeBar: some View {
        HStack(spacing: 7) {
            Text("▲︎ \(BoardSchedule.fmtHM(ls.trigger))")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(CockpitTheme.sec)
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(LinearGradient(colors: [CockpitTheme.accA, CockpitTheme.accB], startPoint: .leading, endPoint: .trailing))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(CockpitTheme.accBd, lineWidth: 1))
                Text("charges 5:00")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(CockpitTheme.accTx)
            }
            .frame(height: 14)
            Text("⚑︎ \(BoardSchedule.fmtHM(ls.reset))")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(CockpitTheme.ok)
        }
    }

    // MARK: - dl rows

    private var dlRows: some View {
        VStack(spacing: 0) {
            row("Auto-nudge", rows.autoNudge)
            row("Charges unattended", rows.chargesUnattended)
            row("Fresh & full", rows.freshAndFull)
            if let gap = rows.gapToNextReset {
                row("Gap to next reset", gap)
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 10.5)).foregroundStyle(CockpitTheme.sec)
            Spacer()
            Text(value).font(.system(size: 11, weight: .semibold))
        }
        .padding(.vertical, 6)
        .overlay(Rectangle().fill(CockpitTheme.hairSoft).frame(height: 1), alignment: .bottom)
    }

    // MARK: - state cards

    @ViewBuilder
    private var cards: some View {
        if visibility.idleDependency {
            idleDependencyCard
        }
        if visibility.blocked, let mid {
            blockedCard(mid: mid)
        }
        if visibility.missed {
            missedCard
        }
        if visibility.chained {
            chainedCard
        }
        if visibility.ran {
            ranCard
        }
    }

    private var idleDependencyCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Depends on you being idle at \(BoardSchedule.fmtHM(ls.trigger))")
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(CockpitTheme.warn)
            Text("If you're still working, the nudge yields and today's reset drifts up to 5 h late.")
                .font(.system(size: 10.5))
            HStack(spacing: 7) {
                if chainTarget != nil, let chainResult = BoardInspectorDerivation.chainResultLabel(chainTarget: chainTarget) {
                    Button("⛓︎ Chain at \(chainResult) — guaranteed", action: onChain)
                        .buttonStyle(.borderedProminent)
                        .tint(CockpitTheme.ok)
                        .controlSize(.small)
                }
                Button("Keep \(BoardSchedule.fmtHM(ls.reset))") {}
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(CockpitTheme.warnBg)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(CockpitTheme.warnBd, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func blockedCard(mid: BoardClassify.MidWindow) -> some View {
        let labels = BoardInspectorDerivation.blockedLabels(mid: mid)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Lands inside the active session")
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(CockpitTheme.warn)
            Text("The \(BoardSchedule.fmtHM(ls.trigger)) nudge can't fire while the account is mid-window. It retries the instant that session resets at \(labels.retries), landing ≈ \(labels.landsAt).")
                .font(.system(size: 10.5))
        }
        .padding(10)
        .background(CockpitTheme.warnBg)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(CockpitTheme.warnBd, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var missedCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            (Text("Today: ").font(.system(size: 10.5, weight: .semibold)).foregroundColor(CockpitTheme.sec)
                + Text("The \(BoardSchedule.fmtHM(ls.trigger)) nudge has already passed (now \(BoardSchedule.fmtHM(nowMinutes))), so the first run is tomorrow.")
                .font(.system(size: 10.5)))
            Text("One-off catch-up now → fresh ≈ \(BoardInspectorDerivation.catchUpLabel(nowMinutes: nowMinutes)) today")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(CockpitTheme.accTx.opacity(0.6))
                .help("lands with the autopilot hookup")
        }
        .padding(10)
        .background(CockpitTheme.hairSoft)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var chainedCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("⛓︎ Chained — guaranteed")
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(CockpitTheme.ok)
            Text("Rides the \(BoardSchedule.fmtHM(ls.trigger)) reset the instant it lands — no idle needed.")
                .font(.system(size: 10.5))
        }
        .padding(10)
        .background(CockpitTheme.okBg)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(CockpitTheme.okBd, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var ranCard: some View {
        (Text("✓︎ ran today").font(.system(size: 10.5, weight: .bold)).foregroundColor(CockpitTheme.ok)
            + Text(" — fresh since \(BoardSchedule.fmtHM(ls.reset)).").font(.system(size: 10.5)))
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CockpitTheme.okBg)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(CockpitTheme.okBd, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - footer

    private var footer: some View {
        HStack {
            Button("Remove reset", action: onDelete)
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(CockpitTheme.crit)
                .accessibilityIdentifier("inspector-remove")
            Spacer()
            Button("−15") { onNudge(-BoardSchedule.snapMin) }
                .buttonStyle(.plain)
                .font(CockpitTheme.numeric(10, weight: .semibold))
                .foregroundStyle(CockpitTheme.accTx)
                .accessibilityIdentifier("nudge-minus")
            Button("+15") { onNudge(BoardSchedule.snapMin) }
                .buttonStyle(.plain)
                .font(CockpitTheme.numeric(10, weight: .semibold))
                .foregroundStyle(CockpitTheme.accTx)
                .accessibilityIdentifier("nudge-plus")
            Text("← → move 15 min")
                .font(.system(size: 10))
                .foregroundStyle(CockpitTheme.ter)
        }
        .padding(.top, 10)
        .overlay(Rectangle().fill(CockpitTheme.hairSoft).frame(height: 1), alignment: .top)
    }
}

/// Installs the Esc + outside-click listeners Inspector.tsx's `useEffect`
/// wires via document-level `keydown`/`mousedown` — ported as local NSEvent
/// monitors scoped to this view's own NSView (a click is "outside" when it
/// falls outside this view's own bounds, converted to its own coordinate
/// space; AppKit has no DOM-style event bubbling to hook instead).
private struct DismissMonitor: NSViewRepresentable {
    let onClose: () -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.onClose = onClose
        return view
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        nsView.onClose = onClose
    }

    final class MonitorView: NSView {
        var onClose: (() -> Void)?
        private var keyMonitor: Any?
        private var clickMonitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            teardown()
            guard window != nil else { return }
            // Local monitors are APP-wide, not per-view: without the
            // same-window guards, an open sheet's Escape would be swallowed
            // here (the sheet becomes un-dismissable) and every click INSIDE
            // a sheet — a different window — would read as "outside" and
            // close the Inspector behind it.
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === self.window,
                      self.window?.isKeyWindow == true
                else { return event }
                if event.keyCode == 53 { // Escape
                    self.onClose?()
                    return nil
                }
                return event
            }
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                let locationInSelf = self.convert(event.locationInWindow, from: nil)
                if !self.bounds.contains(locationInSelf) {
                    self.onClose?()
                }
                return event
            }
        }

        private func teardown() {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
            keyMonitor = nil
            clickMonitor = nil
        }

        deinit { teardown() }
    }
}
