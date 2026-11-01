import Foundation

/// Plans an account's daily window starts from when you actually use Claude
/// Code (the analytics heatmap: tokens per weekday × local hour). The first
/// window starts three hours before your usual start, so its reset lands two
/// hours into your day; the next ones follow at the board's booking gap until
/// your day ends — a fresh limit while you work instead of five hours after
/// your first message.
enum HistoryPlan {
    struct Plan: Equatable {
        /// Usual start and end of your Claude Code day (end exclusive), hour
        /// of day.
        let startHour: Int
        let endHour: Int
        /// Daily window starts, minutes of day, in order.
        let starts: [Int]
        /// The resets those windows give you inside your usual day.
        let resetsInDay: [Int]
    }

    enum Outcome: Equatable {
        case plan(Plan)
        /// Fewer than `minActiveDays` days of use to judge from.
        case tooLittle
        /// Use around the clock: a fixed day does not fit — rolling does.
        case allDay
        /// A day so short that no reset lands inside it: one window covers
        /// it, and replacing the account's times would gain nothing.
        case shortDay
    }

    static let minActiveDays = 5
    /// An hour counts as part of your day at a fifth of your busiest hour.
    static let activeShare = 0.2
    /// The first window starts this long before your day.
    static let leadMinutes = 3 * 60

    static func make(hourWeekday: [[Int64]], activeDays: Int) -> Outcome {
        var heat = [Int64](repeating: 0, count: 24)
        for row in hourWeekday {
            for (h, v) in row.enumerated() where h < 24 { heat[h] += v }
        }
        guard activeDays >= minActiveDays, let peak = heat.max(), peak > 0 else { return .tooLittle }
        let active = heat.map { Double($0) >= Double(peak) * activeShare }
        guard active.contains(false) else { return .allDay }

        // The longest quiet stretch (wrapping midnight) ends where your day
        // begins.
        var bestStart = 0, bestLen = 0
        for s in 0..<24 where !active[s] && active[(s + 23) % 24] {
            var len = 0
            while len < 24 && !active[(s + len) % 24] { len += 1 }
            if len > bestLen { (bestStart, bestLen) = (s, len) }
        }
        let start = (bestStart + bestLen) % 24
        let dayMinutes = (24 - bestLen) * 60

        let window = BoardSchedule.windowHours * 60
        var starts: [Int] = []
        var resets: [Int] = []
        var rel = -leadMinutes // minutes from the start of your day
        // Up to the lane's four a day; never start a window in your last hour.
        while rel < dayMinutes - 60 && starts.count < 4 {
            starts.append(((start * 60 + rel) % BoardSchedule.dayMin + BoardSchedule.dayMin) % BoardSchedule.dayMin)
            let resetRel = rel + window
            if resetRel > 0 && resetRel < dayMinutes {
                resets.append((start * 60 + resetRel) % BoardSchedule.dayMin)
            }
            rel += BoardSchedule.minGapMin
        }
        if resets.isEmpty { return .shortDay }
        return .plan(Plan(startHour: start, endHour: (start * 60 + dayMinutes) / 60 % 24, starts: starts, resetsInDay: resets))
    }

    /// "06:00, 11:15 and 16:30".
    static func list(_ minutes: [Int]) -> String {
        let parts = minutes.map { BoardSchedule.fmtHM($0) }
        switch parts.count {
        case 0: return ""
        case 1: return parts[0]
        default: return parts.dropLast().joined(separator: ", ") + " and " + parts.last!
        }
    }
}
