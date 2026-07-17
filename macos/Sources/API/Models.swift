import Foundation

// Mirror of the daemon's GET /v1/state contract (internal/daemon/daemon.go).
// Field names are the Go JSON tags, spelled out — never inferred.

struct DaemonState: Decodable, Equatable {
    var accounts: [AccountState]
    var activeID: String?
    var schedules: [Schedule]
    /// license_status: the daemon's projection — trialing | lifetime | lapsed |
    /// revoked; absent (nil) means no entitlement yet. The menu bar reads this
    /// to show Pro state without a second request (it rides /v1/state + SSE).
    var license: String? = nil
    var asOf: Date

    enum CodingKeys: String, CodingKey {
        case accounts
        case activeID = "active_id"
        case schedules
        case license = "license_status"
        case asOf = "as_of"
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

    enum CodingKeys: String, CodingKey {
        case id, label, email, pinned, snapshot
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

    var id: String { configDir }

    enum CodingKeys: String, CodingKey {
        case configDir = "config_dir"
        case email, registered
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
