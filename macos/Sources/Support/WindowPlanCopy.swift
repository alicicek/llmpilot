import Foundation

/// The account row's pace line, from the daemon's forecast for the open
/// 5-hour window (internal/daemon/forecast.go). Plain wording: when the
/// window reaches 100% at this pace, and whether that is before it resets.
enum PaceLine {
    struct Line: Equatable {
        let text: String
        /// A wall before the reset is worth the warn tone; anything else is
        /// a calm aside.
        let warn: Bool
    }

    static func line(_ forecast: BucketForecast?, resetsAt: Date?, now: Date = Date(), timeZone: TimeZone = .current) -> Line? {
        guard let forecast else { return nil }
        // The weekly forecast (accounts with no 5-hour limit) reads as the
        // week's pace, with the day in its times.
        let weekly = forecast.kind == "weekly_all" || forecast.kind == "seven_day"
        let pace = weekly ? "At this week's pace" : "At this pace"
        guard let wall = forecast.wallAt, forecast.beforeReset else {
            return Line(text: "\(pace) it resets before you hit 100%.", warn: false)
        }
        // A wall already behind us is a stale projection: the next poll says
        // where the window really is.
        guard wall > now else { return nil }
        var text = "\(pace) you hit 100% around \(weekly ? dayHM(wall, timeZone) : hm(wall, timeZone))"
        if let resetsAt, resetsAt > wall {
            text += ", \(roughDuration(resetsAt.timeIntervalSince(wall))) before it resets."
        } else {
            text += "."
        }
        return Line(text: text, warn: true)
    }

    /// "50 min" / "1 h 20 min" / "1 day 5 h" — the daemon's notice uses the
    /// same shape.
    static func roughDuration(_ seconds: TimeInterval) -> String {
        let m = Int((seconds / 60).rounded())
        if m < 60 { return "\(m) min" }
        if m >= 24 * 60 {
            let days = m / (24 * 60), h = m % (24 * 60) / 60
            let unit = days == 1 ? "day" : "days"
            return h == 0 ? "\(days) \(unit)" : "\(days) \(unit) \(h) h"
        }
        return m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min"
    }
}

/// What the account row offers for starting the next window.
enum PlanRow {
    enum OneTap: Equatable {
        /// "Start the next window at 18:30" — the open window's reset.
        case offer(at: Date)
        /// A one-tap is set: "Next window starts 18:30 · Cancel".
        case set(at: Date)
    }

    /// Rolling covers every reset, so it offers no one-tap. Otherwise a set
    /// one-tap shows; else the open window's reset is on offer; with no open
    /// window there is nothing to start at a reset (Fresh window books one).
    static func oneTap(plan: WindowPlan?, sessionReset: Date?, now: Date) -> OneTap? {
        if plan?.rolling == true { return nil }
        // Shown for as long as it is set, so it can always be cancelled (the
        // daemon drops one that could not fire near its time).
        if let at = plan?.nextAt { return .set(at: at) }
        if let reset = sessionReset, reset > now { return .offer(at: reset) }
        return nil
    }

    /// The caption under a rolling switch that is on. `signedIn`: Claude
    /// Code is signed in to this account where its windows start (the active
    /// account, or a watched one in its own folder) — otherwise the start
    /// waits for it.
    static func rollingCaption(sessionReset: Date?, now: Date, pausedDailyTimes: Bool, signedIn: Bool = true, timeZone: TimeZone = .current) -> String {
        var caption: String
        switch (sessionReset.map { $0 > now } ?? false, signedIn) {
        case (true, true):
            caption = "Next window starts \(hm(sessionReset!, timeZone))"
        case (true, false):
            caption = "Next window starts \(hm(sessionReset!, timeZone)) if Claude Code is signed in to this account then"
        case (false, true):
            caption = "Starting a window now"
        case (false, false):
            caption = "Starts a window once Claude Code is signed in to this account"
        }
        if pausedDailyTimes { caption += " · daily times paused" }
        return caption
    }
}

/// Where a rolling account's next windows sit on today's 24 h track: back
/// to back from the open window's reset — or from now, when no window is
/// open or its reset has already passed (the daemon is starting one) — as
/// minute-of-day starts up to midnight. A reset tomorrow draws nothing: the
/// open window covers the rest of today. The chain carries on past the day.
enum RollingChain {
    static func starts(reset: Date?, now: Date, calendar: Calendar = .current, windowMinutes: Int = 300) -> [Int] {
        func minutes(_ d: Date) -> Int {
            let c = calendar.dateComponents([.hour, .minute], from: d)
            return (c.hour ?? 0) * 60 + (c.minute ?? 0)
        }
        var start: Int
        if let reset, reset > now {
            guard calendar.isDate(reset, inSameDayAs: now) else { return [] }
            start = minutes(reset)
        } else {
            start = minutes(now)
        }
        var out: [Int] = []
        while start < 24 * 60 {
            out.append(start)
            start += windowMinutes
        }
        return out
    }
}

/// "Tue 14:00" in the given zone — a weekly time needs its day.
func dayHM(_ date: Date, _ timeZone: TimeZone = .current) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_GB")
    f.timeZone = timeZone
    f.dateFormat = "EEE HH:mm"
    return f.string(from: date)
}

/// "18:30" in the given zone — the board's 24 h clock.
func hm(_ date: Date, _ timeZone: TimeZone = .current) -> String {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = timeZone
    let c = cal.dateComponents([.hour, .minute], from: date)
    return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
}
