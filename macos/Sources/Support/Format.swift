import Foundation

/// Voice: digits always, HH:MM 24-hour, "·" separates facts, ≈ for estimates.
enum Format {
    static func clock(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// "resets 16:05" for today, "resets Wed 20:00" beyond today.
    static func resets(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return "resets \(clock(date, calendar: calendar))"
        }
        let fmt = DateFormatter()
        fmt.calendar = calendar
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "EEE"
        return "resets \(fmt.string(from: date)) \(clock(date, calendar: calendar))"
    }

    /// Stale stamp: "as of 4 min ago", "as of 2 h ago". Under a minute is live enough.
    static func asOf(_ asOf: Date, now: Date = Date()) -> String? {
        let age = now.timeIntervalSince(asOf)
        guard age >= 60 else { return nil }
        if age < 3600 { return "as of \(Int(age / 60)) min ago" }
        if age < 86400 { return "as of \(Int(age / 3600)) h ago" }
        return "as of \(Int(age / 86400)) d ago"
    }

    /// Privacy alias for an account at a fleet position: "acct 2/4".
    static func alias(index: Int, of total: Int) -> String {
        "acct \(index + 1)/\(total)"
    }

    static func percent(_ p: Int) -> String { "\(p)%" }
}
