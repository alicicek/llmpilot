import XCTest
@testable import llmpilot

/// Hermetic transport tests for the auth-header contract in CockpitAPI.swift
/// (cGet/cSend) — a deferred phase-0 review finding: the Bearer/Content-
/// Type discipline documented there had zero test coverage. `URLProtocol`
/// intercepts every request before a socket opens (no real daemon, no real
/// network), and `HTTPDaemonClient` is pointed at a throwaway `LLMPILOT_HOME`
/// via `daemon.port`/`daemon.token` files (DaemonClient.swift:56-81).
final class CockpitAPIHeaderTests: XCTestCase {
    /// Thread-safe, synchronous (no actor hop) so the recorded request is
    /// guaranteed visible the instant `startLoading` returns control to the
    /// loading system — an async recorder would race the test's assertion.
    private final class RequestRecorder: @unchecked Sendable {
        private var requests: [URLRequest] = []
        private let lock = NSLock()

        func record(_ req: URLRequest) {
            lock.lock(); defer { lock.unlock() }
            requests.append(req)
        }

        func reset() {
            lock.lock(); defer { lock.unlock() }
            requests.removeAll()
        }

        func last() -> URLRequest? {
            lock.lock(); defer { lock.unlock() }
            return requests.last
        }
    }

    private static let recorder = RequestRecorder()

    /// Intercepts every loopback request, records it, and answers with a
    /// canned body keyed by URL path — before any socket is opened.
    private final class StubProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool {
            request.url?.host == "127.0.0.1"
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            CockpitAPIHeaderTests.recorder.record(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.cannedBody(forPath: request.url?.path ?? ""))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}

        private static func cannedBody(forPath path: String) -> Data {
            let json: String
            if path.hasSuffix("/v1/schedules") {
                json = "[]"
            } else if path.hasSuffix("/v1/doctor") {
                json = #"{"as_of":"2026-08-07T12:00:00Z","clean":true,"problems":0,"findings":[],"checks":[]}"#
            } else if path.hasSuffix("/v1/analytics") {
                json = #"{"as_of":"2026-08-07T12:00:00Z"}"#
            } else if path.hasSuffix("/v1/license") {
                json = #"{"available":true,"active":false,"status":"none"}"#
            } else if path.hasSuffix("/v1/stash/adopt") {
                json = #"""
                {"id":"a1","label":"mira","email":"mira@example.dev",
                 "config_dir":"/tmp/a1","keychain_service":"svc","pinned":false}
                """#
            } else if path.hasSuffix("/v1/stash/discard") {
                json = "{}"
            } else if path.hasSuffix("/v1/adopt/move") {
                json = #"""
                {"account":{"id":"a1","label":"mira","email":"mira@example.dev",
                 "config_dir":"/tmp/a1","keychain_service":"svc","pinned":false},
                 "outcome":"complete","note":""}
                """#
            } else if path.hasSuffix("/v1/login/browser/status") {
                json = #"{"status":"pending"}"#
            } else {
                json = "{}"
            }
            return Data(json.utf8)
        }
    }

    private var tempHome: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        URLProtocol.registerClass(StubProtocol.self)
        Self.recorder.reset()
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("llmpilot-header-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        try "59999".write(to: tempHome.appendingPathComponent("daemon.port"), atomically: true, encoding: .utf8)
        try "test-install-token".write(to: tempHome.appendingPathComponent("daemon.token"), atomically: true, encoding: .utf8)
        setenv("LLMPILOT_HOME", tempHome.path, 1)
    }

    override func tearDownWithError() throws {
        URLProtocol.unregisterClass(StubProtocol.self)
        unsetenv("LLMPILOT_HOME")
        if let tempHome { try? FileManager.default.removeItem(at: tempHome) }
        try super.tearDownWithError()
    }

    private var client: HTTPDaemonClient { HTTPDaemonClient() }

    // MARK: - Authorization: present (license reveal, browser-login status, every mutation via cSend)

    func testLicenseRevealSendsAuthorization() async throws {
        _ = try await client.license(reveal: true)
        XCTAssertEqual(Self.recorder.last()?.value(forHTTPHeaderField: "Authorization"), "Bearer test-install-token")
    }

    func testBrowserLoginStatusSendsAuthorization() async throws {
        _ = try await client.browserLoginStatus(attempt: "att-1")
        assertLastSentToken("GET", "/v1/login/browser/status")
    }

    func testStashAdoptSendsAuthorization() async throws {
        _ = try await client.stashAdopt(fingerprint: "fp1", label: nil)
        XCTAssertEqual(Self.recorder.last()?.value(forHTTPHeaderField: "Authorization"), "Bearer test-install-token")
    }

    func testStashDiscardSendsAuthorization() async throws {
        try await client.stashDiscard(fingerprint: "fp1")
        XCTAssertEqual(Self.recorder.last()?.value(forHTTPHeaderField: "Authorization"), "Bearer test-install-token")
    }

    func testAdoptMoveSendsAuthorization() async throws {
        _ = try await client.adoptMove(configDir: "/tmp/a1", label: nil)
        XCTAssertEqual(Self.recorder.last()?.value(forHTTPHeaderField: "Authorization"), "Bearer test-install-token")
    }

    // The daemon 401s these without the token (internal/daemon/auth_test.go
    // TestStateMutationsRequireInstallToken). Only the request is under test,
    // so a response the canned "{}" cannot decode into is ignored (`try?`);
    // the path check stops a call that never sent from passing on an
    // earlier request's header.
    private func assertLastSentToken(_ method: String, _ pathSuffix: String, line: UInt = #line) {
        let req = Self.recorder.last()
        XCTAssertEqual(req?.httpMethod, method, line: line)
        XCTAssertTrue(req?.url?.path.hasSuffix(pathSuffix) ?? false, "last request: \(String(describing: req?.url))", line: line)
        XCTAssertEqual(req?.value(forHTTPHeaderField: "Authorization"), "Bearer test-install-token", line: line)
    }

    func testPutStatuslineConfigSendsAuthorization() async throws {
        _ = try? await client.putStatuslineConfig(StatuslineConfig(version: 1, segments: []))
        assertLastSentToken("PUT", "/v1/statusline/config")
    }

    func testPutConfigSendsAuthorization() async throws {
        _ = try? await client.putConfig(CockpitConfig())
        assertLastSentToken("PUT", "/v1/config")
    }

    func testScheduleMutationsSendAuthorization() async throws {
        _ = try? await client.createSchedule(accountID: "a1", hour: 9, minute: 0, model: nil, effort: nil)
        assertLastSentToken("POST", "/v1/schedules")
        _ = try? await client.updateSchedule(id: "s1", hour: 10, minute: 0)
        assertLastSentToken("PUT", "/v1/schedules/s1")
        try? await client.deleteSchedule(id: "s1")
        assertLastSentToken("DELETE", "/v1/schedules/s1")
    }

    func testSwitchAndAdoptSendAuthorization() async throws {
        try await client.switchAccount(to: "a1")
        assertLastSentToken("POST", "/v1/switch")
        try await client.adopt(configDir: "/tmp/a1")
        assertLastSentToken("POST", "/v1/adopt")
    }

    // MARK: - Authorization: present on every GET (the daemon 401s a tokenless read)

    func testDoctorSendsTheBearer() async throws {
        _ = try await client.doctor()
        assertLastSentToken("GET", "/v1/doctor")
    }

    func testAnalyticsSendsTheBearer() async throws {
        _ = try await client.analytics(days: 30)
        assertLastSentToken("GET", "/v1/analytics")
    }

    func testCockpitConfigSendsTheBearer() async throws {
        _ = try? await client.cockpitConfig()
        assertLastSentToken("GET", "/v1/config")
    }

    func testSchedulesSendsTheBearer() async throws {
        _ = try await client.schedules()
        assertLastSentToken("GET", "/v1/schedules")
    }

    func testLicenseWithoutRevealSendsTheBearer() async throws {
        _ = try await client.license(reveal: false)
        assertLastSentToken("GET", "/v1/license")
    }

    func testStateSendsTheBearer() async throws {
        _ = try? await client.state()
        assertLastSentToken("GET", "/v1/state")
    }

    func testDetectSendsTheBearer() async throws {
        _ = try? await client.detect()
        assertLastSentToken("GET", "/v1/detect")
    }

    func testDaemonConfigSendsTheBearer() async throws {
        _ = try? await client.config()
        assertLastSentToken("GET", "/v1/config")
    }

    func testEventsStreamSendsTheBearer() async throws {
        // The canned body has no `data:` line, so the stream ends right
        // after the request is recorded — only that request is under test.
        do { for try await _ in client.events() {} } catch {}
        assertLastSentToken("GET", "/v1/events")
    }

    func testHistorySendsTheBearer() async throws {
        _ = try? await client.history(accountID: "a1", kind: "five_hour", scope: nil)
        assertLastSentToken("GET", "/v1/history")
    }

    func testStatuslinePreviewSendsTheBearer() async throws {
        _ = try? await client.statuslinePreview(width: 80, tier: "truecolor", config: nil)
        assertLastSentToken("GET", "/v1/statusline/preview")
        _ = try? await client.statuslineSegmentPreview(config: "{}")
        assertLastSentToken("GET", "/v1/statusline/preview")
    }

    func testStatuslineConfigSendsTheBearer() async throws {
        _ = try? await client.statuslineConfig()
        assertLastSentToken("GET", "/v1/statusline/config")
    }

    func testStatuslineSegmentsSendsTheBearer() async throws {
        _ = try? await client.statuslineSegments()
        assertLastSentToken("GET", "/v1/statusline/segments")
    }

    func testLicenseQuoteSendsTheBearer() async throws {
        _ = try? await client.licenseQuote()
        assertLastSentToken("GET", "/v1/license/quote")
    }

    // MARK: - Authorization: absent only when there is no token file

    func testGetsWithoutATokenFileGoOutWithoutAuthorization() async throws {
        try FileManager.default.removeItem(at: tempHome.appendingPathComponent("daemon.token"))
        _ = try await client.doctor()
        var req = Self.recorder.last()
        XCTAssertTrue(req?.url?.path.hasSuffix("/v1/doctor") ?? false, "last request: \(String(describing: req?.url))")
        XCTAssertNil(req?.value(forHTTPHeaderField: "Authorization"))
        _ = try? await client.state()
        req = Self.recorder.last()
        XCTAssertTrue(req?.url?.path.hasSuffix("/v1/state") ?? false, "last request: \(String(describing: req?.url))")
        XCTAssertNil(req?.value(forHTTPHeaderField: "Authorization"))
    }

    // MARK: - Content-Type: application/json on every mutation

    func testStashAdoptCarriesJSONContentType() async throws {
        _ = try await client.stashAdopt(fingerprint: "fp1", label: nil)
        XCTAssertEqual(Self.recorder.last()?.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testStashDiscardCarriesJSONContentType() async throws {
        try await client.stashDiscard(fingerprint: "fp1")
        XCTAssertEqual(Self.recorder.last()?.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testAdoptMoveCarriesJSONContentType() async throws {
        _ = try await client.adoptMove(configDir: "/tmp/a1", label: nil)
        XCTAssertEqual(Self.recorder.last()?.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }
}
