import XCTest
@testable import llmpilot

/// Hermetic transport tests for the auth-header contract in CockpitAPI.swift
/// (lines 108-176) — a deferred phase-0 review finding: the Bearer/Content-
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

    // MARK: - Authorization: present (bearer:true GETs, and every mutation via cSend)

    func testLicenseRevealSendsAuthorization() async throws {
        _ = try await client.license(reveal: true)
        XCTAssertEqual(Self.recorder.last()?.value(forHTTPHeaderField: "Authorization"), "Bearer test-install-token")
    }

    func testBrowserLoginStatusSendsAuthorization() async throws {
        _ = try await client.browserLoginStatus(attempt: "att-1")
        XCTAssertEqual(Self.recorder.last()?.value(forHTTPHeaderField: "Authorization"), "Bearer test-install-token")
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

    // MARK: - Authorization: absent (unguarded GETs, bearer defaults false)

    func testDoctorHasNoAuthorization() async throws {
        _ = try await client.doctor()
        XCTAssertNil(Self.recorder.last()?.value(forHTTPHeaderField: "Authorization"))
    }

    func testAnalyticsHasNoAuthorization() async throws {
        _ = try await client.analytics(days: 30)
        XCTAssertNil(Self.recorder.last()?.value(forHTTPHeaderField: "Authorization"))
    }

    func testCockpitConfigHasNoAuthorization() async throws {
        // GET /v1/config — handleConfigGet has no requireAuth (server.go).
        _ = try await client.cockpitConfig()
        let recorded = Self.recorder.last()
        XCTAssertNotNil(recorded, "no request recorded — the assertion below would pass vacuously")
        XCTAssertEqual(recorded?.url?.path, "/v1/config")
        XCTAssertNil(recorded?.value(forHTTPHeaderField: "Authorization"))
    }

    func testSchedulesHasNoAuthorization() async throws {
        _ = try await client.schedules()
        XCTAssertNil(Self.recorder.last()?.value(forHTTPHeaderField: "Authorization"))
    }

    func testLicenseWithoutRevealHasNoAuthorization() async throws {
        _ = try await client.license(reveal: false)
        XCTAssertNil(Self.recorder.last()?.value(forHTTPHeaderField: "Authorization"))
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
