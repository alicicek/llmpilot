import Foundation

/// Pure 1:1 port of web/src/board/classify.ts — per-lane schedule geometry
/// plus the honesty classification that drives chip dot color, suffix
/// copy, and trigger fine print. Derived entirely from (trigger, reset,
/// now, mid-window) — no hardcoded per-fixture cases, so it stays correct
/// for any board state the daemon sends. Cross-stack parity is pinned by
/// testdata/golden-vectors/board-classify.json.
///
/// The wire-shape `Schedule` is NOT redefined here — this port takes the
/// three fields `laneSchedules` actually reads (`id`, `accountID`,
/// `hour`/`minute`) as a lightweight `ScheduleInput`, same discipline as
/// `BoardTime.bucketLabel`'s narrowed-field deviation.
enum BoardClassify {
    /// web/src/board/classify.ts `laneSchedules`'s per-item input —
    /// mirrors web/src/schedule.ts `Schedule`'s fields `laneSchedules`
    /// reads (`id`, `account_id`, `hour`, `minute`).
    struct ScheduleInput: Equatable {
        let id: String
        let accountID: String
        let hour: Int
        let minute: Int
    }

    /// web/src/board/classify.ts `LaneSchedule`.
    struct LaneSchedule: Equatable {
        let schedule: ScheduleInput
        let trigger: Int
        let reset: Int
        /// trigger === the immediately-preceding (by reset order)
        /// schedule's reset.
        let chained: Bool
    }

    /// web/src/board/classify.ts `laneSchedules`. This lane's schedules
    /// sorted by reset time, with chain pairs detected.
    static func laneSchedules(schedules: [ScheduleInput], accountID: String) -> [LaneSchedule] {
        let mine = schedules
            .filter { $0.accountID == accountID }
            .map { s -> (schedule: ScheduleInput, trigger: Int, reset: Int) in
                (
                    schedule: s,
                    trigger: BoardSchedule.triggerMinutes(hour: s.hour, minute: s.minute),
                    reset: BoardSchedule.resetMinutes(hour: s.hour, minute: s.minute)
                )
            }
            .sorted { $0.reset < $1.reset }
        return mine.enumerated().map { i, m in
            if mine.count < 2 {
                return LaneSchedule(schedule: m.schedule, trigger: m.trigger, reset: m.reset, chained: false)
            }
            let prev = mine[(i - 1 + mine.count) % mine.count]
            let chained = prev.reset != m.reset && BoardSchedule.circularGap(m.trigger, prev.reset) == 0
            return LaneSchedule(schedule: m.schedule, trigger: m.trigger, reset: m.reset, chained: chained)
        }
    }

    /// web/src/board/classify.ts `MidWindow`. The lane's currently-active
    /// session window, if any.
    struct MidWindow: Equatable {
        let start: Int
        let end: Int
    }

    /// web/src/board/classify.ts `ChipClass`.
    enum ChipClass: String, Equatable {
        case ran, blocked, missed, charging, upcoming
    }

    /// web/src/board/classify.ts `inWindow`. EXCLUSIVE at the start: a
    /// trigger exactly AT the window's start is the chained trigger that
    /// OPENED it (fired on the previous reset), not one the window blocks.
    static func inWindow(_ t: Int, _ mid: MidWindow) -> Bool {
        t > mid.start && t < mid.end
    }

    /// web/src/board/classify.ts `classify`. Priority order: blocked (mid-
    /// window swallows the trigger) → ran (reset already happened, `<=`
    /// inclusive) → trigger already fired (`<=` inclusive: chained ?
    /// charging : missed) → upcoming.
    static func classify(_ ls: LaneSchedule, nowMinutes: Int, mid: MidWindow?) -> ChipClass {
        if let mid, inWindow(ls.trigger, mid) { return .blocked }
        if ls.reset <= nowMinutes { return .ran }
        if ls.trigger <= nowMinutes { return ls.chained ? .charging : .missed }
        return .upcoming
    }

    /// web/src/board/classify.ts `Dot`.
    enum Dot: String, Equatable {
        case gray, green, amber
    }

    /// web/src/board/classify.ts `chipDot`. green = chained/guaranteed
    /// (mechanism), wins over everything else; amber = an honesty-risk
    /// state is live right now (blocked/missed); gray = a standalone
    /// nudge, outcome TBD.
    static func chipDot(_ cls: ChipClass, chained: Bool) -> Dot {
        if chained { return .green }
        if cls == .blocked || cls == .missed { return .amber }
        return .gray
    }

    /// web/src/board/classify.ts `ChipCopy`.
    struct ChipCopy: Equatable {
        let suffix: String?
        let suffixTone: String // "ok" | "amber" | "sec"
        let trigLine: String
        let trigTone: String // "ter" | "amber"
    }

    /// web/src/board/classify.ts `chipCopy`. Copy strings verbatim,
    /// including the "blocked" branch's `retries`/`landsAt` math
    /// (`landsAt` = `mid.end + WINDOW_HOURS*60`, wrapped into the day).
    static func chipCopy(_ ls: LaneSchedule, _ cls: ChipClass, _ mid: MidWindow?) -> ChipCopy {
        let t = BoardSchedule.fmtHM(ls.trigger)
        switch cls {
        case .ran:
            return ChipCopy(
                suffix: "✓︎ ran today",
                suffixTone: "ok",
                trigLine: ls.chained ? "⛓︎ \(t) · rides the reset" : "▲︎ \(t)",
                trigTone: "ter"
            )
        case .blocked:
            let retries = BoardSchedule.fmtHM(mid!.end)
            let landsAt = BoardSchedule.fmtHM((mid!.end + BoardSchedule.windowHours * 60) % BoardSchedule.dayMin)
            return ChipCopy(
                suffix: "today ≈ \(landsAt) ⚠︎",
                suffixTone: "amber",
                trigLine: "▲︎ \(t) → blocked today · retries \(retries)",
                trigTone: "amber"
            )
        case .missed:
            return ChipCopy(
                suffix: "from tomorrow",
                suffixTone: "sec",
                trigLine: "▲︎ \(t) · missed today",
                trigTone: "amber"
            )
        case .charging:
            return ChipCopy(
                suffix: nil,
                suffixTone: "ok",
                trigLine: "⛓︎ \(t) · rides the reset",
                trigTone: "ter"
            )
        case .upcoming:
            return ChipCopy(
                suffix: ls.chained ? nil : "assumes idle",
                suffixTone: "sec",
                trigLine: ls.chained ? "⛓︎ \(t) · rides the reset" : "▲︎ \(t)",
                trigTone: "ter"
            )
        }
    }
}
