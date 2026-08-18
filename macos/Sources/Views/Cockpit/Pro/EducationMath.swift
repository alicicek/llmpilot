import Foundation

// Pure, non-SwiftUI helpers shared by the education screens
// (EducationViews.swift, SwitchDemoModel.swift) — split out so the date/
// percentage math is unit-testable without a view. Ports of
// web/src/pro/Education.tsx's free functions (`futureInstant`, `hhmm`,
// `boardHour`, `pctOfDay`) plus its ⑤-only board constants.

enum EducationMath {
    /// Education.tsx:46-50 `futureInstant` — an instant N hours from `now`,
    /// rounded DOWN to the start of that LOCAL hour (`d.setMinutes(0,0,0)`
    /// operates in JS's local-time representation). Always in the future
    /// for any `now` the caller actually passes at call time: a fixed
    /// wall-clock hour would quietly start claiming a reset time in the
    /// past for anyone opening the app later in the day, which is why the
    /// source computes it from `Date.now()` rather than a literal hour.
    /// `now` is injectable so tests don't depend on the wall clock.
    static func futureInstant(hoursFromNow: Int, now: Date = Date()) -> Date {
        let future = now.addingTimeInterval(TimeInterval(hoursFromNow) * 3600)
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day, .hour], from: future)
        return cal.date(from: comps) ?? future
    }

    /// Education.tsx:64-68 `boardHour` — ⑤'s board illustrates one fixed
    /// day, so its hours are TODAY's (device-local), not an offset from
    /// `now`. `now` is injectable so tests don't depend on the wall clock.
    static func boardHour(_ hour: Int, now: Date = Date()) -> Date {
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day], from: now)
        comps.hour = hour
        comps.minute = 0
        comps.second = 0
        comps.nanosecond = 0
        return cal.date(from: comps) ?? now
    }

    /// Education.tsx:52-60 `hhmm` — device-LOCAL HH:MM, 24-hour, matching
    /// both `RunwayBar`'s own reset formatting (`BoardTime.fmtHMFromIso`)
    /// and JS's `toLocaleTimeString([], { hour: "2-digit", minute:
    /// "2-digit", hour12: false })`.
    static func hhmm(_ date: Date) -> String {
        BoardTime.fmtHMFromIso(boardTimeISOString(from: date))
    }

    /// Education.tsx:420 `pctOfDay` — minutes-of-day as a percent of a full
    /// 24h day, used to place every ⑤ board element (axis ticks, the
    /// booked block, the now-line) as a fraction of the track's width.
    static func pctOfDay(_ minutes: Int) -> Double {
        Double(minutes) / (24 * 60) * 100
    }

    // MARK: - ⑤ WindowsScreen board constants (Education.tsx:419-424)

    /// The header column's fixed width — RunwayBar's own label columns
    /// (15px + 104px) are fixed, so the header keeps close to this width
    /// on purpose (take much off and the bar itself gets squeezed out).
    static let windowsHeaderWidth: CGFloat = 228
    /// 10:20 — the board's pinned now-line, INSIDE the drawn block (owner
    /// 2026-08-12: the story is "booked for 07:00, ends 12:00, it's 10:20
    /// and you're mid-window on a tank that opened on its own").
    static let windowsNowMinutes = 10 * 60 + 20
    static let windowsNowLabel = "10:20"
    /// The booked block's trigger (07:00) and reset (12:00) in minutes.
    static let windowsBlockStartMinutes = 7 * 60
    static let windowsBlockEndMinutes = 12 * 60

    // MARK: ⑤ axis labels — which hours survive at a given width

    /// Half the width of an "00" label at 9.5pt, plus breathing room.
    static let axisLabelHalfWidth: CGFloat = 12
    /// "24h · local", pinned centred at `boardWidth - 26`.
    static let axisCaptionWidth: CGFloat = 62
    /// Half the now-line's "10:20" pill. 27 (7pt of horizontal padding) also
    /// evicted the 08 label, which needs 20.3 or less to clear — measured,
    /// not guessed. Trimmed to 3pt of padding so it does not. 12 cannot be
    /// saved at any honest size: it needs 11.1, and "10:20" does not fit in
    /// a 22pt pill. It sits between 08 and 14 naming the exact time, so the
    /// gap reads as information rather than as missing labels.
    static let axisNowPillHalfWidth: CGFloat = 20
    /// Horizontal padding inside that pill — the knob the half-width above
    /// is a consequence of. Keep them in step.
    static let axisNowPillHPadding: CGFloat = 3

    /// Hours between axis labels. Eleven labels span the track at 2-hourly,
    /// so each slot is `trackWidth / 12` — the corridor's 332pt track gives
    /// 27.7pt, which is comfortable for a 9.5pt two-digit label. The first
    /// threshold here was 440, reasoned rather than rendered, and it thinned
    /// the corridor to 4-hourly for no reason (owner 2026-08-18 asked for
    /// the density back after seeing both side by side). 300pt keeps ~25pt a
    /// slot as the floor; below that the axis genuinely does need thinning.
    static func axisStep(trackWidth: CGFloat) -> Int {
        trackWidth >= 300 ? 2 : 4
    }

    /// The hour labels the axis can actually draw. Replaces the old
    /// `stride(from: 0, to: 22)` — that hard-coded 22 existed to stop the
    /// last label colliding with the "24h · local" caption (audit
    /// 2026-08-11: they rendered as "224h · local"), which only worked at
    /// one width. Narrowing the corridor to fit its content (owner
    /// 2026-08-18) broke it again in two places at once: "20" ran into the
    /// caption, and the now-line's "10:20" pill sat on top of "12". Both
    /// are the same rule — drop a label that would overlap something
    /// already pinned there — so both are decided here, from the geometry,
    /// rather than by a constant that has to be re-tuned per width.
    static func axisHours(trackWidth: CGFloat, boardWidth: CGFloat) -> [Int] {
        let x: (Int) -> CGFloat = { h in
            windowsHeaderWidth + trackWidth * CGFloat(pctOfDay(h * 60) / 100)
        }
        let nowX = windowsHeaderWidth + trackWidth * CGFloat(pctOfDay(windowsNowMinutes) / 100)
        let captionLeft = boardWidth - 26 - axisCaptionWidth / 2
        return stride(from: 0, to: 24, by: axisStep(trackWidth: trackWidth)).filter { h in
            let lx = x(h)
            guard lx + axisLabelHalfWidth <= captionLeft else { return false }
            return abs(lx - nowX) >= axisNowPillHalfWidth + axisLabelHalfWidth
        }
    }

    /// Education.tsx:73 `EXAMPLE_NOTE` — rendered under demo lanes whose
    /// numbers are illustrative, never live.
    static let exampleNote = "Example numbers — your live ones are on the board."
}
