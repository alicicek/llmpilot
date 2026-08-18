import SwiftUI

// Native port of web/src/pro/SwitchDemo.tsx's exported `SwitchDemo`
// component — the two lane rows + the narrative line. Deliberately
// UNWRAPPED (no StepDots/headline/Continue button): the source renders
// this bare inside Onboarding.tsx's own inline ④ section, which is
// flow-shell chrome out of this chunk's scope — the integration chunk
// supplies that wrapper and passes this view its `lanes`.
//
// Design critique 2026-08-09 — ④'s ONE job is to prove the automatic
// handoff. The donut gauge showed the same percentage THREE times (gauge
// readout, row percent, row percent again) and was onboarding-only
// spectacle, not shipped product grammar — removed entirely. What's left:
// one handoff panel, two compact rows (bar + a single trailing percent
// per row), sized to whatever copy column the caller gives this view (no
// fixed width hardcoded here), and a native replay control since the
// sequence now runs once and settles rather than looping forever.

struct SwitchDemoView: View {
    let lanes: [EduLane]
    var clock: EduClock = SystemEduClock()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        SwitchDemoBody(lanes: lanes, reducedMotion: reduceMotion, clock: clock)
            // Forces a fresh `SwitchDemoModel` (and its beat) whenever
            // reduced motion flips — mirrors the source effect's
            // `[reduced, lanes]` dependency array re-running from scratch.
            .id(reduceMotion)
    }
}

/// Groups the two lane rows into ONE coherent settled VoiceOver sentence
/// once the demo lands (`model.settled`); before that, VO walks each row as
/// its own element same as any other screen. The narrative line and the
/// replay control are SIBLINGS of this group (they share the row under the
/// lanes), so Replay stays independently reachable either way — and the
/// narrative line hides itself from VO once settled (see `narrativeLine`):
/// its settled text is the same sentence this group's label already reads.
private struct SwitchSummaryGrouping: ViewModifier {
    let settled: Bool
    let summary: String

    func body(content: Content) -> some View {
        if settled {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(summary)
        } else {
            content
                .accessibilityElement(children: .contain)
        }
    }
}

private struct SwitchDemoBody: View {
    let lanes: [EduLane]
    let reducedMotion: Bool
    let clock: EduClock

    @StateObject private var model: SwitchDemoModel

    init(lanes: [EduLane], reducedMotion: Bool, clock: EduClock) {
        self.lanes = lanes
        self.reducedMotion = reducedMotion
        self.clock = clock
        _model = StateObject(wrappedValue: SwitchDemoModel(lanes: lanes, reducedMotion: reducedMotion, clock: clock))
    }

    /// Every lane's bar colour follows the SHIPPED severity rule
    /// (`CockpitTheme.severityBand`, vector-pinned), so the demo never
    /// teaches a colour the board contradicts — no lane is forced green at
    /// high usage, and none is forced amber/red below the shipped
    /// thresholds.
    private func laneColor(_ percent: Int) -> Color {
        switch CockpitTheme.severityBand(percent: Double(percent)) {
        case .crit: return CockpitTheme.crit
        case .warn: return CockpitTheme.warnRaw
        case .calm: return CockpitTheme.ok
        }
    }

    private var voiceOverSummary: String {
        SwitchDemoModel.voiceOverSummary(lanes: lanes, spent: 0, next: 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 10) {
                laneRow(index: 0, lane: lanes[0], percent: model.percentA)
                laneRow(index: 1, lane: lanes[1], percent: model.percentB)
            }
            .modifier(SwitchSummaryGrouping(settled: model.settled, summary: voiceOverSummary))

            // The narrative line and Replay share ONE row (owner 2026-08-10):
            // as separate stacked rows the line was orphaned above a gap and
            // the replay control floated unattached below it, reading as an
            // unrelated spinner rather than "run that again".
            HStack(alignment: .firstTextBaseline, spacing: FlowLayout.footerControlSpacing) {
                narrativeLine
                Spacer(minLength: FlowLayout.footerControlSpacing)
                replayButton
            }
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        // `.contain` BEFORE the identifier (audit 2026-08-11): a bare
        // `.accessibilityIdentifier` on a plain VStack collapsed this whole
        // subtree into one identifier-only element in the AX tree — the
        // Replay button (and everything else in here) was unreachable by
        // identifier for the e2e walk and, more importantly, VoiceOver.
        // Every other corridor container that exposes children carries the
        // same explicit `.contain` (EducationFrame, the accounts list).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("edu-switch-demo")
    }

    private func laneRow(index i: Int, lane: EduLane, percent: Int) -> some View {
        let isActive = i == model.active
        let isResting = model.restingIndex == i
        return HStack(spacing: 10) {
            Text(lane.email)
                .font(CockpitTheme.Onboarding.controlLabel)
                .lineLimit(1)
                .frame(width: 132, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(CockpitTheme.rail)
                    Capsule()
                        .fill(laneColor(percent))
                        .frame(width: geo.size.width * CGFloat(min(100, max(0, percent))) / 100)
                        // F9 (2026-08-16 audit): the model now advances
                        // `percent` in small ticks (climbTickMs for A's
                        // 71→97 climb, creepTickMs for B's post-handoff
                        // creep) rather than one instant jump, so the
                        // number and the bar climb together. Easing each
                        // tick over the TICK interval (not the old fixed
                        // climbMs) keeps the fill smooth at both cadences
                        // instead of chasing an ever-moving target.
                        .animation(.easeInOut(duration: Double(SwitchDemoModel.climbTickMs) / 1000), value: percent)
                }
            }
            .frame(height: 6)
            trailing(isActive: isActive, isResting: isResting, percent: percent, lane: lane)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(CockpitTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(CockpitTheme.hairSoft, lineWidth: 1))
        // The Active chip moving to this row / this row going resting —
        // 200ms, matching the model's own `handoffMs`.
        .animation(.easeInOut(duration: Double(SwitchDemoModel.handoffMs) / 1000), value: isActive)
        .animation(.easeInOut(duration: Double(SwitchDemoModel.handoffMs) / 1000), value: isResting)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("edu-switch-lane-\(i)")
    }

    /// One percentage representation per row: an active/ready lane shows
    /// its trailing "N%" (plus a sentence-case "Active" chip when it's the
    /// active one); a rested lane trades its percent for a "Resets at HH:MM
    /// · ~3h" caption instead — never both.
    ///
    /// HARD swap between the two, never a crossfade: the row animates
    /// `isResting` for its chrome, and SwiftUI's default opacity transition
    /// drew the rest caption on top of "97% Active" for the swap's
    /// duration — the one number the demo exists to show was never cleanly
    /// legible and two lanes read Active at once (critic pass 2026-08-17).
    /// `.transition(.identity)` keeps the last climbing frame — 97% — as
    /// the last thing seen before the caption replaces it outright.
    @ViewBuilder
    private func trailing(isActive: Bool, isResting: Bool, percent: Int, lane: EduLane) -> some View {
        if isResting {
            Text(SwitchDemoModel.restCaption(resets: lane.resets, restsForMinutes: lane.restsForMinutes))
                .font(CockpitTheme.Onboarding.annotation)
                .foregroundColor(CockpitTheme.ter)
                .lineLimit(1)
                .frame(minWidth: 92, alignment: .trailing)
                .transition(.identity)
        } else {
            HStack(spacing: 6) {
                Text("\(percent)%")
                    .font(CockpitTheme.numeric(11, weight: .regular))
                    .foregroundColor(CockpitTheme.sec)
                    .frame(width: 34, alignment: .trailing)
                // Sentence case — the shipped voice never sets control/
                // status copy in all caps (design/VOICE.md).
                Text("Active")
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().stroke(CockpitTheme.okBd, lineWidth: 1).background(Capsule().fill(CockpitTheme.okBg)))
                    .foregroundColor(CockpitTheme.okTx)
                    .opacity(isActive ? 1 : 0)
            }
            .transition(.identity)
        }
    }

    /// Deliberately NOT a live region — VoiceOver's coverage here is the
    /// settled summary sentence (`SwitchSummaryGrouping`), not a running
    /// announcement of every intermediate line. AX-hidden once settled
    /// (review 2026-08-11 P2-5): the settled line and the group's summary
    /// are the same sentence, and exposing both read it twice.
    private var narrativeLine: some View {
        Text(model.line ?? " ")
            .font(CockpitTheme.Onboarding.status)
            .foregroundColor(CockpitTheme.text)
            .opacity(model.line == nil ? 0 : 1)
            .animation(.easeInOut(duration: 0.2), value: model.line)
            .frame(minHeight: 18, alignment: .leading)
            .accessibilityHidden(model.settled)
    }

    /// The demo runs once and settles (no infinite loop) — this is the
    /// only way to see it again. A NAMED control, not a bare glyph: as an
    /// unlabelled circular arrow it read as a spinner or an error badge
    /// (owner 2026-08-10) rather than an action, and nothing on screen said
    /// what it would do.
    private var replayButton: some View {
        Button("Replay", action: { model.start() })
            .pwGhost()
            // pwGhost is a custom ButtonStyle, which strips SwiftUI's
            // default AX exposure (same measured behaviour as the corridor's
            // primary — see EducationChrome) — name it explicitly.
            .accessibilityLabel("Replay the switch demo")
            .accessibilityIdentifier("edu-switch-replay")
    }
}
