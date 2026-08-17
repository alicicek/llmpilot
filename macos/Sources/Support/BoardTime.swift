import Foundation

/// Pure port of web/src/board/severity.ts's non-color helpers — bucket
/// labeling, runway-time math, and the stale-snapshot rule. severity.ts's
/// OWN severity-banding logic (`bucketSeverity`) is already ported as
/// `CockpitTheme.severityBand` (Support/CockpitTheme.swift) — this file
/// does not duplicate it, only reuses its `SeverityBand` type below.
enum BoardTime {
    /// web/src/schedule.ts `DAY_MIN`, as re-exported/used by
    /// board/severity.ts. Circular day math in minutes-since-midnight.
    static let dayMin = 1440

    /// web/src/board/severity.ts `STALE_AFTER_MIN`.
    static let staleAfterMin = 10

    /// web/src/board/severity.ts `bucketLabel`. DEVIATION: the web
    /// function takes the whole `Bucket` object but only ever reads
    /// `.kind`/`.scope` — this port takes just those two fields directly so
    /// it stays callable without a full `Bucket` fixture (the existing
    /// Swift `Bucket`, API/Models.swift, requires `percent` and other
    /// fields `bucketLabel` itself never touches). `weekly_scoped` returns
    /// the UPPERCASED FIRST CHARACTER of scope (not the whole scope
    /// string); a missing or empty scope falls back to "?".
    static func bucketLabel(kind: String, scope: String?) -> String {
        if kind == "session" { return "5h" }
        if kind == "weekly_all" { return "wk" }
        if kind == "weekly_scoped" {
            guard let first = scope?.first else { return "?" }
            return String(first).uppercased()
        }
        return kind
    }

    /// The lane-column label: same as `bucketLabel` except a scoped bucket
    /// carries its WHOLE model name ("Fable", "Opus", "Sonnet"), capitalised.
    /// The one-letter web abbreviation read as truncation to a stranger
    /// (fresh-user audit 2026-08-16, F17: "F" for Fable next to "resets Tue
    /// 13:…"); the board column is sized for the full word now.
    static func laneLabel(kind: String, scope: String?) -> String {
        if kind == "weekly_scoped", let scope, !scope.isEmpty {
            return scope.prefix(1).uppercased() + scope.dropFirst()
        }
        return bucketLabel(kind: kind, scope: scope)
    }

    /// web/src/board/severity.ts `findingSeverity`. Reuses
    /// `CockpitTheme.SeverityBand` rather than inventing a parallel enum —
    /// the doctor panel's finding severities ride the SAME shipped
    /// severity trio. Any value other than "critical"/"warning" (including
    /// "info") falls through to `.calm` — an informational finding is calm
    /// on purpose, not an omission.
    static func findingSeverity(_ s: String) -> CockpitTheme.SeverityBand {
        switch s {
        case "critical": return .crit
        case "warning": return .warn
        default: return .calm
        }
    }

    /// web/src/board/severity.ts `minutesOfDay`. Device-LOCAL wall clock —
    /// mirrors JS `new Date(iso).getHours()`/`getMinutes()` (the browser's
    /// own timezone), which is the OPPOSITE rule from
    /// `HistoryFormat.hhmm`'s literal-offset-digit read. Do not unify the
    /// two code paths.
    static func minutesOfDay(_ iso: String) -> Int {
        guard let d = DaemonDates.parseRFC3339(iso) else { return 0 }
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    /// web/src/board/severity.ts `minutesAgo`. Minutes between an ISO
    /// instant's LOCAL time-of-day and `nowMinutes`, same-day, wrapping via
    /// `dayMin`.
    static func minutesAgo(_ iso: String, _ nowMinutes: Int) -> Int {
        let asOf = minutesOfDay(iso)
        let diff = nowMinutes - asOf
        return diff < 0 ? diff + dayMin : diff
    }

    /// web/src/board/severity.ts `minutesUntil`. Minutes from `nowMinutes`
    /// forward to an ISO instant's LOCAL time-of-day, same-day, wrapping.
    static func minutesUntil(_ iso: String, _ nowMinutes: Int) -> Int {
        let at = minutesOfDay(iso)
        let diff = at - nowMinutes
        return diff < 0 ? diff + dayMin : diff
    }

    /// web/src/board/severity.ts `fmtDurationLeft`.
    static func fmtDurationLeft(_ minutes: Int) -> String {
        let h = minutes / 60
        let m = minutes % 60
        return "\(h):\(String(format: "%02d", m)) left"
    }

    /// web/src/board/severity.ts `isStale`.
    static func isStale(_ asOf: String, _ nowMinutes: Int) -> Bool {
        minutesAgo(asOf, nowMinutes) > staleAfterMin
    }

    /// web/src/board/severity.ts `staleStamp`. Splits the timezone-
    /// dependent `minutesAgo` lookup from the pure formatting rule
    /// (`staleStampText(minutesAgo:)`) so the formatting half stays
    /// device-timezone-independent and vector-testable on its own — see
    /// testdata/golden-vectors/board-time.json's note.
    static func staleStamp(_ asOf: String, _ nowMinutes: Int) -> String {
        staleStampText(minutesAgo: minutesAgo(asOf, nowMinutes))
    }

    /// The formatting half of `staleStamp`, given an already-computed
    /// minutes-ago value: "as of Nm ago" under an hour, else "as of Nh ago"
    /// (rounded).
    static func staleStampText(minutesAgo mins: Int) -> String {
        if mins < 60 { return "as of \(mins)m ago" }
        return "as of \(Int(HistoryFormat.mathRound(Double(mins) / 60)))h ago"
    }

    /// web/src/board/severity.ts `isSameDay`. Literal ISO-string
    /// date-prefix compare (first 10 characters) — NOT a real "same
    /// calendar day" check across timezones, and NOT timezone-dependent
    /// either; matches `HistoryFormat`'s literal-offset-digit family, not
    /// this file's own local-wall-clock family used by `minutesOfDay` et
    /// al.
    static func isSameDay(_ iso: String, _ refIso: String) -> Bool {
        iso.prefix(10) == refIso.prefix(10)
    }

    /// web/src/board/severity.ts `fmtHMFromIso`. Device-LOCAL wall clock.
    static func fmtHMFromIso(_ iso: String) -> String {
        guard let d = DaemonDates.parseRFC3339(iso) else { return "00:00" }
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// web/src/board/severity.ts `fmtDowFromIso`. Device-LOCAL weekday,
    /// en-US short form ("Mon", "Tue", ...) — mirrors JS
    /// `toLocaleDateString("en-US", { weekday: "short" })`: the WEEKDAY
    /// NAME vocabulary is pinned to en-US, but which day it names still
    /// depends on the device's own timezone (calendar left as `.current`).
    static func fmtDowFromIso(_ iso: String) -> String {
        guard let d = DaemonDates.parseRFC3339(iso) else { return "" }
        let fmt = DateFormatter()
        fmt.calendar = Calendar.current
        fmt.timeZone = Calendar.current.timeZone
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "EEE"
        return fmt.string(from: d)
    }
}
