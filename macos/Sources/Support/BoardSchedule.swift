import Foundation

/// Pure 1:1 port of web/src/schedule.ts's pure math — the schedule-time
/// constants plus trigger/reset/format/gap/next-booking arithmetic. The
/// wire-shape `Schedule` and the `fetch*`/`create*`/`move*`/`delete*` I/O
/// calls are NOT ported here (the daemon's own `store.Schedule`-derived DTO
/// and the API client already exist elsewhere on this client, same
/// discipline as `HistoryVectorTests.swift`'s header note). Cross-stack
/// parity is pinned by testdata/golden-vectors/board-schedule.json — see
/// that directory's README for the convention.
enum BoardSchedule {
    /// web/src/schedule.ts `WINDOW_HOURS`.
    static let windowHours = 5

    /// web/src/schedule.ts `DAY_MIN`. Circular day math in
    /// minutes-since-midnight.
    static let dayMin = 24 * 60

    /// web/src/schedule.ts `MIN_GAP_MIN`. Resets must be >= 5h15m apart.
    static let minGapMin = 5 * 60 + 15

    /// web/src/schedule.ts `SNAP_MIN`.
    static let snapMin = 15

    /// web/src/schedule.ts `triggerMinutes`.
    static func triggerMinutes(hour: Int, minute: Int) -> Int {
        hour * 60 + minute
    }

    /// web/src/schedule.ts `resetMinutes`.
    static func resetMinutes(hour: Int, minute: Int) -> Int {
        (triggerMinutes(hour: hour, minute: minute) + windowHours * 60) % dayMin
    }

    /// web/src/schedule.ts `fmtHM`. Wraps `totalMinutes` into `[0, dayMin)`
    /// via the double-mod idiom (handles negative input the same as the
    /// web's `((m % DAY_MIN) + DAY_MIN) % DAY_MIN`) before splitting into
    /// zero-padded HH:MM.
    static func fmtHM(_ totalMinutes: Int) -> String {
        let m = ((totalMinutes % dayMin) + dayMin) % dayMin
        return String(format: "%02d:%02d", m / 60, m % 60)
    }

    /// web/src/schedule.ts `circularGap`. Shortest distance between two
    /// minutes-of-day values around the midnight seam.
    static func circularGap(_ aMin: Int, _ bMin: Int) -> Int {
        let d = abs(aMin - bMin) % dayMin
        return min(d, dayMin - d)
    }

    /// web/src/schedule.ts `nextBookableReset`. First snap-aligned reset
    /// time after `(now + window)` — and, for a mid-window account, after
    /// `(activeEnd + window)` too — that clears every existing reset by
    /// `minGapMin`. TRAP: `floorRaw` is NOT modded into `[0, dayMin)`
    /// before the `ceil`-to-snap that computes `start` — it can exceed
    /// `dayMin` (e.g. `now` near midnight plus the 5h window), and the
    /// following day-length scan (`start..<start+dayMin`) still finds the
    /// right day-relative slot because every `t` is re-modded via `t %
    /// dayMin` on each iteration. Returns nil when a full day's scan (every
    /// snap-aligned minute) finds no slot clearing the gap — a lane at its
    /// booking ceiling (max 4/day makes this reachable).
    static func nextBookableReset(
        nowMinutes: Int,
        existingResets: [Int],
        activeEndMinutes: Int?
    ) -> (hour: Int, minute: Int)? {
        let floorRaw = max(
            nowMinutes + windowHours * 60,
            activeEndMinutes != nil ? activeEndMinutes! + windowHours * 60 : 0
        )
        let start = Int(ceil(Double(floorRaw) / Double(snapMin))) * snapMin
        var t = start
        while t < start + dayMin {
            let m = t % dayMin
            if existingResets.allSatisfy({ circularGap($0, m) >= minGapMin }) {
                return (hour: m / 60, minute: m % 60)
            }
            t += snapMin
        }
        return nil // lane is full (max 4/day makes this reachable)
    }
}
