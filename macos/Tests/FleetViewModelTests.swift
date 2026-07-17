import XCTest
@testable import llmpilot

@MainActor
final class FleetViewModelTests: XCTestCase {
    private func makeModel(_ api: StubAPI) -> FleetViewModel {
        FleetViewModel(api: api, autostart: false)
    }

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "privacyMode")
        UserDefaults.standard.removeObject(forKey: "iconMode")
    }

    func testRefreshGoesLiveWithFleet() async throws {
        let api = StubAPI()
        api.stateResult = .success(Fixtures.twoAccounts())
        api.configResult = DaemonConfig(
            autopilot: .init(disabled: false, thresholdPercent: 85))
        let model = makeModel(api)
        try await model.refresh()
        XCTAssertEqual(model.status, .live)
        XCTAssertEqual(model.accounts.map(\.id), ["acct-a", "acct-b"])
        XCTAssertTrue(model.isActive(model.accounts[0]))
        XCTAssertFalse(model.isActive(model.accounts[1]))
        XCTAssertEqual(model.autopilotLine, "autopilot on · rotates at 85%")
    }

    func testRefreshFailureIsDown() async {
        let api = StubAPI()
        api.stateResult = .failure(DaemonError.down)
        let model = makeModel(api)
        await XCTAssertThrowsErrorAsync(try await model.refresh())
        XCTAssertEqual(model.status, .down)
    }

    func testActionRefreshFailureNeverDowngradesLive() async throws {
        let api = StubAPI()
        api.stateResult = .success(Fixtures.twoAccounts())
        let model = makeModel(api)
        try await model.refresh()
        XCTAssertEqual(model.status, .live)
        api.stateResult = .failure(DaemonError.down)
        await XCTAssertThrowsErrorAsync(try await model.refresh())
        // Only the connect loop may declare down once live — a transient
        // action-path failure must not flash "daemon not running".
        XCTAssertEqual(model.status, .live)
    }

    func testSwitchPostsAndRefreshes() async throws {
        let api = StubAPI()
        var s = Fixtures.twoAccounts()
        api.stateResult = .success(s)
        s.activeID = "acct-b"
        api.stateAfterSwitch = s
        let model = makeModel(api)
        try await model.refresh()
        await model.switchTo("acct-b")
        XCTAssertEqual(api.switchedTo, ["acct-b"])
        XCTAssertNil(model.lastError)
        XCTAssertEqual(model.state?.activeID, "acct-b")
    }

    func testSwitchConflictSurfacesDaemonMessage() async throws {
        let api = StubAPI()
        api.stateResult = .success(Fixtures.twoAccounts())
        api.switchResult = .failure(DaemonError.http(409, "switch b: cooldown active"))
        let model = makeModel(api)
        try await model.refresh()
        await model.switchTo("acct-b")
        XCTAssertEqual(model.lastError, "switch b: cooldown active")
        XCTAssertEqual(model.state?.activeID, "acct-a")
    }

    func testPrivacyModeAliasesEmails() async throws {
        let api = StubAPI()
        api.stateResult = .success(Fixtures.twoAccounts())
        let model = makeModel(api)
        try await model.refresh()
        XCTAssertEqual(model.displayName(for: model.accounts[1]), "b@example.dev")
        model.privacyMode = true
        XCTAssertEqual(model.displayName(for: model.accounts[0]), "acct 1/2")
        XCTAssertEqual(model.displayName(for: model.accounts[1]), "acct 2/2")
    }

    func testStaleLabelAppearsPastFiveMinutes() async throws {
        let api = StubAPI()
        let old = Date().addingTimeInterval(-600)
        var s = Fixtures.twoAccounts()
        s.accounts = s.accounts.map {
            var a = $0
            a.snapshot?.asOf = old
            return a
        }
        api.stateResult = .success(s)
        let model = makeModel(api)
        try await model.refresh()
        let label = try XCTUnwrap(model.staleLabel)
        XCTAssertTrue(label.hasPrefix("as of 10 min ago"), label)
        XCTAssertTrue(label.hasSuffix("showing last known, not live"), label)
    }

    func testFreshSnapshotHasNoStaleLabel() async throws {
        let api = StubAPI()
        api.stateResult = .success(Fixtures.twoAccounts())
        let model = makeModel(api)
        try await model.refresh()
        XCTAssertNil(model.staleLabel)
    }

    func testIconGaugeUsesActiveAccountWorstWeekly() async throws {
        let api = StubAPI()
        api.stateResult = .success(Fixtures.twoAccounts())
        let model = makeModel(api)
        try await model.refresh()
        XCTAssertEqual(model.iconGauge.session, 23)
        XCTAssertEqual(model.iconGauge.weekly, 67) // max(weekly_all 41, Fable 67)
    }

    func testEmptyFleetTriggersDetect() async throws {
        let api = StubAPI()
        api.stateResult = .success(
            DaemonState(accounts: [], activeID: nil, schedules: [], asOf: Date()))
        api.detectResult = [
            DetectedDir(configDir: "/Users/x/.claude", email: "a@example.dev",
                        registered: false)
        ]
        let model = makeModel(api)
        try await model.refresh()
        XCTAssertEqual(model.detected.map(\.configDir), ["/Users/x/.claude"])
        await model.adopt("/Users/x/.claude")
        XCTAssertEqual(api.adopted, ["/Users/x/.claude"])
    }

    func testStartDaemonSurfacesLauncherError() async {
        let api = StubAPI()
        api.stateResult = .failure(DaemonError.down)
        let model = makeModel(api)
        model.launch = { "llmpilot CLI not found — install it first, then relaunch" }
        await model.startDaemon()
        XCTAssertEqual(model.lastError,
                       "llmpilot CLI not found — install it first, then relaunch")
    }

    func testStartDaemonTimeoutSetsError() async {
        let api = StubAPI()
        api.stateResult = .failure(DaemonError.down)
        let model = makeModel(api)
        model.launch = { nil }
        model.startupProbeNanos = 1_000_000 // keep the 10-probe loop fast
        await model.startDaemon()
        XCTAssertEqual(model.status, .down)
        let err = model.lastError ?? ""
        XCTAssertTrue(err.contains("never became reachable"), err)
    }

    func testStartDaemonClearsErrorOnceReachable() async {
        let api = StubAPI()
        api.stateResult = .success(Fixtures.twoAccounts())
        let model = makeModel(api)
        model.launch = { nil }
        model.startupProbeNanos = 1_000_000
        await model.startDaemon()
        XCTAssertNil(model.lastError)
        XCTAssertEqual(model.status, .live)
    }

    func testUpsellShowsWhenUnlicensed() async throws {
        let api = StubAPI()
        api.stateResult = .success(Fixtures.twoAccounts()) // no license_status → nil
        let model = makeModel(api)
        try await model.refresh()
        XCTAssertTrue(model.showUpsell)
        XCTAssertFalse(model.licensed)
        XCTAssertNil(model.proLine)
    }

    func testUpsellHiddenWhenLicensed() async throws {
        let api = StubAPI()
        var s = Fixtures.twoAccounts()
        s.license = "trialing"
        api.stateResult = .success(s)
        let model = makeModel(api)
        try await model.refresh()
        XCTAssertFalse(model.showUpsell)
        XCTAssertTrue(model.licensed)
        XCTAssertEqual(model.proLine, "Pro — trial")
    }

    func testReportsTrialMarkerOnceOnFirstRefresh() async throws {
        let api = StubAPI()
        api.stateResult = .success(Fixtures.twoAccounts())
        let marker = StubTrialMarker(present: true)
        let model = FleetViewModel(api: api, trialMarker: marker, autostart: false)
        try await model.refresh()
        try await model.refresh() // one-shot — a second refresh must not re-report
        XCTAssertEqual(api.markerReports, [true])
    }

    func testAutopilotLineWhenDisabled() async throws {
        let api = StubAPI()
        api.stateResult = .success(Fixtures.twoAccounts())
        api.configResult = DaemonConfig(autopilot: .init(disabled: true, thresholdPercent: nil))
        let model = makeModel(api)
        try await model.refresh()
        XCTAssertEqual(model.autopilotLine, "autopilot off")
    }
}

func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T,
                                  file: StaticString = #filePath,
                                  line: UInt = #line) async {
    do {
        _ = try await expression()
        XCTFail("expected error", file: file, line: line)
    } catch {}
}
