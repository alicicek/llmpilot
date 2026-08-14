import SwiftUI

// Native port of web/src/pro/Education.tsx's ⑤ `WindowsScreen` — split out
// of EducationViews.swift (①/②) to keep both files under the chunk's
// ~400-line guidance. The board it draws reproduces Axis/ChargeBlock/
// NowLine's GRAMMAR at the education card's narrower scale (percent-of-day
// positioning), exactly as the source comment insists: those three are
// locked to geometry.ts's 1160px track, so their pixel spec is mirrored
// here rather than imported — the grammar is identical, the px-per-minute
// is not (Education.tsx:411-418). `eduSessionBucket`/`eduWeeklyBucket`
// (EducationViews.swift) are shared, file-scope-internal helpers.

struct WindowsScreen: View {
    let step: Int
    let total: Int
    var email: String?
    let onContinue: () -> Void
    var clock: EduClock = SystemEduClock()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        WindowsScreenBody(step: step, total: total, email: email, reducedMotion: reduceMotion, clock: clock, onContinue: onContinue)
            .id(reduceMotion)
    }
}

private struct WindowsScreenBody: View {
    let step: Int
    let total: Int
    let email: String?
    let reducedMotion: Bool
    let clock: EduClock
    let onContinue: () -> Void

    @StateObject private var beat: WindowsBeatModel

    init(step: Int, total: Int, email: String?, reducedMotion: Bool, clock: EduClock, onContinue: @escaping () -> Void) {
        self.step = step
        self.total = total
        self.email = email
        self.reducedMotion = reducedMotion
        self.clock = clock
        self.onContinue = onContinue
        _beat = StateObject(wrappedValue: WindowsBeatModel(reducedMotion: reducedMotion, clock: clock))
    }

    /// The board's OWN day (12:00 is where the drawn block ends, and the
    /// now-line is pinned at 10:20 inside it — owner 2026-08-12), not a
    /// `Date.now()` offset. Recomputed per body evaluation like the
    /// source's plain `const`, not frozen — both read "today" only.
    private var reset: Date { EducationMath.boardHour(12) }

    var body: some View {
        EducationFrame(
            step: step, total: total,
            headline: "Schedule sessions ", keyPhrase: "on autopilot", tail: ".",
            lede: "Book a 5-hour window on the board — it opens while you sleep, so you work with no disruptions.",
            // Design critique 2026-08-09 — unlike ①/②, this board used to
            // ship WITHOUT the illustrative-numbers note even though its
            // times/percent are fabricated beside a real account identity.
            // That's a trust error: mark it the same way.
            example: true,
            note: "Booked for 07:00 last night — running by the time you sat down.",
            continueLabel: "Compare free and Pro",
            onContinue: onContinue
        ) {
            board.padding(.top, 22)
        }
        .onAppear { beat.start() }
        .onDisappear { beat.stop() }
    }

    /// One combined VoiceOver sentence for the whole board (design critique
    /// 2026-08-09, accessibility item 6): the axis ticks, the charge
    /// block's watermark, and the now-line are all decorative/illustrative
    /// — collapsing the board to `.ignore` children (rather than `.contain`)
    /// keeps every one of them out of the AX tree without hiding each
    /// individually, and states the one fact that matters once.
    private var boardAccessibilitySummary: String {
        let identity = email ?? "Your Claude account"
        let statusPhrase =
            beat.opened ? "in use — a 5-hour window that opened on its own at 07:00 and resets at 12:00"
            : (beat.booked ? "a 5-hour window booked for 07:00" : "booking a 5-hour window for 07:00")
        return "\(identity) — \(statusPhrase). It is 10:20 now: the window opened before the day started, so the work never paused for a reset."
    }

    private var board: some View {
        VStack(spacing: 0) {
            axisRow
            bodyRow
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(CockpitTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(CockpitTheme.hairSoft, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(boardAccessibilitySummary)
        .accessibilityIdentifier("edu-windows-board")
    }

    private var axisRow: some View {
        GeometryReader { geo in
            let trackWidth = max(0, geo.size.width - EducationMath.windowsHeaderWidth)
            ZStack(alignment: .topLeading) {
                ForEach(0..<25, id: \.self) { h in
                    Rectangle().fill(CockpitTheme.hair).frame(width: 1, height: 5)
                        .position(x: EducationMath.windowsHeaderWidth + trackWidth * CGFloat(EducationMath.pctOfDay(h * 60) / 100), y: 30 - 2.5)
                }
                // `to: 22`, not 24 (audit 2026-08-11): the "22" label's slot
                // is where the "24h · local" caption sits, and the two
                // rendered on top of each other as "224h · local".
                ForEach(Array(stride(from: 0, to: 22, by: 2)), id: \.self) { h in
                    Text(String(format: "%02d", h))
                        .font(CockpitTheme.numeric(9.5))
                        .foregroundColor(CockpitTheme.ter)
                        .position(x: EducationMath.windowsHeaderWidth + trackWidth * CGFloat(EducationMath.pctOfDay(h * 60) / 100), y: 14)
                }
                Text("24h · local")
                    .font(CockpitTheme.numeric(9.5))
                    .foregroundColor(CockpitTheme.ter)
                    .position(x: geo.size.width - 26, y: 14)
            }
        }
        .frame(height: 30)
        .overlay(Rectangle().fill(CockpitTheme.hair).frame(height: 1), alignment: .bottom)
    }

    private var bodyRow: some View {
        HStack(spacing: 0) {
            header
            track
        }
        .frame(height: 98)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(email ?? "Your Claude account")
                .font(CockpitTheme.Onboarding.status.weight(.semibold))
                .lineLimit(1)
            HStack(spacing: 5) {
                Circle()
                    // Blue while merely booked (charging/booked is accent's
                    // MEANING), amber once in use — the same tone the wall's
                    // mid-window lane speaks.
                    .fill(beat.opened ? CockpitTheme.warnRaw : (beat.booked ? CockpitTheme.accent : CockpitTheme.grayDot))
                    .frame(width: 6, height: 6)
                    .animation(.easeInOut(duration: 0.2), value: beat.opened)
                Text(beat.opened ? "In use — resets 12:00" : (beat.booked ? "Booked — opens 07:00" : "Idle"))
                    .font(CockpitTheme.Onboarding.status)
                    .foregroundColor(CockpitTheme.sec)
                    .lineLimit(1)
                    // Status → in-use crossfades over 200ms rather than
                    // snapping (design critique 2026-08-09).
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: beat.opened)
                    .accessibilityIdentifier("edu-windows-status")
            }
            // 46% — mid-window usage, illustrative like every number here
            // (the example note below the board owns that disclosure).
            CockpitRunwayBar(bucket: eduSessionBucket(percent: beat.opened ? 46 : 0, resetsAt: reset), refAsOf: reset, stale: false)
                .padding(.top, 2)
        }
        .padding(.horizontal, 12)
        .padding(.top, 11)
        .frame(width: EducationMath.windowsHeaderWidth, height: 98, alignment: .top)
        .overlay(Rectangle().fill(CockpitTheme.hairSoft).frame(width: 1), alignment: .trailing)
    }

    private var track: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack(alignment: .topLeading) {
                // the wash: past-time overlay from 00:00 to the now-line.
                CockpitTheme.wash
                    .frame(width: w * CGFloat(EducationMath.pctOfDay(EducationMath.windowsNowMinutes) / 100), height: h)

                chargeBlock(trackWidth: w)
                nowLine(trackWidth: w, trackHeight: h)
            }
        }
    }

    private func chargeBlock(trackWidth w: CGFloat) -> some View {
        let left = w * CGFloat(EducationMath.pctOfDay(EducationMath.windowsBlockStartMinutes) / 100)
        let width = w * CGFloat(EducationMath.pctOfDay(EducationMath.windowsBlockEndMinutes - EducationMath.windowsBlockStartMinutes) / 100)
        return RoundedRectangle(cornerRadius: 7)
            .fill(LinearGradient(colors: [CockpitTheme.accA, CockpitTheme.accB], startPoint: .leading, endPoint: .trailing))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(CockpitTheme.accBd, lineWidth: 1))
            .overlay(
                Text("5:00")
                    .font(CockpitTheme.numeric(9, weight: .semibold))
                    .tracking(0.4)
                    .foregroundColor(CockpitTheme.accTx)
                    .opacity(0.55)
            )
            .frame(width: width, height: 30)
            // Opacity only — no scale (design critique 2026-08-09: the
            // scale-in read as spectacle, not product grammar).
            .opacity(beat.booked ? 1 : 0)
            .animation(.easeInOut(duration: 0.2), value: beat.booked)
            .position(x: left + width / 2, y: 30 + 15)
            .accessibilityIdentifier("edu-windows-block")
    }

    /// NowLine.tsx: the line spans the track's full height and its label
    /// bubble sits at the board's top edge, over the axis — `top:-22px`
    /// relative to THIS container's top, which lands it near the axis
    /// row's bottom (same overlap the real board has).
    private func nowLine(trackWidth w: CGFloat, trackHeight h: CGFloat) -> some View {
        let x = w * CGFloat(EducationMath.pctOfDay(EducationMath.windowsNowMinutes) / 100)
        return ZStack(alignment: .top) {
            Rectangle().fill(CockpitTheme.crit).opacity(0.9).frame(width: 1.5, height: h)
            Text(EducationMath.windowsNowLabel)
                .font(CockpitTheme.numeric(9.5, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 1)
                .background(Capsule().fill(CockpitTheme.critDeep))
                .fixedSize()
                .offset(y: -22)
        }
        .frame(height: h, alignment: .top)
        .position(x: x, y: h / 2)
        .accessibilityHidden(true)
    }
}
