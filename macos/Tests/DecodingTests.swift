import XCTest
@testable import llmpilot

/// The wire contract: field names are the daemon's Go JSON tags, dates are
/// RFC 3339 with or without fractional seconds, bucket kinds are open.
final class DecodingTests: XCTestCase {
    func testStateDecodesDaemonShape() throws {
        let json = """
        {
          "accounts": [
            {
              "id": "acct-a", "label": "a", "email": "a@example.dev",
              "config_dir": "/Users/x/.claude",
              "keychain_service": "Claude Code-credentials-abcd1234",
              "pinned": true,
              "snapshot": {
                "account_id": "acct-a",
                "as_of": "2026-07-11T14:32:00.123456789Z",
                "buckets": [
                  {"kind": "session", "percent": 12.5,
                   "resets_at": "2026-07-11T16:05:00Z",
                   "severity": "normal", "active": true},
                  {"kind": "weekly_scoped", "scope": "Fable", "percent": 67},
                  {"kind": "quokka_hourly", "percent": 5}
                ]
              },
              "token_note": "needs a claude session"
            }
          ],
          "active_id": "acct-a",
          "events": [{"at": "2026-07-11T09:00:00Z", "kind": "auto_switch",
                      "account_id": "acct-a", "message": "x"}],
          "schedules": [{"id": "kai-0900", "account_id": "acct-a",
                         "hour": 9, "minute": 0}],
          "as_of": "2026-07-11T14:32:00Z"
        }
        """
        let s = try DaemonDates.decoder().decode(DaemonState.self, from: Data(json.utf8))
        XCTAssertEqual(s.activeID, "acct-a")
        XCTAssertEqual(s.accounts.count, 1)
        let a = s.accounts[0]
        XCTAssertEqual(a.email, "a@example.dev")
        XCTAssertTrue(a.pinned)
        XCTAssertEqual(a.tokenNote, "needs a claude session")
        let buckets = try XCTUnwrap(a.snapshot?.buckets)
        XCTAssertEqual(buckets.count, 3)
        XCTAssertEqual(buckets[0].shortLabel, "5h")
        // Fractional percents are real daemon output (Go float64) — the
        // integer-only fixture hid a decode failure that took the app down.
        XCTAssertEqual(buckets[0].percent, 12.5)
        XCTAssertEqual(buckets[0].percentInt, 13)
        XCTAssertEqual(buckets[0].active, true)
        XCTAssertNotNil(buckets[0].resetsAt)
        XCTAssertEqual(buckets[1].shortLabel, "Fable")
        // Unknown kind survives and renders as itself — bucket-agnostic.
        XCTAssertEqual(buckets[2].shortLabel, "quokka_hourly")
        XCTAssertEqual(s.schedules.first?.accountID, "acct-a")
        XCTAssertEqual(s.schedules.first?.hour, 9)
    }

    func testDateParsingSweepsFractionalWidths() throws {
        // Go's RFC3339Nano trims trailing zeros: width varies 0–9 per
        // response. Old-Foundation ISO8601DateFormatter accepts only
        // exactly 3 — the parser must not depend on it.
        let base = Date(timeIntervalSince1970: 1_784_548_800) // 2026-07-20T12:00:00Z
        let cases: [(String, TimeInterval)] = [
            ("2026-07-20T12:00:00Z", 0),
            ("2026-07-20T12:00:00.5Z", 0.5),
            ("2026-07-20T12:00:00.123Z", 0.123),
            ("2026-07-20T12:00:00.266011Z", 0.266011),
            ("2026-07-20T12:00:00.123456789Z", 0.123456789),
            ("2026-07-20T13:00:00.25+01:00", 0.25),
        ]
        for (raw, frac) in cases {
            let parsed = try XCTUnwrap(DaemonDates.parseRFC3339(raw), raw)
            XCTAssertEqual(parsed.timeIntervalSince(base), frac, accuracy: 0.000001, raw)
        }
        XCTAssertNil(DaemonDates.parseRFC3339("not a date"))
        XCTAssertNil(DaemonDates.parseRFC3339("2026-07-20T12:00:00.Z"))
    }

    func testStateDecodesLicenseStatus() throws {
        // license_status rides /v1/state; a trialing/lifetime grant is "Pro on".
        let licensed = """
        {"accounts": [], "active_id": "", "schedules": [],
         "license_status": "trialing", "as_of": "2026-07-12T14:32:00Z"}
        """
        let s = try DaemonDates.decoder().decode(DaemonState.self, from: Data(licensed.utf8))
        XCTAssertEqual(s.license, "trialing")
        XCTAssertTrue(s.licensed)

        // Go omits the field when empty — absent means no entitlement yet.
        let none = """
        {"accounts": [], "active_id": "", "schedules": [], "as_of": "2026-07-12T14:32:00Z"}
        """
        let s2 = try DaemonDates.decoder().decode(DaemonState.self, from: Data(none.utf8))
        XCTAssertNil(s2.license)
        XCTAssertFalse(s2.licensed)
    }

    func testDetectAndConfigShapes() throws {
        let detect = """
        [{"config_dir": "/Users/x/.claude", "email": "a@example.dev", "registered": false}]
        """
        let dirs = try DaemonDates.decoder().decode([DetectedDir].self, from: Data(detect.utf8))
        XCTAssertEqual(dirs.first?.configDir, "/Users/x/.claude")
        XCTAssertEqual(dirs.first?.registered, false)

        let config = """
        {"autopilot": {"disabled": false, "threshold_percent": 92.5},
         "notifications": {"thresholds": [75, 90]}}
        """
        let c = try DaemonDates.decoder().decode(DaemonConfig.self, from: Data(config.utf8))
        XCTAssertEqual(c.autopilot?.thresholdPercent, 92.5)
    }
}
