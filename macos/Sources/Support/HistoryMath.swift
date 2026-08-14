import Foundation

// Pure 1:1 ports of the history charts' pure logic (web/src/history/*.ts plus
// the pure helpers embedded in the chart components). Every function name
// here mirrors its web counterpart exactly so a reader can jump straight
// across stacks. Cross-stack parity is pinned by the vector files under
// testdata/golden-vectors/ — see that directory's README for the convention.
//
// AnalyticsCell/AnalyticsTokens/HistorySample are NOT redefined here — they
// already exist as the daemon's wire types in API/CockpitModels.swift and
// are reused as-is (same discipline as everywhere else on this client).

// MARK: - HistoryPricing (web/src/history/pricing.ts)

enum HistoryPricing {
    /// web/src/history/pricing.ts `Price`. Per-1M-token USD.
    struct Price: Equatable {
        let input: Double
        let output: Double
    }

    /// web/src/history/pricing.ts `TABLE`.
    ///
    /// TRAP: the web file's own comment claims "longest prefix, first" but
    /// the actual code is a plain linear scan returning the FIRST entry (in
    /// listed/declaration order) whose prefix matches — not the longest
    /// matching prefix. This port mirrors the LOOP, not the comment. With
    /// today's table there is no actual prefix collision to observe
    /// (`"claude-haiku"` and `"claude-3-5-haiku"` are not prefixes of each
    /// other, and both happen to price identically anyway) — so today the
    /// two interpretations agree. A future table entry could make the
    /// distinction observable; if that happens, keep this a listed-order
    /// scan, matching the web source, not a "helpfully" sorted one.
    static let table: [(prefix: String, price: Price)] = [
        ("claude-fable-5", Price(input: 10, output: 50)),
        ("claude-mythos-5", Price(input: 10, output: 50)),
        ("claude-opus", Price(input: 5, output: 25)),
        ("claude-sonnet", Price(input: 3, output: 15)),
        ("claude-haiku", Price(input: 1, output: 5)),
        ("claude-3-5-haiku", Price(input: 1, output: 5)),
    ]

    /// web/src/history/pricing.ts `priceFor`. Case-SENSITIVE prefix match
    /// (JS `String.startsWith` never lowercases) — unlike
    /// `HistoryColors.familyOf`, which lowercases the id first. An unknown
    /// model returns nil (UNPRICED), never a guessed price.
    static func priceFor(_ modelID: String) -> Price? {
        for (prefix, price) in table where modelID.hasPrefix(prefix) {
            return price
        }
        return nil
    }

    /// web/src/history/pricing.ts `valueOf`. Cache-creation tokens price at
    /// 1.25x input; cache-read tokens price at 0.1x input — both anchored
    /// to the SAME model's input price, never its output price. nil when
    /// the model is unpriced.
    static func valueOf(_ modelID: String, _ t: AnalyticsTokens) -> Double? {
        guard let p = priceFor(modelID) else { return nil }
        let m = 1_000_000.0
        return (Double(t.input) / m) * p.input
            + (Double(t.output) / m) * p.output
            + (Double(t.cacheCreation) / m) * p.input * 1.25
            + (Double(t.cacheRead) / m) * p.input * 0.1
    }
}

// MARK: - HistoryAggregate (web/src/history/aggregate.ts, Projects.tsx, ModelMix.tsx)

enum HistoryAggregate {
    /// web/src/history/aggregate.ts `totalTokens`. Sums ALL FOUR token
    /// fields — feeds `groupByProject`.
    static func totalTokens(_ t: AnalyticsTokens) -> Int64 {
        t.input + t.output + t.cacheCreation + t.cacheRead
    }

    /// web/src/history/aggregate.ts `ioTokens`. Sums input+output ONLY,
    /// ignoring both cache fields — feeds `groupByFamily`. Asymmetric with
    /// `totalTokens` BY DESIGN (the model-mix chart tracks live in/out
    /// tokens; the project bar tracks the full spend footprint) — do not
    /// "fix" one to match the other.
    static func ioTokens(_ t: AnalyticsTokens) -> Int64 {
        t.input + t.output
    }

    struct ValueSummary: Equatable {
        var total: Double
        var unpricedIds: Set<String>
    }

    /// web/src/history/aggregate.ts `valueSummary`. Unpriced cells are
    /// excluded from `total` and named honestly in `unpricedIds`, never
    /// silently priced.
    static func valueSummary(_ cells: [AnalyticsCell]) -> ValueSummary {
        var total = 0.0
        var unpricedIds = Set<String>()
        for c in cells {
            if let v = HistoryPricing.valueOf(c.model, c.tokens) {
                total += v
            } else {
                unpricedIds.insert(c.model)
            }
        }
        return ValueSummary(total: total, unpricedIds: unpricedIds)
    }

    struct FamilyGroup: Equatable {
        var family: String
        var tokens: Int64
        var value: Double
        var unpricedIds: Set<String>
    }

    /// web/src/history/aggregate.ts `groupByFamily`. `tokens` is the
    /// `ioTokens` sum (input+output only) — see `ioTokens`'s own trap note.
    /// Iteration order of the returned array mirrors the web `Map`'s
    /// insertion order (first-seen family, in cell order).
    static func groupByFamily(_ cells: [AnalyticsCell]) -> [FamilyGroup] {
        var byFamily: [String: FamilyGroup] = [:]
        var order: [String] = []
        for c in cells {
            let family = HistoryColors.familyOf(c.model)
            if byFamily[family] == nil {
                byFamily[family] = FamilyGroup(family: family, tokens: 0, value: 0, unpricedIds: [])
                order.append(family)
            }
            byFamily[family]?.tokens += ioTokens(c.tokens)
            if let v = HistoryPricing.valueOf(c.model, c.tokens) {
                byFamily[family]?.value += v
            } else {
                byFamily[family]?.unpricedIds.insert(c.model)
            }
        }
        return order.compactMap { byFamily[$0] }
    }

    struct ProjectGroup: Equatable {
        var project: String
        var tokens: Int64
        var value: Double
    }

    /// web/src/history/aggregate.ts `groupByProject`. `tokens` is the
    /// `totalTokens` sum (all four fields) — asymmetric with
    /// `groupByFamily` BY DESIGN. Unlike `FamilyGroup`, `ProjectGroup`
    /// carries NO `unpricedIds` — the web source's `ProjectGroup` interface
    /// simply has no such field; an unpriced cell's tokens still count
    /// toward the group, its dollars just don't reach `value`.
    static func groupByProject(_ cells: [AnalyticsCell]) -> [ProjectGroup] {
        var byProject: [String: ProjectGroup] = [:]
        var order: [String] = []
        for c in cells {
            if byProject[c.project] == nil {
                byProject[c.project] = ProjectGroup(project: c.project, tokens: 0, value: 0)
                order.append(c.project)
            }
            byProject[c.project]?.tokens += totalTokens(c.tokens)
            if let v = HistoryPricing.valueOf(c.model, c.tokens) {
                byProject[c.project]?.value += v
            }
        }
        return order.compactMap { byProject[$0] }
    }

    struct Segment: Equatable {
        var family: String
        var tokens: Int64
        var value: Double
        var unpricedIds: Set<String>
    }

    /// web/src/history/ModelMix.tsx `buildSegments` (module-private there;
    /// exported for this port's tests, same posture as the web export
    /// added at the bottom of that file). Known families
    /// (`HistoryColors.FAMILY_ORDER`) keep their own segment ONLY if their
    /// `tokens > 0`; every unknown family folds into one "Other" segment,
    /// itself dropped entirely if the combined unknown tokens are 0.
    static func buildSegments(_ groups: [FamilyGroup]) -> [Segment] {
        // ModelMix.tsx:19-21 is find-FIRST-then-filter: a duplicate family
        // whose first entry has zero tokens is dropped even if a later
        // duplicate has tokens. Unreachable from groupByFamily (one group
        // per family) but this exported function must match on any input.
        let known = HistoryColors.FAMILY_ORDER.compactMap { family in
            groups.first { $0.family == family }
        }.filter { $0.tokens > 0 }
        let unknown = groups.filter { !HistoryColors.FAMILY_ORDER.contains($0.family) }
        var segments = known.map {
            Segment(family: $0.family, tokens: $0.tokens, value: $0.value, unpricedIds: $0.unpricedIds)
        }
        if !unknown.isEmpty {
            var other = Segment(family: HistoryColors.OTHER_FAMILY, tokens: 0, value: 0, unpricedIds: [])
            for g in unknown {
                other.tokens += g.tokens
                other.value += g.value
                other.unpricedIds.formUnion(g.unpricedIds)
            }
            if other.tokens > 0 { segments.append(other) }
        }
        return segments
    }

    struct TopProjects: Equatable {
        var rows: [ProjectGroup]
        var otherCount: Int
        var otherTokens: Int64
    }

    private static let topN = 5

    /// web/src/history/Projects.tsx `topProjects`. Sorted desc by tokens;
    /// TOP_N=5 kept as `rows`, the remainder folded into
    /// `otherCount`/`otherTokens`.
    static func topProjects(_ cells: [AnalyticsCell]) -> TopProjects {
        let groups = groupByProject(cells).sorted { $0.tokens > $1.tokens }
        let rows = Array(groups.prefix(topN))
        let rest = groups.dropFirst(topN)
        let otherTokens = rest.reduce(Int64(0)) { $0 + $1.tokens }
        return TopProjects(rows: rows, otherCount: rest.count, otherTokens: otherTokens)
    }
}

// MARK: - HistoryFormat (web/src/history/format.ts)

enum HistoryFormat {
    /// JS `Math.round`: rounds half AWAY FROM zero for positives but
    /// TOWARD +infinity for negatives (`Math.round(-0.5) === -0`,
    /// `Math.round(-1.5) === -1`) — NOT Swift's `.rounded()` default
    /// (`.toNearestOrAwayFromZero`, which would give -2 for -1.5). This is
    /// the ECMA-262 definition, `floor(x + 0.5)`, reproduced exactly.
    static func mathRound(_ x: Double) -> Double {
        (x + 0.5).rounded(.down)
    }

    /// JS `Number.prototype.toFixed(digits)`, reproduced via `mathRound`
    /// at the target scale rather than trusting `String(format:)`'s
    /// platform-specific rounding to agree with the JS engine's.
    static func fixed(_ n: Double, _ digits: Int) -> String {
        let scale = pow(10.0, Double(digits))
        let scaled = mathRound(n * scale) / scale
        return String(format: "%.\(digits)f", scaled)
    }

    /// JS `Math.round(n).toLocaleString("en-US")`. Pins `Locale(identifier:
    /// "en_US")` explicitly — the web call pins "en-US" too, independent of
    /// the browser's own locale, so this must NEVER read `Locale.current`.
    static func enUSInt(_ n: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.maximumFractionDigits = 0
        formatter.minimumFractionDigits = 0
        return formatter.string(from: NSNumber(value: n)) ?? String(Int64(n))
    }

    /// web/src/history/format.ts `formatTokens`. Threshold boundaries:
    /// 1e6 switches to "M", 1e7 drops to 0 decimals; 1e3 switches to "K",
    /// 1e4 drops to 0 decimals; below 1e3, an en-US-grouped rounded
    /// integer (never triggers a thousands separator in practice, since
    /// the branch above catches abs >= 1000).
    static func formatTokens(_ n: Double) -> String {
        let mag = abs(n)
        if mag >= 1_000_000 {
            let digits = mag >= 10_000_000 ? 0 : 1
            return "\(fixed(n / 1_000_000, digits))M"
        }
        if mag >= 1_000 {
            let digits = mag >= 10_000 ? 0 : 1
            return "\(fixed(n / 1_000, digits))K"
        }
        return enUSInt(mathRound(n))
    }

    /// web/src/history/format.ts `formatUSD`. >= 1000: rounded + en-US
    /// thousands separators. >= 100 (and < 1000): 0 decimals. Else: 2
    /// decimals. `approx` (default true) prepends "≈ ".
    static func formatUSD(_ n: Double, approx: Bool = true) -> String {
        let v = abs(n) >= 1000 ? enUSInt(mathRound(n)) : fixed(n, n >= 100 ? 0 : 2)
        return "\(approx ? "≈ " : "")$\(v)"
    }

    /// web/src/history/format.ts `formatPercent`.
    static func formatPercent(_ n: Double) -> String {
        "\(Int(mathRound(n)))%"
    }

    private static let hhmmRegex = try! NSRegularExpression(pattern: "T(\\d{2}):(\\d{2})")

    /// web/src/history/format.ts `hhmm`. Reads the ISO string's LITERAL
    /// digits after "T" — never parses/converts the instant. Empty string
    /// when the pattern isn't found (malformed input), matching the web's
    /// `m ? ... : ""`.
    static func hhmm(_ iso: String) -> String {
        let ns = iso as NSString
        guard let m = hhmmRegex.firstMatch(in: iso, range: NSRange(location: 0, length: ns.length)) else {
            return ""
        }
        return "\(ns.substring(with: m.range(at: 1))):\(ns.substring(with: m.range(at: 2)))"
    }

    private static let offsetRegex = try! NSRegularExpression(pattern: "([+-])(\\d{2}):(\\d{2})$")

    /// web/src/history/format.ts `isoOffsetMinutes`. Reads the trailing
    /// literal `±HH:MM` digits; 0 when absent (e.g. a "Z"-suffixed or
    /// malformed string) — never a real timezone-database lookup.
    static func isoOffsetMinutes(_ iso: String) -> Int {
        let ns = iso as NSString
        guard let m = offsetRegex.firstMatch(in: iso, range: NSRange(location: 0, length: ns.length)) else {
            return 0
        }
        let sign = ns.substring(with: m.range(at: 1)) == "-" ? -1 : 1
        let hh = Int(ns.substring(with: m.range(at: 2))) ?? 0
        let mm = Int(ns.substring(with: m.range(at: 3))) ?? 0
        return sign * (hh * 60 + mm)
    }

    /// web/src/history/format.ts `hhmmAtEpoch`. UTC components of
    /// `epochMs + offsetMinutes*60_000` — the derived-timestamp counterpart
    /// to `hhmm`'s literal-digit read, for epoch values with no ISO string
    /// of their own (e.g. a projected wall-clock time).
    static func hhmmAtEpoch(_ epochMs: Double, _ offsetMinutes: Int) -> String {
        let totalMs = epochMs + Double(offsetMinutes) * 60_000
        let date = Date(timeIntervalSince1970: totalMs / 1000)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// web/src/history/format.ts `dateOnly`. First 10 characters
    /// ("YYYY-MM-DD") of the ISO string — a literal substring, not a parse.
    static func dateOnly(_ iso: String) -> String {
        String(iso.prefix(10))
    }

    private static let dateOnlyFormatter: DateFormatter = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = cal.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// web/src/history/format.ts `addDays`. UTC date arithmetic on a
    /// date-only string (no time-of-day, no local timezone involved).
    static func addDays(_ dateStr: String, _ days: Int) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        guard let d = dateOnlyFormatter.date(from: dateStr),
              let shifted = cal.date(byAdding: .day, value: days, to: d)
        else { return dateStr }
        return dateOnlyFormatter.string(from: shifted)
    }

    /// web/src/history/format.ts `RANGE_DAYS`.
    static let rangeDays: [String: Int] = ["today": 1, "7d": 7, "30d": 30, "1y": 365]
}

// MARK: - BurnMath (web/src/history/burnMath.ts, BurnRate.tsx projectWallMs)

enum BurnMath {
    /// web/src/history/burnMath.ts `hoursWithActivityToday`. TRAP: floors
    /// at 1 via `max(1, hours)` even for an all-zero weekday row — a quiet
    /// day still divides by at least 1, never by zero. Weekday index is
    /// `getUTCDay` on the date-only string (0 = Sunday), matching
    /// `hour_weekday`'s own row indexing (7 rows, Sunday=0).
    static func hoursWithActivityToday(_ hourWeekday: [[Int64]], _ todayDateStr: String) -> Int {
        let weekday = utcWeekday(fromDateOnly: todayDateStr)
        let row = (weekday >= 0 && weekday < hourWeekday.count) ? hourWeekday[weekday] : []
        let hours = row.filter { $0 > 0 }.count
        return max(1, hours)
    }

    /// web/src/history/burnMath.ts `hourlyRate`.
    static func hourlyRate(_ cellsToday: [AnalyticsCell], _ activityHours: Int) -> Double {
        let total = HistoryAggregate.valueSummary(cellsToday).total
        return activityHours > 0 ? total / Double(activityHours) : 0
    }

    private static func utcWeekday(fromDateOnly dateStr: String) -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = cal.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: dateStr) else { return -1 }
        // Calendar.weekday is 1=Sunday...7=Saturday; JS getUTCDay is 0=Sunday.
        return cal.component(.weekday, from: d) - 1
    }

    /// web/src/history/BurnRate.tsx `projectWallMs`. Linear fit (least
    /// squares) over the last ~30 min of samples (`<=`, inclusive), or the
    /// final two samples overall when fewer than 2 fall in that window;
    /// needs >= 2 points total; a non-positive slope (flat or decreasing
    /// burn) has no meaningful "hit the wall" time, so nil rather than a
    /// stale/misleading answer. Returned value is epoch milliseconds.
    static func projectWallMs(_ samples: [HistorySample]) -> Double? {
        guard samples.count >= 2 else { return nil }
        let lastMs = samples[samples.count - 1].at.timeIntervalSince1970 * 1000
        let recent = samples.filter { lastMs - $0.at.timeIntervalSince1970 * 1000 <= 30 * 60_000 }
        let pts = recent.count >= 2 ? recent : Array(samples.suffix(2))
        let x0 = pts[0].at.timeIntervalSince1970 * 1000
        let xs = pts.map { ($0.at.timeIntervalSince1970 * 1000 - x0) / 60_000 }
        let ys = pts.map { $0.percent }
        let n = Double(xs.count)
        let meanX = xs.reduce(0, +) / n
        let meanY = ys.reduce(0, +) / n
        var num = 0.0
        var den = 0.0
        for i in 0..<xs.count {
            num += (xs[i] - meanX) * (ys[i] - meanY)
            den += (xs[i] - meanX) * (xs[i] - meanX)
        }
        let slope = den == 0 ? 0 : num / den
        guard slope > 0 else { return nil }
        let intercept = meanY - slope * meanX
        return x0 + ((100 - intercept) / slope) * 60_000
    }
}

// MARK: - HistoryDelight (web/src/history/Delight.tsx)

enum HistoryDelight {
    /// web/src/history/Delight.tsx `HOBBIT_TOKENS`.
    static let hobbitTokens = 125_000.0

    /// web/src/history/Delight.tsx factor-string rule (the body of
    /// `DelightFooter`, minus the range-scope-word presentation, which is
    /// UI copy, not ported logic). nil when there are no tokens to report
    /// at all (`factor <= 0`) — mirrors the web component rendering
    /// nothing in that case. >= 100: rounded integer with en-US thousands
    /// separators. Else: 1 decimal place.
    static func hobbitFactorString(_ totalTokens: Double) -> String? {
        let factor = totalTokens / hobbitTokens
        guard factor > 0 else { return nil }
        if factor >= 100 {
            return HistoryFormat.enUSInt(HistoryFormat.mathRound(factor))
        }
        return HistoryFormat.fixed(factor, 1)
    }
}
