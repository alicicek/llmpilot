import Foundation

// Mirror of the daemon's GET /v1/state contract (internal/daemon/daemon.go).
// Field names are the Go JSON tags, spelled out — never inferred.

struct DaemonState: Decodable, Equatable {
    var accounts: [AccountState]
    var activeID: String?
    var schedules: [Schedule]
    /// Preserved foreign credentials awaiting adopt/discard (metadata only —
    /// the payload never rides the wire). Empty array when none.
    var stash: [StashEntry]
    /// license_status: the daemon's projection — trialing | lifetime | lapsed |
    /// revoked; absent (nil) means no entitlement yet. The menu bar reads this
    /// to show Pro state without a second request (it rides /v1/state + SSE).
    var license: String? = nil
    var asOf: Date

    enum CodingKeys: String, CodingKey {
        case accounts
        case activeID = "active_id"
        case schedules
        case stash
        case license = "license_status"
        case asOf = "as_of"
    }

    init(accounts: [AccountState], activeID: String?, schedules: [Schedule],
         stash: [StashEntry] = [], license: String? = nil, asOf: Date)
    {
        self.accounts = accounts
        self.activeID = activeID
        self.schedules = schedules
        self.stash = stash
        self.license = license
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
        stash = try c.decodeIfPresent([StashEntry].self, forKey: .stash) ?? []
        license = try c.decodeIfPresent(String.self, forKey: .license)
        asOf = try c.decode(Date.self, forKey: .asOf)
    }

    /// A trialing or lifetime grant is the only "Pro is on" state.
    var licensed: Bool { license == "trialing" || license == "lifetime" }
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

    enum CodingKeys: String, CodingKey {
        case id, label, email, pinned, snapshot, stale
        case tokenNote = "token_note"
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

    var id: String { configDir }

    enum CodingKeys: String, CodingKey {
        case configDir = "config_dir"
        case email, registered, moved
    }

    init(configDir: String, email: String, registered: Bool, moved: Bool = false) {
        self.configDir = configDir
        self.email = email
        self.registered = registered
        self.moved = moved
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        configDir = try c.decode(String.self, forKey: .configDir)
        email = try c.decodeIfPresent(String.self, forKey: .email) ?? ""
        registered = try c.decodeIfPresent(Bool.self, forKey: .registered) ?? false
        moved = try c.decodeIfPresent(Bool.self, forKey: .moved) ?? false
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
