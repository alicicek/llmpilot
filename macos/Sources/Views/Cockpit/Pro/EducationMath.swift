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

    /// Education.tsx:73 `EXAMPLE_NOTE` — rendered under demo lanes whose
    /// numbers are illustrative, never live.
    static let exampleNote = "Example numbers — your live ones are on the board."
}
