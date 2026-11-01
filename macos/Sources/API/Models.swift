import Foundation

// Mirror of the daemon's GET /v1/state contract (internal/daemon/daemon.go).
// Field names are the Go JSON tags, spelled out — never inferred.

struct DaemonState: Decodable, Equatable {
    var accounts: [AccountState]
    var activeID: String?
    var schedules: [Schedule]
    /// Every account's rolling / one-off window starts (window_plans; empty
    /// from a daemon too old to serve it).
    var windowPlans: [WindowPlan] = []
    /// Preserved foreign credentials awaiting adopt/discard (metadata only —
    /// the payload never rides the wire). Empty array when none.
    var stash: [StashEntry]
    /// license_status: the daemon's projection — trialing | lifetime | lapsed |
    /// revoked; absent (nil) means no entitlement yet. The menu bar reads this
    /// to show Pro state without a second request (it rides /v1/state + SSE).
    var license: String? = nil
    /// license_seat_refused: the license server refused this install a seat —
    /// it turns the license view's "checking" into "restore by email", so the
    /// cockpit reloads the license on it.
    var licenseSeatRefused = false
    /// The build of the daemon PROCESS answering, which is not necessarily the
    /// binary on disk: an in-place update replaces the bundle while the old
    /// process keeps running. nil from a daemon too old to report it.
    var version: String? = nil
    /// Plan-ordered switch/rotation history (web/src/api.ts DaemonEvent).
    /// Empty array when none — an older daemon or a fresh install must still
    /// decode.
    var events: [DaemonEvent]
    var asOf: Date

    enum CodingKeys: String, CodingKey {
        case accounts
        case activeID = "active_id"
        case schedules
        case windowPlans = "window_plans"
        case stash
        case license = "license_status"
        case licenseSeatRefused = "license_seat_refused"
        case version
        case events
        case asOf = "as_of"
    }

    init(accounts: [AccountState], activeID: String?, schedules: [Schedule],
         stash: [StashEntry] = [], license: String? = nil,
         version: String? = nil, events: [DaemonEvent] = [], asOf: Date)
    {
        self.accounts = accounts
        self.activeID = activeID
        self.schedules = schedules
        self.stash = stash
        self.license = license
        self.version = version
        self.events = events
        self.asOf = asOf
    }

    /// Go marshals nil slices as JSON null; a fresh install has zero
    /// accounts, and that state must decode — never kill the whole fleet
    /// view (the web side normalizes the same way).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accounts = try c.decodeIfPresent([AccountState].self, forKey: .accounts) ?? []
        activeID = try c.decodeIfPresent(String.self, forKey: .activeID)
        schedules = try c.decodeIfPresent([Schedule].self, forKey: .schedules) ?? []
        windowPlans = try c.decodeIfPresent([WindowPlan].self, forKey: .windowPlans) ?? []
        stash = try c.decodeIfPresent([StashEntry].self, forKey: .stash) ?? []
        license = try c.decodeIfPresent(String.self, forKey: .license)
        licenseSeatRefused = try c.decodeIfPresent(Bool.self, forKey: .licenseSeatRefused) ?? false
        version = try c.decodeIfPresent(String.self, forKey: .version)
        events = try c.decodeIfPresent([DaemonEvent].self, forKey: .events) ?? []
        asOf = try c.decode(Date.self, forKey: .asOf)
    }

    /// A trialing or lifetime grant is the only "Pro is on" state.
    var licensed: Bool { license == "trialing" || license == "lifetime" }
}

/// One fleet-history entry (web/src/api.ts `DaemonEvent`): a switch,
/// rotation, or other plan-ordered occurrence the daemon recorded. `kind` is
/// an OPEN string passed through from the daemon — unknown kinds render,
/// never error (same rule as `Bucket.kind`).
struct DaemonEvent: Decodable, Equatable {
    var at: Date
    var kind: String
    var accountID: String?
    var message: String
    var late: Bool?

    enum CodingKeys: String, CodingKey {
        case at, kind, message, late
        case accountID = "account_id"
    }
}

struct AccountState: Decodable, Equatable, Identifiable {
    var id: String
    var label: String
    var email: String
    var pinned: Bool
    var snapshot: UsageSnapshot?
    var tokenNote: String?
    /// The daemon's authoritative stale mark: the stored token expired while
    /// idle, so `snapshot` is frozen at last-known until the account wakes.
    var stale: Bool?
    /// The account's own config dir (pilotapi/types.go `config_dir`).
    /// Global-swappable fleet accounts all carry the GLOBAL dir here
    /// (internal/daemon/server.go:592-593); pinned/watched accounts carry
    /// their own folder.
    var configDir: String?
    /// The open 5-hour window's pace and wall (internal/daemon/forecast.go);
    /// nil until the daemon has a quarter hour of polls to judge it.
    var forecasts: [BucketForecast]?

    enum CodingKeys: String, CodingKey {
        case id, label, email, pinned, snapshot, stale, forecasts
        case tokenNote = "token_note"
        case configDir = "config_dir"
    }

    /// The forecast for the 5-hour window, if the daemon has one.
    var sessionForecast: BucketForecast? {
        forecasts?.first { $0.kind == "session" || $0.kind == "five_hour" }
    }

    /// The weekly forecast the daemon sends for an account with no 5-hour
    /// limit (internal/daemon/forecast.go weeklyForecasts).
    var weeklyForecast: BucketForecast? {
        forecasts?.first { $0.kind == "weekly_all" || $0.kind == "seven_day" }
    }

    /// The account's usage lists no 5-hour limit at all — Anthropic drops it
    /// for verified accounts on some plans (Ultra), account by account. An
    /// account WITH one lists it even while idle; no usage yet is unknown
    /// (pilotapi.NoFiveHourLimit).
    var noFiveHourLimit: Bool {
        guard let buckets = snapshot?.buckets, !buckets.isEmpty else { return false }
        return !buckets.contains { $0.kind == "session" || $0.kind == "five_hour" }
    }

    /// The pace line's forecast: the weekly one when there is no 5-hour limit.
    var paceForecast: BucketForecast? { noFiveHourLimit ? weeklyForecast : sessionForecast }
}

/// An open 5-hour window's pace (forecast.go BucketForecast): percent per
/// hour at the live burn, and when it reaches 100% at that pace.
struct BucketForecast: Decodable, Equatable {
    var kind: String
    var scope: String?
    var perHour: Double
    /// nil: the pace is too slow to reach 100% at all.
    var wallAt: Date?
    /// Whether wallAt lands before the window resets.
    var beforeReset: Bool

    enum CodingKeys: String, CodingKey {
        case kind, scope
        case perHour = "per_hour"
        case wallAt = "wall_at"
        case beforeReset = "before_reset"
    }

    init(kind: String, scope: String? = nil, perHour: Double, wallAt: Date?, beforeReset: Bool) {
        self.kind = kind
        self.scope = scope
        self.perHour = perHour
        self.wallAt = wallAt
        self.beforeReset = beforeReset
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(String.self, forKey: .kind)
        scope = try c.decodeIfPresent(String.self, forKey: .scope)
        perHour = try c.decodeIfPresent(Double.self, forKey: .perHour) ?? 0
        wallAt = try c.decodeIfPresent(Date.self, forKey: .wallAt)
        beforeReset = try c.decodeIfPresent(Bool.self, forKey: .beforeReset) ?? false
    }
}

/// One account's automatic window starts (pilotapi.WindowPlan): rolling
/// starts the next window at every reset; nextAt starts one at one moment.
struct WindowPlan: Decodable, Equatable {
    var accountID: String
    var rolling: Bool
    var nextAt: Date?

    enum CodingKeys: String, CodingKey {
        case accountID = "account_id"
        case rolling
        case nextAt = "next_at"
    }

    init(accountID: String, rolling: Bool = false, nextAt: Date? = nil) {
        self.accountID = accountID
        self.rolling = rolling
        self.nextAt = nextAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accountID = try c.decode(String.self, forKey: .accountID)
        rolling = try c.decodeIfPresent(Bool.self, forKey: .rolling) ?? false
        nextAt = try c.decodeIfPresent(Date.self, forKey: .nextAt)
    }
}

struct UsageSnapshot: Decodable, Equatable {
    var asOf: Date
    var buckets: [Bucket]

    enum CodingKeys: String, CodingKey {
        case asOf = "as_of"
        case buckets
    }
}

/// Bucket kinds and severities are OPEN strings passed through from the usage
/// endpoint — unknown kinds render, never error (ledger: bucket-agnostic).
struct Bucket: Decodable, Equatable {
    var kind: String
    var scope: String?
    var percent: Double // Go float64 — fractional values like 12.5 are real
    var resetsAt: Date?
    var severity: String?
    var active: Bool?

    var percentInt: Int { Int(percent.rounded()) }

    enum CodingKeys: String, CodingKey {
        case kind, scope, percent, severity, active
        case resetsAt = "resets_at"
    }

    /// Short display label: session → 5h, weekly_all → wk, scoped → its scope.
    var shortLabel: String {
        switch kind {
        case "session": return "5h"
        case "weekly_all": return "wk"
        case "weekly_scoped": return scope ?? "scoped"
        default: return scope ?? kind
        }
    }
}

/// One preserved foreign credential (a swap found an unknown account's
/// sign-in in the global slot and kept it instead of guessing an owner).
/// `dead` marks a lineage the token endpoint has rejected — adopting it
/// needs a fresh sign-in.
struct StashEntry: Decodable, Equatable, Identifiable {
    var fingerprint: String
    var label: String?
    var stashedAt: Date
    var dead: Bool?

    var id: String { fingerprint }

    enum CodingKeys: String, CodingKey {
        case fingerprint, label, dead
        case stashedAt = "stashed_at"
    }
}

struct Schedule: Decodable, Equatable, Identifiable {
    var id: String
    var accountID: String
    var hour: Int
    var minute: Int

    enum CodingKeys: String, CodingKey {
        case id, hour, minute
        case accountID = "account_id"
    }
}

struct DetectedDir: Decodable, Equatable, Identifiable {
    var configDir: String
    var email: String
    var registered: Bool
    /// A migration has already moved this dir into the fleet. Older daemons
    /// predate the field — absence decodes to false, never fails the row
    /// (a field the emitter omits must still decode).
    var moved: Bool
    /// false only when the dir is CONFIRMED to hold no credential: it still
    /// names an account in .claude.json, but the sign-in itself is gone, so
    /// adopt and move can only refuse (mirrors web/src/api.ts DetectedDir).
    /// Older daemons omit it — absent reads as signed in, the pre-existing
    /// behavior (internal/daemon/server.go:662-665).
    var signedIn: Bool?
    /// The subscription tier's DISPLAY label ("Max 20×", "Pro") — mapped
    /// daemon-side by the claudecfg adapter, which owns the raw vocabulary.
    /// Absent when unknown (older daemons, unrecognized tier): a surface
    /// shows nothing rather than a guess (owner 2026-08-12).
    var tier: String?

    var id: String { configDir }

    enum CodingKeys: String, CodingKey {
        case configDir = "config_dir"
        case email, registered, moved, tier
        case signedIn = "signed_in"
    }

    init(configDir: String, email: String, registered: Bool, moved: Bool = false, signedIn: Bool? = nil, tier: String? = nil) {
        self.configDir = configDir
        self.email = email
        self.registered = registered
        self.moved = moved
        self.signedIn = signedIn
        self.tier = tier
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        configDir = try c.decode(String.self, forKey: .configDir)
        email = try c.decodeIfPresent(String.self, forKey: .email) ?? ""
        registered = try c.decodeIfPresent(Bool.self, forKey: .registered) ?? false
        moved = try c.decodeIfPresent(Bool.self, forKey: .moved) ?? false
        signedIn = try c.decodeIfPresent(Bool.self, forKey: .signedIn)
        tier = try c.decodeIfPresent(String.self, forKey: .tier)
    }
}

struct DaemonConfig: Codable, Equatable {
    struct Autopilot: Codable, Equatable {
        var disabled: Bool?
        var thresholdPercent: Double? // Go float64, like every percent

        enum CodingKeys: String, CodingKey {
            case disabled
            case thresholdPercent = "threshold_percent"
        }
    }
    var autopilot: Autopilot?
}

enum DaemonDates {
    private static let plain = ISO8601DateFormatter()

    /// Go's RFC3339Nano trims trailing zeros, so the fractional width is
    /// 0–9 digits and varies per response. ISO8601DateFormatter's
    /// .withFractionalSeconds accepts only exactly 3 digits on macOS 13/14
    /// (pre-swift-foundation) — parse the fraction ourselves instead.
    static func parseRFC3339(_ s: String) -> Date? {
        if let t = plain.date(from: s) { return t }
        guard let dot = s.firstIndex(of: ".") else { return nil }
        var idx = s.index(after: dot)
        var frac = ""
        while idx < s.endIndex, s[idx].isNumber {
            frac.append(s[idx])
            idx = s.index(after: idx)
        }
        guard !frac.isEmpty,
              let seconds = Double("0.\(frac)"),
              let base = plain.date(from: String(s[..<dot]) + String(s[idx...]))
        else { return nil }
        return base.addingTimeInterval(seconds)
    }

    static func decoder() -> JSONDecoder {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .custom { d in
            let s = try d.singleValueContainer().decode(String.self)
            if let t = parseRFC3339(s) { return t }
            throw DecodingError.dataCorrupted(.init(
                codingPath: d.codingPath,
                debugDescription: "unparseable RFC3339 date: \(s)"))
        }
        return dec
    }
}
