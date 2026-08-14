import XCTest
@testable import llmpilot

/// The ensure-running state machine, first-launch auto-open, and the
/// login-item toggle — all against injected seams; the real SMAppService,
/// launchd, and window controller are never touched here.
@MainActor
final class EnsureRunningTests: XCTestCase {
    private static let suite = "EnsureRunningTests"
    private var defaults: UserDefaults!
    private var opened: [URL] = []

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: Self.suite)
        defaults.removePersistentDomain(forName: Self.suite)
        opened = []
    }

    private func makeModel(
        _ api: StubAPI,
        items: FakeLoginItems = FakeLoginItems(),
        legacy: Bool = false,
        installed: Bool = true
    ) -> (FleetViewModel, FakeLoginItems) {
        let model = FleetViewModel(api: api, autostart: false)
        model.loginItems = items
        model.legacyPlistPresent = { legacy }
        model.bundleLocationBlocked = { false }
        // The test runner's own bundle is never in /Applications; the
        // stale-enrollment repair is gated on an installed copy, so state
        // it explicitly per test rather than inheriting the runner's path.
        model.bundleIsInstalled = { installed }
        model.launch = { "unexpected legacy launch" }
        model.defaults = defaults
        model.openWindow = { [weak self] url in self?.opened.append(url) }
        model.startupProbeNanos = 1_000_000 // keep probe loops fast
        return (model, items)
    }

    // MARK: - State machine

    func testReachableDaemonMeansNoRegisterAndNoLaunch() async {
        let api = StubAPI()
        api.stateResult = .success(Fixtures.twoAccounts())
        let (model, items) = makeModel(api)
        await model.ensureRunning()
        XCTAssertEqual(model.status, .live)
        XCTAssertEqual(items.registerCalls, 0)
        XCTAssertNil(model.startGate)
    }

    func testLegacyPlistTakesLegacyPathNeverSMAppService() async {
        let api = StubAPI()
        api.stateResult = .failure(DaemonError.down)
        let (model, items) = makeModel(api, legacy: true)
        model.launch = {
            api.stateResult = .success(Fixtures.twoAccounts())
            return nil
        }
        await model.ensureRunning()
        XCTAssertEqual(model.status, .live)
        XCTAssertEqual(items.registerCalls, 0, "register() on top of a legacy agent silently loses to it — must never be called")
    }

    func testRegistersAgentWhenNoLegacyPlist() async {
        let api = StubAPI()
        api.stateResult = .failure(DaemonError.down)
        let items = FakeLoginItems()
        items.onRegister = { api.stateResult = .success(Fixtures.twoAccounts()) }
        let (model, _) = makeModel(api, items: items)
        await model.ensureRunning()
        XCTAssertEqual(model.status, .live)
        XCTAssertEqual(items.registerCalls, 1)
        XCTAssertNil(model.lastError)
    }

    /// Hit live 2026-08-08: launchd held "spawn scheduled" forever against a
    /// rebuilt (DerivedData) bundle — the agent reports .enabled, register()
    /// is a no-op, and the socket never comes up. The repair is a one-shot
    /// unregister + register from THIS bundle, and only then giving up.
    func testStaleEnabledEnrollmentIsReenrolledOnce() async {
        let api = StubAPI()
        api.stateResult = .failure(DaemonError.down)
        let items = FakeLoginItems()
        items.agentStatusValue = .enabled // enrolled, but nothing spawns
        items.registerShouldThrow = true // register() over a live enrollment refuses
        items.onUnregister = {
            // Re-enrollment is what brings the daemon up: allow the register
            // that FOLLOWS the unregister to land and flip the API live.
            items.registerShouldThrow = false
            items.onRegister = { api.stateResult = .success(Fixtures.twoAccounts()) }
        }
        let (model, _) = makeModel(api, items: items)
        await model.ensureRunning()
        XCTAssertEqual(model.status, .live)
        XCTAssertEqual(items.unregisterCalls, 1)
        XCTAssertNil(model.lastError)
    }

    func testStaleEnrollmentRepairFailingStillEndsDownWithTheDetail() async {
        let api = StubAPI()
        api.stateResult = .failure(DaemonError.down) // never comes up
        let items = FakeLoginItems()
        items.agentStatusValue = .enabled
        items.registerShouldThrow = true
        let (model, _) = makeModel(api, items: items)
        await model.ensureRunning()
        XCTAssertEqual(model.status, .down)
        XCTAssertEqual(items.unregisterCalls, 1, "the repair is one-shot — no unregister loop")
        XCTAssertEqual(model.lastError, FleetViewModel.daemonUnreachableError)
    }

    /// The guard's fail case: re-enrolling rewrites the user's LaunchAgent to
    /// THIS bundle's path, so an un-installed copy (a DerivedData build,
    /// which launchd refuses to spawn at all) must fail loudly rather than
    /// take a working /Applications enrollment down with it.
    func testStaleEnrollmentIsNotRepairedFromAnUninstalledBundle() async {
        let api = StubAPI()
        api.stateResult = .failure(DaemonError.down)
        let items = FakeLoginItems()
        items.agentStatusValue = .enabled
        let (model, _) = makeModel(api, items: items, installed: false)
        await model.ensureRunning()
        XCTAssertEqual(model.status, .down)
        XCTAssertEqual(
            items.unregisterCalls, 0,
            "an un-installed bundle must never rewrite the real agent's enrollment")
        XCTAssertEqual(model.lastError, FleetViewModel.daemonUnreachableError)
    }

    func testRequiresApprovalGetsGateAndNoRegisterLoop() async {
        let api = StubAPI()
        api.stateResult = .failure(DaemonError.down)
        let items = FakeLoginItems()
        items.registerShouldThrow = true
        items.agentStatusValue = .requiresApproval
        let (model, _) = makeModel(api, items: items)
        await model.ensureRunning()
        XCTAssertEqual(model.startGate, .requiresApproval)
        XCTAssertEqual(model.status, .down)
        XCTAssertEqual(items.registerCalls, 1, "requiresApproval must never loop-register")
    }

    func testApprovalParkWithoutThrowAlsoGates() async {
        let api = StubAPI()
        api.stateResult = .failure(DaemonError.down)
        let items = FakeLoginItems()
        items.agentStatusValue = .requiresApproval // register() succeeds but parks
        let (model, _) = makeModel(api, items: items)
        await model.ensureRunning()
        XCTAssertEqual(model.startGate, .requiresApproval)
        XCTAssertEqual(items.registerCalls, 1)
    }

    func testRegisterRefusalFallsBackToLegacyPath() async {
        let api = StubAPI()
        api.stateResult = .failure(DaemonError.down)
        let items = FakeLoginItems()
        items.registerShouldThrow = true
        items.agentStatusValue = .notFound // BTM rejected this build
        let (model, _) = makeModel(api, items: items)
        var launched = false
        model.launch = {
            launched = true
            api.stateResult = .success(Fixtures.twoAccounts())
            return nil
        }
        await model.ensureRunning()
        XCTAssertTrue(launched)
        XCTAssertEqual(model.status, .live)
        XCTAssertNil(model.startGate)
    }

    func testTranslocatedBundleShowsMoveGateAndStartsNothing() async {
        let api = StubAPI()
        api.stateResult = .failure(DaemonError.down)
        let (model, items) = makeModel(api)
        model.bundleLocationBlocked = { true }
        var launched = false
        model.launch = { launched = true; return nil }
        await model.ensureRunning()
        XCTAssertEqual(model.startGate, .moveToApplications)
        XCTAssertEqual(model.status, .down)
        XCTAssertFalse(launched)
        XCTAssertEqual(items.registerCalls, 0)
    }

    func testStartingStateHoldsWhileProbing() async {
        let api = StubAPI()
        api.stateResult = .failure(DaemonError.down)
        let items = FakeLoginItems()
        let (model, _) = makeModel(api, items: items)
        model.startupProbeNanos = 50_000_000
        let run = Task { await model.ensureRunning() }
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(model.status, .starting, "probe failures must ride under .starting, not flash down")
        await run.value
        XCTAssertEqual(model.status, .down)
        XCTAssertEqual(model.lastError, FleetViewModel.daemonUnreachableError)
    }

    // MARK: - First-launch auto-open

    func testFirstSuccessfulStateAutoOpensWindowExactlyOnce() async throws {
        let api = StubAPI()
        api.stateResult = .success(Fixtures.twoAccounts())
        let (model, _) = makeModel(api)
        // The flag now burns only on a CONFIRMED-visible window (cooperative
        // activation can surface it behind a fullscreen Space, unseen).
        model.windowVisible = { true }
        model.scheduleVisibilityCheck = { _, work in work() }
        try await model.refresh()
        try await model.refresh()
        XCTAssertEqual(opened.count, 1)
        XCTAssertTrue(defaults.bool(forKey: FleetViewModel.firstLaunchKey))

        // Relaunch: a second model over the same defaults must not open again.
        let (model2, _) = makeModel(api)
        model2.scheduleVisibilityCheck = { _, work in work() }
        try await model2.refresh()
        XCTAssertEqual(opened.count, 1)
        _ = model
    }

    func testFailedStartNeverBurnsTheAutoOpen() async {
        let api = StubAPI()
        api.stateResult = .failure(DaemonError.down)
        let (model, _) = makeModel(api, legacy: true)
        model.launch = { nil } // "succeeds" but the daemon never comes up
        await model.ensureRunning()
        XCTAssertEqual(opened.count, 0)
        XCTAssertFalse(defaults.bool(forKey: FleetViewModel.firstLaunchKey),
                       "a failed start must not burn the one auto-open")
    }

    // MARK: - Login item toggle

    func testStartAtLoginToggleRegistersAndUnregisters() async {
        let api = StubAPI()
        let (model, items) = makeModel(api)
        await model.setStartAtLogin(true)
        XCTAssertEqual(items.mainSets, [true])
        XCTAssertTrue(model.startAtLogin)
        await model.setStartAtLogin(false)
        XCTAssertEqual(items.mainSets, [true, false])
        XCTAssertFalse(model.startAtLogin)
    }

    // MARK: - First-run login-item default

    func testFirstRunDefaultsStartAtLoginOnExactlyOnce() async {
        let api = StubAPI()
        let (model, items) = makeModel(api)
        await model.defaultStartAtLoginOnce()
        XCTAssertEqual(items.mainSets, [true])
        XCTAssertTrue(model.startAtLogin)
        XCTAssertTrue(defaults.bool(forKey: FleetViewModel.startAtLoginDefaultedKey))

        // Relaunch over the same defaults: the one-shot never re-registers —
        // the gear toggle (and System Settings revocations) own it from here.
        let (model2, items2) = makeModel(api)
        await model2.defaultStartAtLoginOnce()
        XCTAssertEqual(items2.mainSets, [])
        _ = model
    }

    func testTranslocatedFirstRunDefersTheLoginItemDefault() async {
        let api = StubAPI()
        let (model, items) = makeModel(api)
        model.bundleLocationBlocked = { true }
        await model.defaultStartAtLoginOnce()
        XCTAssertEqual(items.mainSets, [], "registering from a DMG/translocated path would pin a doomed path")
        XCTAssertFalse(defaults.bool(forKey: FleetViewModel.startAtLoginDefaultedKey),
                       "a deferred default must not burn the one-shot")

        // Next launch from Applications: the default applies.
        model.bundleLocationBlocked = { false }
        await model.defaultStartAtLoginOnce()
        XCTAssertEqual(items.mainSets, [true])
    }

    func testFailedLoginItemDefaultDoesNotBurnTheOneShot() async {
        let api = StubAPI()
        let items = FakeLoginItems()
        items.setMainShouldThrow = true
        let (model, _) = makeModel(api, items: items)
        await model.defaultStartAtLoginOnce()
        XCTAssertFalse(defaults.bool(forKey: FleetViewModel.startAtLoginDefaultedKey),
                       "a refused registration must retry next launch, not lose the default forever")

        // Next launch, BTM cooperates: the default lands and the key burns.
        items.setMainShouldThrow = false
        await model.defaultStartAtLoginOnce()
        XCTAssertEqual(items.mainSets, [true, true])
        XCTAssertTrue(defaults.bool(forKey: FleetViewModel.startAtLoginDefaultedKey))
    }
}
