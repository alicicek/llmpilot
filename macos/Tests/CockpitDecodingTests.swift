import XCTest
@testable import llmpilot

/// Decoding tests for the Phase 0 chunk B cockpit API surface
/// (Sources/API/CockpitModels.swift, Sources/API/CockpitAPI.swift). Every
/// fixture is built from the daemon's actual Go marshaling — see the
/// per-test file:line citations. Hermetic: no network, no daemon.
final class CockpitDecodingTests: XCTestCase {
    // MARK: - history (internal/daemon/server.go:851-864)

    func testHistoryResponseHappyPath() throws {
        // server.go:859-863: samples always {at, percent} (daemon.go:346-349).
        let json = #"""
        {"samples": [{"at": "2026-07-11T14:32:00Z", "percent": 12.5},
                      {"at": "2026-07-11T14:37:00Z", "percent": 18}]}
        """#
        let r = try DaemonDates.decoder().decode(HistoryResponse.self, from: Data(json.utf8))
        XCTAssertEqual(r.samples.count, 2)
        XCTAssertEqual(r.samples[0].percent, 12.5)
    }

    func testHistoryResponseNullSamplesDecodesToEmpty() throws {
        let json = #"{"samples": null}"#
        let r = try DaemonDates.decoder().decode(HistoryResponse.self, from: Data(json.utf8))
        XCTAssertEqual(r.samples, [])
    }

    func testHistoryResponseAbsentSamplesDecodesToEmpty() throws {
        let r = try DaemonDates.decoder().decode(HistoryResponse.self, from: Data("{}".utf8))
        XCTAssertEqual(r.samples, [])
    }

    // MARK: - doctor (internal/doctor/doctor.go:101-148)

    func testDoctorReportHappyPath() throws {
        // doctor.go:136-148 (Report), 101-109 (Finding), 78-83 (Remedy),
        // 127-132 (Check). 3-digit fractional second on as_of.
        let json = #"""
        {"as_of": "2026-07-11T14:32:00.123Z", "clean": false, "problems": 1,
         "findings": [{"id": "stale-kai", "check": "stale", "severity": "warning",
                       "title": "kai's token is stale", "detail": "needs a session",
                       "accounts": ["kai"],
                       "remedy": {"verb": "switch", "label": "Switch to kai",
                                  "target": "kai"}}],
         "checks": [{"id": "stale", "title": "Stale tokens", "state": "finding"},
                    {"id": "install", "title": "Install", "state": "not_checked",
                     "why": "launch agent unreadable"}]}
        """#
        let r = try DaemonDates.decoder().decode(DoctorReport.self, from: Data(json.utf8))
        XCTAssertFalse(r.clean)
        XCTAssertEqual(r.problems, 1)
        XCTAssertEqual(r.findings.count, 1)
        XCTAssertEqual(r.findings[0].accounts, ["kai"])
        XCTAssertEqual(r.findings[0].remedy.verb, "switch")
        XCTAssertNil(r.findings[0].remedy.command)
        XCTAssertEqual(r.checks.count, 2)
        XCTAssertEqual(r.checks[1].why, "launch agent unreadable")
    }

    func testDoctorReportNullFindingsAndChecksDecodeToEmpty() throws {
        // Report.Findings/.Checks carry no `omitempty` — a clean sweep with
        // nothing to report still marshals both as JSON null.
        let json = #"""
        {"as_of": "2026-07-11T14:32:00Z", "clean": true, "problems": 0,
         "findings": null, "checks": null}
        """#
        let r = try DaemonDates.decoder().decode(DoctorReport.self, from: Data(json.utf8))
        XCTAssertTrue(r.clean)
        XCTAssertEqual(r.findings, [])
        XCTAssertEqual(r.checks, [])
    }

    func testDoctorFindingAccountsNullDecodesToEmpty() throws {
        let json = #"""
        {"as_of": "2026-07-11T14:32:00Z", "clean": false, "problems": 1,
         "findings": [{"id": "x", "check": "x", "severity": "info", "title": "t",
                       "detail": "d", "accounts": null,
                       "remedy": {"verb": "none", "label": "nothing to do"}}],
         "checks": []}
        """#
        let r = try DaemonDates.decoder().decode(DoctorReport.self, from: Data(json.utf8))
        XCTAssertEqual(r.findings[0].accounts, [])
    }

    // MARK: - analytics (internal/daemon/server.go:878-972)

    func testAnalyticsResponseHappyPath() throws {
        // server.go:901-908 (cellOut), 964-971 (response); analytics.go:31-36
        // (Tokens). 9-digit fractional second on as_of.
        let json = #"""
        {"cells": [{"account_id": "kai", "project": "llmpilot", "model": "claude-sonnet-5",
                     "day": "2026-07-10", "messages": 42,
                     "tokens": {"input": 1000, "output": 2000,
                                "cache_creation": 500, "cache_read": 9000}}],
         "hour_weekday": [[0,1],[2,3]],
         "files_total": 100, "files_parsed": 5, "files_reused": 95,
         "as_of": "2026-07-11T14:32:00.123456789Z"}
        """#
        let r = try DaemonDates.decoder().decode(AnalyticsResponse.self, from: Data(json.utf8))
        XCTAssertEqual(r.cells.count, 1)
        XCTAssertEqual(r.cells[0].accountID, "kai")
        XCTAssertEqual(r.cells[0].tokens.cacheRead, 9000)
        XCTAssertEqual(r.hourWeekday, [[0, 1], [2, 3]])
        XCTAssertEqual(r.filesTotal, 100)
    }

    func testAnalyticsResponseNullArraysDecodeToEmpty() throws {
        let json = #"""
        {"cells": null, "hour_weekday": null, "files_total": 0,
         "files_parsed": 0, "files_reused": 0,
         "as_of": "2026-07-11T14:32:00Z"}
        """#
        let r = try DaemonDates.decoder().decode(AnalyticsResponse.self, from: Data(json.utf8))
        XCTAssertEqual(r.cells, [])
        XCTAssertEqual(r.hourWeekday, [])
    }

    func testAnalyticsResponseSharedAccountEmptyID() throws {
        // account_id "" marks the shared global config dir — never omitted.
        let json = #"""
        {"cells": [{"account_id": "", "project": "scratch", "model": "claude-sonnet-5",
                     "day": "2026-07-10", "messages": 1,
                     "tokens": {"input": 1, "output": 1, "cache_creation": 0, "cache_read": 0}}],
         "hour_weekday": [], "files_total": 0, "files_parsed": 0, "files_reused": 0,
         "as_of": "2026-07-11T14:32:00Z"}
        """#
        let r = try DaemonDates.decoder().decode(AnalyticsResponse.self, from: Data(json.utf8))
        XCTAssertEqual(r.cells[0].accountID, "")
    }

    // MARK: - statusline (internal/daemon/statusline.go, internal/statusline)

    func testStatuslinePreviewResponseHappyPath() throws {
        // statusline.go:84-92.
        let json = #"""
        {"line": "[acct 1/2] 5h 23%", "plain": "[acct 1/2] 5h 23%",
         "width": 80, "tier": "16"}
        """#
        let r = try DaemonDates.decoder().decode(StatuslinePreviewResponse.self, from: Data(json.utf8))
        XCTAssertEqual(r.width, 80)
        XCTAssertEqual(r.tier, "16")
    }

    func testStatuslineConfigResponseGetShapeWithLoadError() throws {
        // GET always carries load_error, even when empty (statusline.go:94-102).
        let json = #"""
        {"config": {"version": 1, "preset": "runway", "segments": [{"id": "account"}, {"id": "usage"}]},
         "load_error": ""}
        """#
        let r = try DaemonDates.decoder().decode(StatuslineConfigResponse.self, from: Data(json.utf8))
        XCTAssertEqual(r.config.preset, "runway")
        XCTAssertEqual(r.config.segments.count, 2)
        XCTAssertEqual(r.loadError, "")
    }

    func testStatuslineConfigResponsePutShapeOmitsLoadError() throws {
        // PUT's response has no load_error key at all (statusline.go:104-119).
        let json = #"{"config": {"version": 1, "segments": [{"id": "dir"}]}}"#
        let r = try DaemonDates.decoder().decode(StatuslineConfigResponse.self, from: Data(json.utf8))
        XCTAssertNil(r.loadError)
    }

    func testStatuslineConfigNullSegmentsDecodesToEmpty() throws {
        let json = #"{"config": {"version": 1, "segments": null}}"#
        let r = try DaemonDates.decoder().decode(StatuslineConfigResponse.self, from: Data(json.utf8))
        XCTAssertEqual(r.config.segments, [])
    }

    func testStatuslineConfigSegmentOptionsRoundTripThroughJSONValue() throws {
        // SegmentConfig.Options is Go `map[string]any` (statusline.go:54-57).
        let json = #"""
        {"version": 1, "segments":
         [{"id": "usage", "options": {"mode": "bar"}},
          {"id": "account", "options": {"privacy": true}}]}
        """#
        let cfg = try DaemonDates.decoder().decode(StatuslineConfig.self, from: Data(json.utf8))
        XCTAssertEqual(cfg.segments[0].options?["mode"], .string("bar"))
        XCTAssertEqual(cfg.segments[1].options?["privacy"], .bool(true))

        // Encodable round-trips the same shape back out.
        let reEncoded = try JSONEncoder().encode(cfg)
        let decoded = try DaemonDates.decoder().decode(StatuslineConfig.self, from: reEncoded)
        XCTAssertEqual(decoded, cfg)
    }

    // daemonErrorMessage's full ladder: envelope text > generic status line
    // for any other JSON object (leaked braces in a flash banner are the
    // bug) > raw text > status line.
    func testDaemonErrorMessageLadder() {
        XCTAssertEqual(
            daemonErrorMessage(from: Data(#"{"error":"cooldown active"}"#.utf8), code: 409),
            "cooldown active")
        XCTAssertEqual(
            daemonErrorMessage(from: Data(#"{"error":"x","code":"pro_required"}"#.utf8), code: 402),
            "x")
        XCTAssertEqual(
            daemonErrorMessage(from: Data(#"{"error":""}"#.utf8), code: 500), "http 500")
        XCTAssertEqual(
            daemonErrorMessage(from: Data(#"{"ok":true}"#.utf8), code: 500), "http 500")
        XCTAssertEqual(
            daemonErrorMessage(from: Data("plain text refusal".utf8), code: 409),
            "plain text refusal")
        XCTAssertEqual(daemonErrorMessage(from: Data(), code: 502), "http 502")
        XCTAssertEqual(
            daemonErrorMessage(from: Data("   \n".utf8), code: 500), "http 500")
    }

    // The guard's FAIL case (repo rule: test every guard's fail case): a
    // nested array/object here means the wire contract changed, and the old
    // silent `.null` coercion would wipe the value on the next config PUT
    // round-trip. JSONValue must throw, not coerce.
    func testJSONValueRefusesNestedContainers() {
        XCTAssertThrowsError(try JSONDecoder().decode(
            [String: JSONValue].self, from: Data(#"{"x":[1,2]}"#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(
            [String: JSONValue].self, from: Data(#"{"x":{"y":1}}"#.utf8)))
    }

    func testStatuslineSegmentsResponseHappyPathAndNullTolerance() throws {
        // render.go:150-158 (SegmentSpec), segments.go:16-22 (OptionSpec),
        // statusline.go:222-227 (Preset).
        let json = #"""
        {"segments": [{"id": "burn", "name": "Burn wall", "desc": "burn-rate",
                        "priority": 80, "fleet": true,
                        "options": [{"key": "mode", "label": "Display", "type": "enum",
                                     "values": ["percent", "bar"], "default": "percent"}]}],
         "presets": [{"id": "runway", "name": "Runway", "desc": "the classic line",
                       "config": {"version": 1, "segments": [{"id": "account"}]}}]}
        """#
        let r = try DaemonDates.decoder().decode(StatuslineSegmentsResponse.self, from: Data(json.utf8))
        XCTAssertEqual(r.segments[0].deps, []) // omitempty, absent here
        XCTAssertTrue(r.segments[0].fleet)
        XCTAssertEqual(r.segments[0].options[0].defaultValue, .string("percent"))
        XCTAssertEqual(r.presets[0].config.segments[0].id, "account")

        let empty = try DaemonDates.decoder().decode(
            StatuslineSegmentsResponse.self, from: Data(#"{"segments": null, "presets": null}"#.utf8))
        XCTAssertEqual(empty.segments, [])
        XCTAssertEqual(empty.presets, [])
    }

    // MARK: - licensing (internal/daemon/license.go)

    func testLicenseInfoHappyPathWithTrial() throws {
        // license.go:152-169 (licenseInfo), 144-148 (trialInfo).
        let json = #"""
        {"available": true, "active": true, "status": "trialing", "kind": "trial",
         "features": ["autopilot", "scheduling"], "seats": 1,
         "trial": {"ends_at": "2026-07-19T14:32:00Z",
                    "charge_date": "2026-07-19T14:32:00Z", "days_left": 8},
         "last_validated": "2026-07-11T14:32:00.5Z",
         "license_id_masked": "lic_••••ab12",
         "nocard_trial_used": true}
        """#
        let r = try DaemonDates.decoder().decode(LicenseInfo.self, from: Data(json.utf8))
        XCTAssertTrue(r.active)
        XCTAssertEqual(r.features, ["autopilot", "scheduling"])
        XCTAssertEqual(r.trial?.daysLeft, 8)
        XCTAssertNil(r.licenseID) // only present under ?reveal=1
        XCTAssertTrue(r.nocardTrialUsed)
    }

    func testLicenseInfoUnavailableMinimalShape() throws {
        // g.Available == false short-circuits to this minimal body (license.go:194-198).
        let json = #"""
        {"available": false, "active": false, "status": "unavailable",
         "nocard_trial_used": false}
        """#
        let r = try DaemonDates.decoder().decode(LicenseInfo.self, from: Data(json.utf8))
        XCTAssertFalse(r.available)
        XCTAssertEqual(r.status, "unavailable")
        XCTAssertEqual(r.features, [])
        XCTAssertEqual(r.seats, 0)
        XCTAssertNil(r.trial)
        XCTAssertNil(r.errorCode)
    }

    func testLicenseInfoRevealCarriesFullID() throws {
        let json = #"""
        {"available": true, "active": true, "status": "lifetime",
         "license_id": "lic_full_abc123", "license_id_masked": "lic_••••c123",
         "nocard_trial_used": false}
        """#
        let r = try DaemonDates.decoder().decode(LicenseInfo.self, from: Data(json.utf8))
        XCTAssertEqual(r.licenseID, "lic_full_abc123")
    }

    func testLicenseQuoteHappyPathAndCurrencyMapIsOpen() throws {
        // license_test.go:215 pins the worker's shape verbatim, proxied by
        // handleLicenseQuote (license.go:420-438).
        let json = #"""
        {"trial_days":8,"charge_date":"2026-07-23T12:00:00Z",
         "prices":{"full":{"gbp":999,"usd":1299},"discount":{"gbp":599,"usd":799}}}
        """#
        let q = try DaemonDates.decoder().decode(LicenseQuote.self, from: Data(json.utf8))
        XCTAssertEqual(q.trialDays, 8)
        XCTAssertEqual(q.prices?.full["usd"], 1299)
        XCTAssertEqual(q.prices?.discount["gbp"], 599)
    }

    func testLicenseQuoteMissingPricesDecodeToEmptyMaps() throws {
        let json = #"{"trial_days":8,"charge_date":"2026-07-23T12:00:00Z","prices":{}}"#
        let q = try DaemonDates.decoder().decode(LicenseQuote.self, from: Data(json.utf8))
        XCTAssertEqual(q.prices?.full, [:])
        XCTAssertEqual(q.prices?.discount, [:])
    }

    // The body is a third party's (the worker's, proxied verbatim by
    // license.go handleLicenseQuote) — a renamed or regionally absent field
    // must degrade the paywall copy, never make the whole quote undecodable.
    func testLicenseQuoteToleratesMissingThirdPartyFields() throws {
        let q = try DaemonDates.decoder().decode(
            LicenseQuote.self, from: Data(#"{"trial_days":8}"#.utf8))
        XCTAssertEqual(q.trialDays, 8)
        XCTAssertNil(q.chargeDate)
        XCTAssertNil(q.prices)
        let empty = try DaemonDates.decoder().decode(
            LicenseQuote.self, from: Data("{}".utf8))
        XCTAssertNil(empty.trialDays)
    }

    // MARK: - licensing mutations (Phase 4 chunk A: license.go:246-548)

    func testCheckoutHandoffHappyPath() throws {
        // license.go:304: writeJSON(w, 200, map[string]string{"url": ...,
        // "session_id": ...}).
        let json = #"{"url":"https://checkout.stripe.com/c/pay/full?remind=2","session_id":"cs_test_123"}"#
        let r = try DaemonDates.decoder().decode(CheckoutHandoff.self, from: Data(json.utf8))
        XCTAssertEqual(r.url, "https://checkout.stripe.com/c/pay/full?remind=2")
        XCTAssertEqual(r.sessionID, "cs_test_123")
    }

    func testCheckoutHandoffToleratesAMissingSessionID() throws {
        let r = try DaemonDates.decoder().decode(
            CheckoutHandoff.self, from: Data(#"{"url":"https://pay/full"}"#.utf8))
        XCTAssertEqual(r.url, "https://pay/full")
        XCTAssertNil(r.sessionID)
    }

    func testLicenseCancelResultHappyPath() throws {
        // license.go:478: {"status": stored.Status} — "lapsed".
        let r = try DaemonDates.decoder().decode(
            LicenseCancelResult.self, from: Data(#"{"status":"lapsed"}"#.utf8))
        XCTAssertEqual(r.status, "lapsed")
    }

    func testLicenseClaimResultHappyPath() throws {
        // license.go:547: {"status": view.Status}.
        let r = try DaemonDates.decoder().decode(
            LicenseClaimResult.self, from: Data(#"{"status":"lifetime"}"#.utf8))
        XCTAssertEqual(r.status, "lifetime")
    }

    // MARK: - schedules (pilotapi/types.go:81-91) — round-trip

    func testScheduleRecordRoundTripsThroughCodable() throws {
        let original = ScheduleRecord(id: "kai-0900", accountID: "kai", hour: 9, minute: 0,
                                       model: "claude-sonnet-5", effort: "low")
        let data = try JSONEncoder().encode(original)
        let decoded = try DaemonDates.decoder().decode(ScheduleRecord.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testScheduleRecordDecodesServerShapeWithoutModelEffort() throws {
        // model/effort are `omitempty` — a cheapest-default schedule omits both.
        let json = #"{"id": "kai-0900", "account_id": "kai", "hour": 9, "minute": 0}"#
        let sc = try DaemonDates.decoder().decode(ScheduleRecord.self, from: Data(json.utf8))
        XCTAssertNil(sc.model)
        XCTAssertNil(sc.effort)
    }

    func testScheduleCreateRequestOmitsNilModelEffort() throws {
        // Mirrors Go's `omitempty` on Model/Effort (pilotapi/types.go:89-90):
        // the encoded body must not send the keys at all when unset.
        let bare = ScheduleCreateRequest(accountID: "kai", hour: 9, minute: 0, model: nil, effort: nil)
        let data = try JSONEncoder().encode(bare)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(obj.keys), ["account_id", "hour", "minute"])

        let full = ScheduleCreateRequest(accountID: "kai", hour: 9, minute: 0, model: "claude-sonnet-5", effort: "low")
        let data2 = try JSONEncoder().encode(full)
        let obj2 = try XCTUnwrap(try JSONSerialization.jsonObject(with: data2) as? [String: Any])
        XCTAssertEqual(Set(obj2.keys), ["account_id", "hour", "minute", "model", "effort"])
    }

    // MARK: - accounts / adopt / stash (pilotapi/types.go:14-21; server.go)

    func testCockpitAccountHappyPath() throws {
        // As served raw by POST /v1/stash/adopt (server.go:341).
        let json = #"""
        {"id": "acct-a", "label": "kai", "email": "kai@example.dev",
         "config_dir": "/Users/x/.claude-2", "keychain_service": "Claude Code-credentials-abcd",
         "pinned": false}
        """#
        let a = try DaemonDates.decoder().decode(CockpitAccount.self, from: Data(json.utf8))
        XCTAssertEqual(a.configDir, "/Users/x/.claude-2")
        XCTAssertFalse(a.pinned)
    }

    func testAdoptMoveResultHappyPath() throws {
        // server.go:814-818.
        let json = #"""
        {"account": {"id": "acct-a", "label": "kai", "email": "kai@example.dev",
                       "config_dir": "/Users/x/.llmpilot/accounts/acct-a",
                       "keychain_service": "llmpilot-acct-a", "pinned": false},
         "outcome": "clone_suspect", "note": "a second copy may still exist"}
        """#
        let r = try DaemonDates.decoder().decode(AdoptMoveResult.self, from: Data(json.utf8))
        XCTAssertEqual(r.outcome, "clone_suspect")
        XCTAssertEqual(r.account.label, "kai")
    }

    // MARK: - config (internal/store/config.go:17-24)

    func testCockpitConfigRoundTripsFullShape() throws {
        let cfg = CockpitConfig(
            autopilot: CockpitAutopilotConfig(disabled: false, thresholdPercent: 90, cooldownMinutes: 15),
            notifications: CockpitNotificationsConfig(disabled: false, thresholds: [75, 90]),
            planCostMonthly: ["acct-a": 20.0])
        let data = try JSONEncoder().encode(cfg)
        let decoded = try DaemonDates.decoder().decode(CockpitConfig.self, from: data)
        XCTAssertEqual(decoded, cfg)
    }

    func testCockpitConfigDecodesMinimalServerShape() throws {
        let json = #"{"autopilot": {}, "notifications": {"thresholds": [75, 90]}}"#
        let cfg = try DaemonDates.decoder().decode(CockpitConfig.self, from: Data(json.utf8))
        XCTAssertEqual(cfg.notifications?.thresholds, [75, 90])
        XCTAssertNil(cfg.planCostMonthly)
    }

    // MARK: - browser sign-in (internal/daemon/login.go)

    func testBrowserLoginStartHappyPath() throws {
        let json = #"{"authorize_url": "https://claude.ai/oauth/authorize?...", "attempt_id": "abc123"}"#
        let r = try DaemonDates.decoder().decode(BrowserLoginStart.self, from: Data(json.utf8))
        XCTAssertEqual(r.attemptID, "abc123")
    }

    func testBrowserLoginStatusAllStates() throws {
        // login.go:296-298 — error/account_id are always present (map[string]string), possibly "".
        let pending = #"{"status": "pending", "error": "", "account_id": ""}"#
        let p = try DaemonDates.decoder().decode(BrowserLoginStatus.self, from: Data(pending.utf8))
        XCTAssertEqual(p.status, "pending")

        let done = #"{"status": "done", "error": "", "account_id": "acct-a"}"#
        let d = try DaemonDates.decoder().decode(BrowserLoginStatus.self, from: Data(done.utf8))
        XCTAssertEqual(d.accountID, "acct-a")

        let failed = #"{"status": "failed", "error": "the sign-in timed out — try again", "account_id": ""}"#
        let f = try DaemonDates.decoder().decode(BrowserLoginStatus.self, from: Data(failed.utf8))
        XCTAssertEqual(f.error, "the sign-in timed out — try again")
    }

    // MARK: - error envelopes (415 / 402)

    func testErrorEnvelopeDecodes415WithoutCode() throws {
        // requireJSON's plain httpError (server.go:111-115) — no machine code.
        let json = #"{"error": "Content-Type must be application/json"}"#
        let e = try JSONDecoder().decode(ErrorEnvelope.self, from: Data(json.utf8))
        XCTAssertEqual(e.error, "Content-Type must be application/json")
        XCTAssertNil(e.code)
    }

    func testErrorEnvelopeDecodes402WithProRequiredCode() throws {
        // proRefusal's typed 402 (server.go:990-995).
        let json = #"""
        {"error": "Fresh windows run on your schedule — that is the autopilot's job.",
         "code": "pro_required"}
        """#
        let e = try JSONDecoder().decode(ErrorEnvelope.self, from: Data(json.utf8))
        XCTAssertEqual(e.code, "pro_required")
    }

    // MARK: - RFC3339Nano fractional-width sweep (dedicated cases beyond the
    // ones folded into the fixtures above)

    func testDatesWithShortAndFullFractionalWidthsDecode() throws {
        let short = try DaemonDates.decoder().decode(
            HistorySample.self, from: Data(#"{"at": "2026-07-11T14:32:00.123Z", "percent": 1}"#.utf8))
        XCTAssertNotNil(short.at)

        let full = try DaemonDates.decoder().decode(
            HistorySample.self, from: Data(#"{"at": "2026-07-11T14:32:00.123456789Z", "percent": 1}"#.utf8))
        XCTAssertNotNil(full.at)

        // Same instant at the second, different sub-second precision on the wire.
        XCTAssertEqual(short.at.timeIntervalSince1970.rounded(), full.at.timeIntervalSince1970.rounded())
    }
}
