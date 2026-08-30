import XCTest

@testable import llmpilot

/// The recovery deep link's boundary: a URL is untrusted input from any
/// browser, and everything that isn't exactly llmpilot://recover with a
/// well-formed one-time token must die in the parser — before a claim,
/// a wire call, or an alert can happen.
@MainActor
final class RecoveryLinkTests: XCTestCase {
    private let hex64 = String(repeating: "0123456789abcdef", count: 4)

    func testTheRealLinkShapeParses() {
        XCTAssertEqual(
            RecoveryLink.token(from: URL(string: "llmpilot://recover?token=\(hex64)")!), hex64)
        // Single-slash normalization (path form) is the same link.
        XCTAssertEqual(
            RecoveryLink.token(from: URL(string: "llmpilot:/recover?token=\(hex64)")!), hex64)
        // Hex case is normalized, never refused — the token compares hashed
        // server-side, lowercased here for one canonical shape.
        XCTAssertEqual(
            RecoveryLink.token(from: URL(string: "llmpilot://recover?token=\(hex64.uppercased())")!),
            hex64)
    }

    func testForeignSchemesAndTargetsAreRefused() {
        for bad in [
            "https://recover?token=\(hex64)",            // wrong scheme
            "llmpilot://recovery?token=\(hex64)",        // wrong target
            "llmpilot://checkout?token=\(hex64)",        // some other feature's link
            "llmpilot://recover/extra?token=\(hex64)",   // trailing path segment
        ] {
            XCTAssertNil(RecoveryLink.token(from: URL(string: bad)!), bad)
        }
    }

    func testMalformedTokensAreRefused() {
        for bad in [
            "llmpilot://recover",                                  // no query
            "llmpilot://recover?token=",                           // empty
            "llmpilot://recover?token=abc123",                     // too short
            "llmpilot://recover?token=\(hex64)ff",                 // too long
            "llmpilot://recover?token=\(String(repeating: "g", count: 64))", // non-hex
            "llmpilot://recover?other=\(hex64)",                   // wrong param
        ] {
            XCTAssertNil(RecoveryLink.token(from: URL(string: bad)!), bad)
        }
    }

    /// Builds a handler with alert seams stubbed to counters; confirm
    /// defaults to "Restore" so the claim path runs unless a test flips it.
    private func makeHandler(_ api: StubCockpitAPI) -> (RecoveryLinkHandler, Counters) {
        let c = Counters()
        let h = RecoveryLinkHandler()
        h.api = api
        h.retryDelay = 0
        h.confirm = { c.confirms += 1; return c.consent }
        h.presentSuccess = { c.successes += 1 }
        h.presentFailure = { _ in c.failures += 1 }
        return (h, c)
    }

    final class Counters {
        var confirms = 0
        var successes = 0
        var failures = 0
        var consent = true
    }

    func testJunkNeverReachesTheWireAndNeverEvenAsksToConfirm() async {
        let api = StubCockpitAPI()
        api.licenseClaimResult = .success(LicenseClaimResult(status: "lifetime"))
        let (h, c) = makeHandler(api)
        h.handle(URL(string: "llmpilot://recover?token=nope")!)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(api.licenseClaimRequests.count, 0, "junk must never reach the wire")
        XCTAssertEqual(c.confirms, 0, "a malformed link must not even raise the consent dialog")
    }

    func testCancelledConsentClaimsNothing() async {
        let api = StubCockpitAPI()
        api.licenseClaimResult = .success(LicenseClaimResult(status: "lifetime"))
        let (h, c) = makeHandler(api)
        c.consent = false
        h.handle(URL(string: "llmpilot://recover?token=\(hex64)")!)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(c.confirms, 1, "the human is asked")
        XCTAssertEqual(api.licenseClaimRequests.count, 0, "Cancel means no license mutation")
        // The gate reset — a later genuine link still works.
        c.consent = true
        h.handle(URL(string: "llmpilot://recover?token=\(hex64)")!)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(api.licenseClaimRequests.count, 1)
    }

    func testConfirmedClaimSucceedsAndAcknowledges() async {
        let api = StubCockpitAPI()
        api.licenseClaimResult = .success(LicenseClaimResult(status: "lifetime"))
        let (h, c) = makeHandler(api)
        h.handle(URL(string: "llmpilot://recover?token=\(hex64)")!)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(api.licenseClaimRequests, [hex64])
        XCTAssertEqual(c.successes, 1, "success is acknowledged, not silent")
        XCTAssertEqual(c.failures, 0)
    }

    func testAnAlreadyClaimedLinkReClickedNeverReClaims() async {
        // The recovery page doesn't change after a claim, so re-clicking
        // "Open llmpilot" is expected — it must not burn a second claim on
        // the now-spent token, nor re-ask to confirm (F3).
        let api = StubCockpitAPI()
        api.licenseClaimResult = .success(LicenseClaimResult(status: "lifetime"))
        let (h, c) = makeHandler(api)
        let url = URL(string: "llmpilot://recover?token=\(hex64)")!
        h.handle(url)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(api.licenseClaimRequests.count, 1)
        h.handle(url) // the re-click, in a LATER main-actor turn
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(api.licenseClaimRequests.count, 1, "the spent token is never re-claimed")
        XCTAssertEqual(c.confirms, 1, "a re-click doesn't re-prompt")
    }

    func testAFreshLinkAfterAFailureStillClaims() async {
        // The inFlight gate must reset on the failure branch too, across the
        // await boundary — the mutation that removed the reset (a claim-once-
        // per-launch handler) must fail here (F3).
        let api = StubCockpitAPI()
        api.licenseClaimResult = .failure(ApiError(status: 400, code: "invalid_or_expired", message: "x"))
        let (h, c) = makeHandler(api)
        let expired = String(repeating: "ab", count: 32)
        h.handle(URL(string: "llmpilot://recover?token=\(expired)")!)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(c.failures, 1)
        // A second, DIFFERENT link (the user requested a fresh email) must
        // still be claimable — the gate did not latch shut.
        api.licenseClaimResult = .success(LicenseClaimResult(status: "lifetime"))
        h.handle(URL(string: "llmpilot://recover?token=\(hex64)")!)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(api.licenseClaimRequests, [expired, hex64], "reset-on-failure, so a fresh link claims")
        XCTAssertEqual(c.successes, 1)
    }

    func testColdLaunchRetriesWhileTheDaemonIsStillComingUp() async {
        // The canonical case: the link launched the app; the first claims
        // fail with DaemonError.down until the daemon's port file appears.
        let api = StubCockpitAPI()
        api.licenseClaimResultQueue = [
            .failure(DaemonError.down),
            .failure(DaemonError.down),
            .success(LicenseClaimResult(status: "lifetime")),
        ]
        api.licenseClaimResult = .success(LicenseClaimResult(status: "lifetime"))
        let (h, c) = makeHandler(api)
        h.handle(URL(string: "llmpilot://recover?token=\(hex64)")!)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(api.licenseClaimRequests.count, 3, "retried past the daemon-still-starting window")
        XCTAssertEqual(c.successes, 1)
        XCTAssertEqual(c.failures, 0, "a cold start that then succeeds never shows an error")
    }

    func testDaemonDownCopyIsNotTheRawInternalString() {
        XCTAssertEqual(
            RecoveryLinkHandler.failureCopy(for: DaemonError.down),
            "llmpilot is still starting up. Open the recovery link again in a few seconds.")
        XCTAssertTrue(
            RecoveryLinkHandler.failureCopy(for: ApiError(status: 409, code: "seat_limit_reached", message: "x"))
                .contains("maximum number of Macs"))
    }
}
