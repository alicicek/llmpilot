import Foundation

// Mirrors of the daemon's cockpit-only wire contracts — everything the
// embedded web cockpit reaches beyond GET /v1/state (that one lives in
// Models.swift). Field names are the Go JSON tags, spelled out — never
// inferred. Same discipline as Models.swift throughout: Go nil slices
// marshal as JSON null (or, for a few endpoints, are simply omitted by an
// older daemon), so every array field tolerates absence via
// decodeIfPresent, and every date rides DaemonDates.decoder().

// MARK: - JSON value

/// A minimal JSON value for the handful of genuinely-untyped wire fields:
/// statusline segment option maps and their declared defaults
/// (internal/statusline/segments.go OptionSpec.Default is Go `any`, and
/// SegmentConfig.Options is `map[string]any`). Options are only ever
/// bool | enum(string) | string | color(string), so string/number/bool/null
/// cover the wire — no nested arrays or objects ever ride these fields.
enum JSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let v = try? c.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? c.decode(Double.self) {
            self = .number(v)
        } else if let v = try? c.decode(String.self) {
            self = .string(v)
        } else {
            // An array/object here means the wire contract above changed —
            // silently nulling it would wipe the value on the next config
            // round-trip (PUT sends back what we decoded). Fail loudly.
            throw DecodingError.dataCorruptedError(
                in: c,
                debugDescription:
                    "statusline option values are bool|number|string|null on the wire — refusing to coerce a nested array/object")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case let .string(v): try c.encode(v)
        case let .number(v): try c.encode(v)
        case let .bool(v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
}

// MARK: - history (GET /v1/history — internal/daemon/server.go:851-864)

/// One sample of an account's usage percent over time
/// (internal/daemon/daemon.go:346-349).
struct HistorySample: Codable, Equatable {
    var at: Date
    var percent: Double
}

/// The endpoint always wraps samples in an object and coalesces a nil slice
/// to `[]` server-side (server.go:859-863) — this client tolerates a null
/// or absent key too, the same defensive posture as every other array field.
struct HistoryResponse: Decodable, Equatable {
    var samples: [HistorySample]

    enum CodingKeys: String, CodingKey { case samples }

    init(samples: [HistorySample]) { self.samples = samples }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        samples = try c.decodeIfPresent([HistorySample].self, forKey: .samples) ?? []
    }
}

// MARK: - doctor (GET /v1/doctor — internal/doctor/doctor.go)

/// internal/doctor/doctor.go:78-83.
struct DoctorRemedy: Decodable, Equatable {
    var verb: String
    var label: String
    var target: String?
    var command: String?
}

/// internal/doctor/doctor.go:101-109. `accounts` carries labels, never
/// emails or secrets.
struct DoctorFinding: Decodable, Equatable, Identifiable {
    var id: String
    var check: String
    var severity: String // critical | warning | info
    var title: String
    var detail: String
    var accounts: [String]
    var remedy: DoctorRemedy

    enum CodingKeys: String, CodingKey {
        case id, check, severity, title, detail, accounts, remedy
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        check = try c.decode(String.self, forKey: .check)
        severity = try c.decode(String.self, forKey: .severity)
        title = try c.decode(String.self, forKey: .title)
        detail = try c.decode(String.self, forKey: .detail)
        accounts = try c.decodeIfPresent([String].self, forKey: .accounts) ?? []
        remedy = try c.decode(DoctorRemedy.self, forKey: .remedy)
    }
}

/// internal/doctor/doctor.go:127-132. A NOT-CHECKED state must never be
/// dropped silently — `why` explains it.
struct DoctorCheck: Decodable, Equatable, Identifiable {
    var id: String
    var title: String
    var state: String // ok | finding | not_checked
    var why: String?
}

/// internal/doctor/doctor.go:136-148. `findings`/`checks` carry no
/// `omitempty` tag in Go, so a report with none of either marshals both as
/// JSON null — decode that to an empty array, never fail the whole sweep.
struct DoctorReport: Decodable, Equatable {
    var asOf: Date
    var clean: Bool
    var problems: Int
    var findings: [DoctorFinding]
    var checks: [DoctorCheck]

    enum CodingKeys: String, CodingKey {
        case asOf = "as_of"
        case clean, problems, findings, checks
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        asOf = try c.decode(Date.self, forKey: .asOf)
        clean = try c.decode(Bool.self, forKey: .clean)
        problems = try c.decode(Int.self, forKey: .problems)
        findings = try c.decodeIfPresent([DoctorFinding].self, forKey: .findings) ?? []
        checks = try c.decodeIfPresent([DoctorCheck].self, forKey: .checks) ?? []
    }
}

// MARK: - analytics (GET /v1/analytics — internal/daemon/server.go:878-972)

/// internal/analytics/analytics.go:31-36.
struct AnalyticsTokens: Decodable, Equatable {
    var input: Int64
    var output: Int64
    var cacheCreation: Int64
    var cacheRead: Int64

    enum CodingKeys: String, CodingKey {
        case input, output
        case cacheCreation = "cache_creation"
        case cacheRead = "cache_read"
    }
}

/// The unexported `cellOut` shape (server.go:901-908). `accountID` is ""
/// for activity in the shared global config dir — the UI's "shared" row.
struct AnalyticsCell: Decodable, Equatable {
    var accountID: String
    var project: String
    var model: String
    var day: String // YYYY-MM-DD
    var messages: Int64
    var tokens: AnalyticsTokens

    enum CodingKeys: String, CodingKey {
        case accountID = "account_id"
        case project, model, day, messages, tokens
    }
}

/// server.go:964-971. `cells` is initialized `[]cellOut{}` and
/// `hour_weekday` is a fixed [7][24]int64 Go array, so neither is ever nil
/// on the wire in practice — tolerated as null/absent anyway, the same
/// defensive posture as every other array field on this client.
struct AnalyticsResponse: Decodable, Equatable {
    var cells: [AnalyticsCell]
    /// 7 rows (Sunday=0) × 24 local hours of total tokens.
    var hourWeekday: [[Int64]]
    var filesTotal: Int
    var filesParsed: Int
    var filesReused: Int
    var asOf: Date

    enum CodingKeys: String, CodingKey {
        case cells
        case hourWeekday = "hour_weekday"
        case filesTotal = "files_total"
        case filesParsed = "files_parsed"
        case filesReused = "files_reused"
        case asOf = "as_of"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cells = try c.decodeIfPresent([AnalyticsCell].self, forKey: .cells) ?? []
        hourWeekday = try c.decodeIfPresent([[Int64]].self, forKey: .hourWeekday) ?? []
        filesTotal = try c.decodeIfPresent(Int.self, forKey: .filesTotal) ?? 0
        filesParsed = try c.decodeIfPresent(Int.self, forKey: .filesParsed) ?? 0
        filesReused = try c.decodeIfPresent(Int.self, forKey: .filesReused) ?? 0
        asOf = try c.decode(Date.self, forKey: .asOf)
    }
}

// MARK: - statusline (internal/daemon/statusline.go, internal/statusline)

/// internal/statusline/segments.go:16-22. `values` rides only `enum`-typed
/// options; `default` is Go `any`.
struct SLOptionSpec: Decodable, Equatable {
    var key: String
    var label: String
    var type: String // bool | enum | string | color
    var values: [String]?
    var defaultValue: JSONValue?

    enum CodingKeys: String, CodingKey {
        case key, label, type, values
        case defaultValue = "default"
    }
}

/// internal/statusline/render.go:150-158 (served by Specs(), statusline.go:
/// 121-128). `deps` and `fleet` carry `omitempty` and may be absent.
struct SLSegmentSpec: Decodable, Equatable, Identifiable {
    var id: String
    var name: String
    var desc: String
    var deps: [String]
    var priority: Int
    var fleet: Bool
    var options: [SLOptionSpec]

    enum CodingKeys: String, CodingKey {
        case id, name, desc, deps, priority, fleet, options
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        desc = try c.decode(String.self, forKey: .desc)
        deps = try c.decodeIfPresent([String].self, forKey: .deps) ?? []
        priority = try c.decode(Int.self, forKey: .priority)
        fleet = try c.decodeIfPresent(Bool.self, forKey: .fleet) ?? false
        options = try c.decodeIfPresent([SLOptionSpec].self, forKey: .options) ?? []
    }
}

/// internal/statusline/statusline.go:43-45.
struct SLKeepConfig: Codable, Equatable {
    var command: String
}

/// internal/statusline/statusline.go:54-57.
struct SLSegmentConfig: Codable, Equatable {
    var id: String
    var options: [String: JSONValue]?
}

/// internal/statusline/statusline.go:27-35. Decoding tolerates a null/absent
/// `segments` array; Encodable is synthesized (Optional fields already omit
/// their key on nil, matching Go's `omitempty` — see CockpitDecodingTests).
struct StatuslineConfig: Codable, Equatable {
    var version: Int
    var preset: String?
    var separator: String?
    var flex: String?
    var color: String?
    var keep: SLKeepConfig?
    var segments: [SLSegmentConfig]

    enum CodingKeys: String, CodingKey {
        case version, preset, separator, flex, color, keep, segments
    }

    init(
        version: Int, preset: String? = nil, separator: String? = nil,
        flex: String? = nil, color: String? = nil, keep: SLKeepConfig? = nil,
        segments: [SLSegmentConfig]
    ) {
        self.version = version
        self.preset = preset
        self.separator = separator
        self.flex = flex
        self.color = color
        self.keep = keep
        self.segments = segments
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        preset = try c.decodeIfPresent(String.self, forKey: .preset)
        separator = try c.decodeIfPresent(String.self, forKey: .separator)
        flex = try c.decodeIfPresent(String.self, forKey: .flex)
        color = try c.decodeIfPresent(String.self, forKey: .color)
        keep = try c.decodeIfPresent(SLKeepConfig.self, forKey: .keep)
        segments = try c.decodeIfPresent([SLSegmentConfig].self, forKey: .segments) ?? []
    }
}

/// internal/statusline/statusline.go:222-227.
struct SLPreset: Decodable, Equatable, Identifiable {
    var id: String
    var name: String
    var desc: String
    var config: StatuslineConfig
}

/// GET /v1/statusline/segments (statusline.go:121-128).
struct StatuslineSegmentsResponse: Decodable, Equatable {
    var segments: [SLSegmentSpec]
    var presets: [SLPreset]

    enum CodingKeys: String, CodingKey { case segments, presets }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        segments = try c.decodeIfPresent([SLSegmentSpec].self, forKey: .segments) ?? []
        presets = try c.decodeIfPresent([SLPreset].self, forKey: .presets) ?? []
    }
}

/// GET/PUT /v1/statusline/config. GET always carries `load_error` (empty
/// string when clean, statusline.go:94-102); PUT's response omits the key
/// entirely (statusline.go:104-119) — both decode fine since it is optional.
struct StatuslineConfigResponse: Decodable, Equatable {
    var config: StatuslineConfig
    var loadError: String?

    enum CodingKeys: String, CodingKey {
        case config
        case loadError = "load_error"
    }
}

/// GET /v1/statusline/preview (statusline.go:84-92). `line`/`plain` are the
/// SAME Go renderer the binary prints — preview==production.
struct StatuslinePreviewResponse: Decodable, Equatable {
    var line: String
    var plain: String
    var width: Int
    var tier: String
}

// MARK: - licensing (internal/daemon/license.go)

/// internal/daemon/license.go:144-148.
struct TrialInfo: Decodable, Equatable {
    var endsAt: Date
    var chargeDate: Date?
    var daysLeft: Int

    enum CodingKeys: String, CodingKey {
        case endsAt = "ends_at"
        case chargeDate = "charge_date"
        case daysLeft = "days_left"
    }
}

/// GET /v1/license (license.go:152-169). The signed entitlement token never
/// rides this response; the full `license_id` appears only under
/// `?reveal=1`, which requires the Bearer install token (see CockpitAPI.swift).
struct LicenseInfo: Decodable, Equatable {
    var available: Bool
    var active: Bool
    var status: String // none | trialing | lifetime | lapsed | revoked | unavailable
    var kind: String?
    var features: [String]
    var seats: Int
    var expiresAt: Date?
    var trial: TrialInfo?
    var lastValidated: Date?
    var licenseID: String?
    var licenseIDMasked: String?
    var nocardTrialUsed: Bool
    var errorCode: String?

    enum CodingKeys: String, CodingKey {
        case available, active, status, kind, features, seats
        case expiresAt = "expires_at"
        case trial
        case lastValidated = "last_validated"
        case licenseID = "license_id"
        case licenseIDMasked = "license_id_masked"
        case nocardTrialUsed = "nocard_trial_used"
        case errorCode = "error_code"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        available = try c.decode(Bool.self, forKey: .available)
        active = try c.decode(Bool.self, forKey: .active)
        status = try c.decode(String.self, forKey: .status)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        features = try c.decodeIfPresent([String].self, forKey: .features) ?? []
        seats = try c.decodeIfPresent(Int.self, forKey: .seats) ?? 0
        expiresAt = try c.decodeIfPresent(Date.self, forKey: .expiresAt)
        trial = try c.decodeIfPresent(TrialInfo.self, forKey: .trial)
        lastValidated = try c.decodeIfPresent(Date.self, forKey: .lastValidated)
        licenseID = try c.decodeIfPresent(String.self, forKey: .licenseID)
        licenseIDMasked = try c.decodeIfPresent(String.self, forKey: .licenseIDMasked)
        nocardTrialUsed = try c.decodeIfPresent(Bool.self, forKey: .nocardTrialUsed) ?? false
        errorCode = try c.decodeIfPresent(String.self, forKey: .errorCode)
    }
}

/// GET /v1/license/quote (license.go:420-438) proxies the worker's
/// `/v1/quote` body VERBATIM — the daemon adds no meaning to it. Shape
/// pinned by TestLicenseQuoteProxiesWorkerTerms (license_test.go:215):
/// `{"trial_days":8,"charge_date":"...","prices":{"full":{"gbp":999,"usd":1299},
///  "discount":{"gbp":599,"usd":799}}}`. `prices` is a currency → minor-units
/// map per rung, open-ended (new currencies must not break decode).
struct LicenseQuote: Decodable, Equatable {
    struct Prices: Decodable, Equatable {
        var full: [String: Int]
        var discount: [String: Int]

        enum CodingKeys: String, CodingKey { case full, discount }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            full = try c.decodeIfPresent([String: Int].self, forKey: .full) ?? [:]
            discount = try c.decodeIfPresent([String: Int].self, forKey: .discount) ?? [:]
        }
    }

    // All optional on purpose: the body is a THIRD PARTY's (the worker's,
    // passed through verbatim) — a worker-side rename or a region without a
    // charge date must degrade the paywall copy, never make the whole quote
    // undecodable. The consent-echo rule needs whatever fields DID arrive.
    var trialDays: Int?
    var chargeDate: Date?
    var prices: Prices?

    enum CodingKeys: String, CodingKey {
        case trialDays = "trial_days"
        case chargeDate = "charge_date"
        case prices
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        trialDays = try c.decodeIfPresent(Int.self, forKey: .trialDays)
        chargeDate = try c.decodeIfPresent(Date.self, forKey: .chargeDate)
        prices = try c.decodeIfPresent(Prices.self, forKey: .prices)
    }
}

// MARK: - licensing mutations (Phase 4 chunk A: LadderLogic.swift/
// AskMachine.swift own the state machine; these are only the wire shapes.)

/// POST /v1/license/checkout's 200 (license.go:304: `writeJSON(w, 200,
/// map[string]string{"url": ..., "session_id": ...})`) — both keys always
/// present (a Go `map[string]string`), but decoded tolerantly like every
/// other body here.
struct CheckoutHandoff: Decodable, Equatable {
    var url: String
    var sessionID: String?

    enum CodingKeys: String, CodingKey {
        case url
        case sessionID = "session_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        sessionID = try c.decodeIfPresent(String.self, forKey: .sessionID)
    }
}

/// POST /v1/license/cancel's 200 (license.go:478: `{"status": stored.Status}`
/// — "lapsed").
struct LicenseCancelResult: Decodable, Equatable {
    var status: String
}

/// POST /v1/license/recover/claim's 200 (license.go:547: `{"status":
/// view.Status}`).
struct LicenseClaimResult: Decodable, Equatable {
    var status: String
}

// MARK: - schedules (pilotapi/types.go:81-91, internal/daemon/server.go:405-587)

/// Full mirror of pilotapi.Schedule — Models.swift's `Schedule` is the
/// lighter /v1/state projection (id/account_id/hour/minute only); this one
/// round-trips `model`/`effort` too, which /v1/schedules itself serves.
struct ScheduleRecord: Codable, Equatable, Identifiable {
    var id: String
    var accountID: String
    var hour: Int
    var minute: Int
    var model: String?
    var effort: String?

    enum CodingKeys: String, CodingKey {
        case id, hour, minute, model, effort
        case accountID = "account_id"
    }
}

/// POST /v1/schedules body (server.go:426-432).
struct ScheduleCreateRequest: Encodable {
    var accountID: String
    var hour: Int
    var minute: Int
    var model: String?
    var effort: String?

    enum CodingKeys: String, CodingKey {
        case hour, minute, model, effort
        case accountID = "account_id"
    }
}

/// PUT /v1/schedules/{id} body — hour/minute only (server.go:502-505).
struct ScheduleUpdateRequest: Encodable {
    var hour: Int
    var minute: Int
}

// MARK: - accounts (pilotapi/types.go:14-21)

/// Full mirror of pilotapi.Account, as served raw by POST /v1/stash/adopt
/// (server.go:341) and nested in POST /v1/adopt/move's response
/// (server.go:814-818). Models.swift's `AccountState` is the /v1/state
/// projection (adds snapshot/token_note/stale, drops config_dir/
/// keychain_service) — a different shape, not this one.
struct CockpitAccount: Decodable, Equatable, Identifiable {
    var id: String
    var label: String
    var email: String
    var configDir: String
    var keychainService: String
    var pinned: Bool

    enum CodingKeys: String, CodingKey {
        case id, label, email, pinned
        case configDir = "config_dir"
        case keychainService = "keychain_service"
    }
}

/// POST /v1/adopt/move response (server.go:814-818).
struct AdoptMoveResult: Decodable, Equatable {
    var account: CockpitAccount
    var outcome: String // "complete" | "clone_suspect"
    var note: String
}

// MARK: - config (internal/store/config.go, internal/daemon/server.go:821-849)

/// pilotapi.AutopilotConfig, aliased as store.AutopilotConfig
/// (pilotapi/types.go:156-160).
struct CockpitAutopilotConfig: Codable, Equatable {
    var disabled: Bool?
    var thresholdPercent: Double?
    var cooldownMinutes: Int?
    /// Adaptive time-to-wall's floor override (owner 2026-08-13). Carried
    /// even though the sheet has no editor for it: the sheet's writes PUT
    /// the FULL config (server-side full replace), so a field this model
    /// didn't know would be silently WIPED by any Settings toggle.
    var runwayMinutes: Int? = nil

    enum CodingKeys: String, CodingKey {
        case disabled
        case thresholdPercent = "threshold_percent"
        case cooldownMinutes = "cooldown_minutes"
        case runwayMinutes = "runway_minutes"
    }
}

/// store.NotificationsConfig (internal/store/config.go:33-38).
struct CockpitNotificationsConfig: Codable, Equatable {
    var disabled: Bool?
    var thresholds: [Double]?
}

/// GET/PUT /v1/config body — the full store.Config (internal/store/
/// config.go:17-24). Models.swift's `DaemonConfig` only reads `autopilot`;
/// PUT is a full replace server-side (handleConfigPut decodes straight into
/// store.Config), so a round-trip mutation needs every field to avoid
/// silently wiping notifications/plan_cost_monthly.
struct CockpitConfig: Codable, Equatable {
    var autopilot: CockpitAutopilotConfig?
    var notifications: CockpitNotificationsConfig?
    var planCostMonthly: [String: Double]?

    enum CodingKeys: String, CodingKey {
        case autopilot, notifications
        case planCostMonthly = "plan_cost_monthly"
    }
}

// MARK: - browser sign-in (internal/daemon/login.go)

/// POST /v1/login/browser response (login.go:274-276). No CSRF state rides
/// this — the daemon's own loopback listener catches the callback.
struct BrowserLoginStart: Decodable, Equatable {
    var authorizeURL: String
    var attemptID: String

    enum CodingKeys: String, CodingKey {
        case authorizeURL = "authorize_url"
        case attemptID = "attempt_id"
    }
}

/// GET /v1/login/browser/status response (login.go:296-298). Every key is a
/// Go `map[string]string` value, so `error`/`account_id` are always present
/// (possibly ""), never omitted — decoded tolerantly anyway.
struct BrowserLoginStatus: Decodable, Equatable {
    var status: String // pending | done | failed
    var error: String?
    /// Machine-readable failure class ("rate_limited" or "") — the sheet
    /// keys its Try-again state off this, never off the prose in `error`.
    var code: String?
    var accountID: String?

    init(status: String, error: String? = nil, code: String? = nil, accountID: String? = nil) {
        self.status = status
        self.error = error
        self.code = code
        self.accountID = accountID
    }

    enum CodingKeys: String, CodingKey {
        case status, error, code
        case accountID = "account_id"
    }
}

// MARK: - error envelopes

/// The daemon's generic error body (httpError, server.go:980-982) and the
/// typed refusal a few handlers add a machine `code` to (proRefusal's 402s,
/// server.go:988-1004; requireAuth's 401, auth.go:41-45; httpWorkerError's
/// typed refusals, server.go:1020-1027) share this one shape. `code` is
/// absent on a plain httpError (e.g. requireJSON's 415, server.go:111-115).
struct ErrorEnvelope: Decodable, Equatable {
    var error: String
    var code: String?
}
