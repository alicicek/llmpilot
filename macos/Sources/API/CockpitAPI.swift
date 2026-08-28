import Foundation

/// Mirrors web/src/api.ts's `ApiError` / web/src/schedule.ts's `mutate`: a
/// non-2xx response from a cockpit MUTATION (cSend — POST/PUT/DELETE) keeps
/// the daemon's machine `code` beside the human message, so a caller can
/// route a tier boundary (proRefusal's 402 pro_required/pro_unavailable,
/// server.go:988-1004) to an offer instead of a generic failure.
///
/// PLUMBING DECISION (phase 3 chunk C): `DaemonError.http(Int, String)`
/// (DaemonClient.swift) carries only the unwrapped message — `code` is
/// decoded by `daemonErrorMessage` and then dropped, which is fine for the
/// ~15 call sites that only ever display the message, but leaves
/// ScheduleActions with nothing to route on. Widening `DaemonError.http`'s
/// arity was rejected: it is pattern-matched positionally in DaemonClient.swift
/// and constructed positionally across five other agents' test files this
/// brief must not touch, so a 3rd associated value would ripple past this
/// chunk's boundary for no reason `cGet` readers need. Instead: `cSend` —
/// used ONLY by mutations, exactly the shape of web's `mutate()` — decodes
/// `ErrorEnvelope.code` before it's lost and throws this typed error
/// instead of `DaemonError.http`. `cGet` (reads: schedules fetch, doctor,
/// analytics, license, statusline, …) is untouched and keeps throwing
/// `DaemonError.http`, matching web where only `mutate()` (not
/// `fetchSchedules`) constructs `ApiError`. No existing test exercises real
/// HTTPDaemonClient network code (every StubCockpitAPI-backed test scripts
/// a `Result` directly), so this is a zero-blast-radius change outside this
/// chunk's own new files.
struct ApiError: LocalizedError, Equatable {
    let status: Int
    /// The envelope's machine `code` — absent on a plain httpError (415,
    /// 404, generic 502, …), present on proRefusal's 402s and the typed
    /// worker refusals httpWorkerError forwards.
    let code: String?
    /// The envelope's `error` field verbatim (already unwrapped by
    /// `daemonErrorMessage` — never raw JSON).
    let message: String

    var errorDescription: String? { message }
}

/// The full cockpit API surface beyond DaemonAPI's fleet/state/login basics —
/// schedules, history, doctor, analytics, the statusline editor, licensing
/// (reads/quote only; checkout/cancel/recover are Phase 4), stash resolution,
/// the move-into-fleet mutation, config PUT, and the zero-paste browser
/// sign-in. One protocol so later phases build views against it without
/// touching HTTPDaemonClient again.
///
/// Auth notes throughout (internal/daemon/auth.go): a route requires the
/// Bearer install token ONLY when its handler calls `d.requireAuth` — that is
/// stated per method below, verified against server.go/login.go/license.go.
protocol CockpitDaemonAPI: DaemonAPI {
    // GET /v1/schedules — no auth (server.go:52,405-415).
    func schedules() async throws -> [ScheduleRecord]
    // POST /v1/schedules — no auth; entitlement-gated 402 server-side
    // (server.go:53,417-490).
    func createSchedule(
        accountID: String, hour: Int, minute: Int, model: String?, effort: String?
    ) async throws -> ScheduleRecord
    // PUT /v1/schedules/{id} — no auth (server.go:54,492-547).
    func updateSchedule(id: String, hour: Int, minute: Int) async throws -> ScheduleRecord
    // DELETE /v1/schedules/{id} — no auth (server.go:55,549-587).
    func deleteSchedule(id: String) async throws

    // GET /v1/history — no auth (server.go:68,851-864).
    func history(accountID: String, kind: String, scope: String?) async throws -> [HistorySample]

    // GET /v1/doctor — no auth, read-only sweep (server.go:56; doctor.go:120-125).
    func doctor() async throws -> DoctorReport

    // GET /v1/analytics — no auth (server.go:69,878-972).
    func analytics(days: Int) async throws -> AnalyticsResponse

    // GET /v1/statusline/preview — no auth (server.go:70; statusline.go:52-92).
    // `config` previews a DRAFT config JSON string; nil previews the saved one.
    func statuslinePreview(width: Int, tier: String, config: String?) async throws -> StatuslinePreviewResponse
    // GET /v1/statusline/config — no auth (server.go:71; statusline.go:94-102).
    func statuslineConfig() async throws -> StatuslineConfigResponse
    // PUT /v1/statusline/config — no auth (server.go:72; statusline.go:104-119).
    func putStatuslineConfig(_ cfg: StatuslineConfig) async throws -> StatuslineConfigResponse
    // GET /v1/statusline/segments — no auth (server.go:73; statusline.go:121-128).
    func statuslineSegments() async throws -> StatuslineSegmentsResponse

    // GET /v1/license — no auth UNLESS reveal=1, which requires the Bearer
    // install token to reveal the full license id (server.go:74;
    // license.go:184-242, reveal check at license.go:214-219).
    func license(reveal: Bool) async throws -> LicenseInfo
    // GET /v1/license/quote — no auth; public pre-checkout pricing proxied
    // from the worker (server.go:75; license.go:420-438).
    func licenseQuote() async throws -> LicenseQuote

    // POST /v1/license/checkout — REQUIRES the Bearer install token
    // (server.go:76; license.go:246-305, requireAuth at line 252). `echo` is
    // the exact consent terms the buyer saw (LadderLogic.QuoteEcho, ridden
    // as the body's "quote" field verbatim per license.go:261-262);
    // `remindDaysBefore` nil omits the field, leaving the worker's own
    // default (license.go:271-278). AskMachine.swift is the only caller.
    func licenseCheckout(rung: String, echo: QuoteEcho, remindDaysBefore: Int?) async throws -> CheckoutHandoff
    // POST /v1/license/cancel — REQUIRES the Bearer install token
    // (server.go:77; license.go:443-479, requireAuth at line 449). One-click
    // trial cancel (consumer-law checklist c).
    func licenseCancel() async throws -> LicenseCancelResult
    // POST /v1/license/recover — REQUIRES the Bearer install token
    // (server.go:78; license.go:483-509, requireAuth at line 489). Uniform
    // 202 whether or not the address is on file (no enumeration) — success
    // carries nothing to decode.
    func licenseRecover(email: String) async throws
    // POST /v1/license/recover/claim — REQUIRES the Bearer install token
    // (server.go:79; license.go:513-548, requireAuth at line 519).
    func licenseClaim(token: String) async throws -> LicenseClaimResult

    // POST /v1/stash/adopt — requires the Bearer install token
    // (server.go:60,291-342, requireAuth at 292).
    func stashAdopt(fingerprint: String, label: String?) async throws -> CockpitAccount
    // POST /v1/stash/discard — requires the Bearer install token
    // (server.go:61,346-381, requireAuth at 347).
    func stashDiscard(fingerprint: String) async throws

    // POST /v1/adopt/move — requires the Bearer install token; destructive
    // (retires the source config dir) unlike the open POST /v1/adopt
    // (server.go:59,748-819, requireAuth at 749).
    func adoptMove(configDir: String, label: String?) async throws -> AdoptMoveResult

    // GET /v1/config — no auth (server.go:66; handleConfigGet at
    // server.go:821-831 serves the full store config with notification
    // defaults applied visibly). The read path Value.tsx's plan-cost
    // comparison needs.
    func cockpitConfig() async throws -> CockpitConfig
    // PUT /v1/config — no auth (server.go:67,833-849; handleConfigPut never
    // calls requireAuth).
    func putConfig(_ cfg: CockpitConfig) async throws -> CockpitConfig

    // POST /v1/login/browser — requires the Bearer install token
    // (login.go:64,234-276, requireAuth at 235).
    func startBrowserLogin() async throws -> BrowserLoginStart
    // GET /v1/login/browser/status — requires the Bearer install token
    // (login.go:65,280-299, requireAuth at 281).
    func browserLoginStatus(attempt: String) async throws -> BrowserLoginStatus
}

extension HTTPDaemonClient: CockpitDaemonAPI {
    // DaemonClient.swift's `get`/`postJSON`/`postJSONData`/`url` helpers are
    // `private` — Swift scopes `private` to the declaring file, so THIS
    // extension (a different file) cannot see them even though it extends
    // the same type. These mirror the same discipline instead (timeouts,
    // Content-Type: application/json on every mutation, the Bearer install
    // token, DaemonError.http carrying the response body) rather than
    // reimplementing it differently.

    private func cockpitRequestURL(_ path: String, query: [String: String] = [:]) throws -> URL {
        guard let base = baseURL() else { throw DaemonError.down }
        guard var comps = URLComponents(
            url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false
        ) else { throw DaemonError.down }
        if !query.isEmpty {
            // Sorted for deterministic request URLs (a Dictionary's order
            // varies per process) — matters for logs, tests, and caching.
            comps.queryItems = query.sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
            // URLComponents leaves `+` literal, but Go's r.URL.Query()
            // decodes `+` as a space — a draft statusline config containing
            // "C++" would preview as "C  ". The web side's URLSearchParams
            // emits %2B; match it (measured 2026-08-07, preview==production
            // contract).
            comps.percentEncodedQuery = comps.percentEncodedQuery?
                .replacingOccurrences(of: "+", with: "%2B")
        }
        guard let url = comps.url else { throw DaemonError.down }
        return url
    }

    /// bearer defaults false: most cockpit GETs are unguarded, so this never
    /// sends the token unless a caller explicitly needs it (license reveal,
    /// the browser-login status poll).
    private func cGet(
        _ path: String, query: [String: String] = [:], bearer: Bool = false,
        timeout: TimeInterval = 10
    ) async throws -> Data {
        var req = URLRequest(url: try cockpitRequestURL(path, query: query))
        req.timeoutInterval = timeout
        if bearer, let tok = Self.installToken() {
            req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
        }
        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch let e as URLError where e.code == .cancelled {
            // URLSession surfaces Task cancellation as URLError(.cancelled),
            // never CancellationError (measured 2026-08-07) — map it back so
            // a cancelled load doesn't write a bogus "daemon not running"
            // error string into a view model.
            throw CancellationError()
        } catch {
            throw DaemonError.down
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            throw DaemonError.http(code, daemonErrorMessage(from: data, code: code))
        }
        return data
    }

    /// Content-Type: application/json on every mutation — the daemon
    /// 415-rejects anything else (requireJSON, server.go:111-123). The
    /// Bearer token rides every mutation when available, same as
    /// postJSONData: an extra header on an unguarded route is harmless, and
    /// several of these DO require it.
    private func cSend<T: Encodable>(
        _ method: String, _ path: String, body: T, timeout: TimeInterval = 10
    ) async throws -> Data {
        var req = URLRequest(url: try cockpitRequestURL(path))
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let tok = Self.installToken() {
            req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
        }
        // .iso8601 up front: no request body carries a Date today, but the
        // default .deferredToDate would silently send a float the first time
        // one does — the daemon speaks RFC3339 everywhere.
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        req.httpBody = try enc.encode(body)
        req.timeoutInterval = timeout
        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch let e as URLError where e.code == .cancelled {
            throw CancellationError()
        } catch {
            throw DaemonError.down
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(code) else {
            // The one decode site: unlike cGet's DaemonError.http, a mutation
            // failure keeps the envelope's `code` alongside the message (see
            // ApiError's doc comment above for why this is scoped to cSend).
            let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data)
            throw ApiError(status: code, code: envelope?.code, message: daemonErrorMessage(from: data, code: code))
        }
        return data
    }

    private func cPost<T: Encodable>(_ path: String, body: T, timeout: TimeInterval = 10) async throws -> Data {
        try await cSend("POST", path, body: body, timeout: timeout)
    }

    private func cPut<T: Encodable>(_ path: String, body: T) async throws -> Data {
        try await cSend("PUT", path, body: body)
    }

    private func cDelete(_ path: String) async throws {
        struct Empty: Encodable {}
        // The daemon's DELETE handler only checks Content-Type, never
        // decodes a body (handleScheduleDelete, server.go:549-587) — an
        // empty JSON object satisfies the 415 gate honestly.
        _ = try await cSend("DELETE", path, body: Empty())
    }

    private func pathID(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
    }

    // MARK: schedules

    func schedules() async throws -> [ScheduleRecord] {
        try DaemonDates.decoder().decode([ScheduleRecord]?.self, from: try await cGet("v1/schedules")) ?? []
    }

    func createSchedule(
        accountID: String, hour: Int, minute: Int, model: String? = nil, effort: String? = nil
    ) async throws -> ScheduleRecord {
        let body = ScheduleCreateRequest(accountID: accountID, hour: hour, minute: minute, model: model, effort: effort)
        let data = try await cPost("v1/schedules", body: body)
        return try DaemonDates.decoder().decode(ScheduleRecord.self, from: data)
    }

    func updateSchedule(id: String, hour: Int, minute: Int) async throws -> ScheduleRecord {
        let data = try await cPut("v1/schedules/\(pathID(id))", body: ScheduleUpdateRequest(hour: hour, minute: minute))
        return try DaemonDates.decoder().decode(ScheduleRecord.self, from: data)
    }

    func deleteSchedule(id: String) async throws {
        try await cDelete("v1/schedules/\(pathID(id))")
    }

    // MARK: history / doctor / analytics

    func history(accountID: String, kind: String, scope: String? = nil) async throws -> [HistorySample] {
        var query = ["account_id": accountID, "kind": kind]
        if let scope { query["scope"] = scope }
        let data = try await cGet("v1/history", query: query)
        return try DaemonDates.decoder().decode(HistoryResponse.self, from: data).samples
    }

    // Doctor sweeps and the analytics transcript walk can take real wall
    // time on a cold cache (internal/analytics/analytics.go documents the
    // first scan of a big ~/.claude/projects as legitimately slow) — a 10s
    // timeout would misreport a healthy-but-busy daemon as down.
    func doctor() async throws -> DoctorReport {
        try DaemonDates.decoder().decode(
            DoctorReport.self, from: try await cGet("v1/doctor", timeout: 60))
    }

    func analytics(days: Int = 30) async throws -> AnalyticsResponse {
        try DaemonDates.decoder().decode(
            AnalyticsResponse.self,
            from: try await cGet("v1/analytics", query: ["days": String(days)], timeout: 60))
    }

    // MARK: statusline

    /// `config` carries a DRAFT config as its JSON string — the whole point
    /// of the endpoint (internal/daemon/statusline.go handleStatuslinePreview
    /// reads a `config` query param): the editor previews unsaved edits with
    /// the daemon's real renderer. nil previews the saved config.
    func statuslinePreview(width: Int, tier: String, config: String? = nil) async throws -> StatuslinePreviewResponse {
        var query = ["width": String(width), "tier": tier]
        if let config { query["config"] = config }
        return try DaemonDates.decoder().decode(
            StatuslinePreviewResponse.self,
            from: try await cGet("v1/statusline/preview", query: query))
    }

    func statuslineConfig() async throws -> StatuslineConfigResponse {
        try DaemonDates.decoder().decode(StatuslineConfigResponse.self, from: try await cGet("v1/statusline/config"))
    }

    func putStatuslineConfig(_ cfg: StatuslineConfig) async throws -> StatuslineConfigResponse {
        try DaemonDates.decoder().decode(
            StatuslineConfigResponse.self, from: try await cPut("v1/statusline/config", body: cfg))
    }

    func statuslineSegments() async throws -> StatuslineSegmentsResponse {
        try DaemonDates.decoder().decode(StatuslineSegmentsResponse.self, from: try await cGet("v1/statusline/segments"))
    }

    // MARK: licensing (reads/quote only — Phase 4 owns checkout/cancel/recover)

    func license(reveal: Bool = false) async throws -> LicenseInfo {
        let query = reveal ? ["reveal": "1"] : [:]
        return try DaemonDates.decoder().decode(
            LicenseInfo.self, from: try await cGet("v1/license", query: query, bearer: reveal))
    }

    func licenseQuote() async throws -> LicenseQuote {
        try DaemonDates.decoder().decode(LicenseQuote.self, from: try await cGet("v1/license/quote"))
    }

    // MARK: licensing mutations (Phase 4 chunk A — checkout/cancel/recover/claim)

    // (CheckoutRequestBody lives at file scope below so a test can pin the
    // ui field — money review 2026-08-27 F5: nothing asserted the client
    // actually asks for the hosted flow.)

    func licenseCheckout(rung: String, echo: QuoteEcho, remindDaysBefore: Int?) async throws -> CheckoutHandoff {
        let data = try await cPost(
            "v1/license/checkout",
            body: CheckoutRequestBody(rung: rung, quote: echo, remindDaysBefore: remindDaysBefore))
        return try DaemonDates.decoder().decode(CheckoutHandoff.self, from: data)
    }

    func licenseCancel() async throws -> LicenseCancelResult {
        struct Empty: Encodable {}
        let data = try await cPost("v1/license/cancel", body: Empty())
        return try DaemonDates.decoder().decode(LicenseCancelResult.self, from: data)
    }

    func licenseRecover(email: String) async throws {
        struct Body: Encodable { var email: String }
        _ = try await cPost("v1/license/recover", body: Body(email: email))
    }

    func licenseClaim(token: String) async throws -> LicenseClaimResult {
        struct Body: Encodable { var token: String }
        let data = try await cPost("v1/license/recover/claim", body: Body(token: token))
        return try DaemonDates.decoder().decode(LicenseClaimResult.self, from: data)
    }

    // MARK: stash / move / config

    func stashAdopt(fingerprint: String, label: String? = nil) async throws -> CockpitAccount {
        struct Body: Encodable { var fingerprint: String; var label: String? }
        let data = try await cPost("v1/stash/adopt", body: Body(fingerprint: fingerprint, label: label))
        return try DaemonDates.decoder().decode(CockpitAccount.self, from: data)
    }

    func stashDiscard(fingerprint: String) async throws {
        struct Body: Encodable { var fingerprint: String }
        _ = try await cPost("v1/stash/discard", body: Body(fingerprint: fingerprint))
    }

    func adoptMove(configDir: String, label: String? = nil) async throws -> AdoptMoveResult {
        struct Body: Encodable {
            var configDir: String
            var label: String?
            enum CodingKeys: String, CodingKey {
                case configDir = "config_dir"
                case label
            }
        }
        let data = try await cPost("v1/adopt/move", body: Body(configDir: configDir, label: label))
        return try DaemonDates.decoder().decode(AdoptMoveResult.self, from: data)
    }

    func cockpitConfig() async throws -> CockpitConfig {
        try DaemonDates.decoder().decode(CockpitConfig.self, from: try await cGet("v1/config"))
    }

    func putConfig(_ cfg: CockpitConfig) async throws -> CockpitConfig {
        try DaemonDates.decoder().decode(CockpitConfig.self, from: try await cPut("v1/config", body: cfg))
    }

    // MARK: zero-paste browser sign-in

    func startBrowserLogin() async throws -> BrowserLoginStart {
        struct Empty: Encodable {}
        let data = try await cPost("v1/login/browser", body: Empty())
        return try DaemonDates.decoder().decode(BrowserLoginStart.self, from: data)
    }

    func browserLoginStatus(attempt: String) async throws -> BrowserLoginStatus {
        try DaemonDates.decoder().decode(
            BrowserLoginStatus.self,
            from: try await cGet("v1/login/browser/status", query: ["attempt": attempt], bearer: true))
    }
}

/// POST /v1/license/checkout's body. File-scope so a test can pin that the
/// 1.3.4 client asks for the HOSTED (browser) flow: hosted sessions carry
/// the success/cancel URLs whose cancel hit is the decider's real back-out
/// signal. The daemon's default stays "embedded" so a 1.3.3 app keeps its
/// sheet flow against a newer daemon.
struct CheckoutRequestBody: Encodable {
    var rung: String
    var ui = "hosted"
    var quote: QuoteEcho
    var remindDaysBefore: Int?
    enum CodingKeys: String, CodingKey {
        case rung, ui, quote
        case remindDaysBefore = "remind_days_before"
    }
}
