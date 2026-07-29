import XCTest
@testable import llmpilot

@MainActor
final class FleetViewModelTests: XCTestCase {
    private var testDefaults: UserDefaults!

    private func makeModel(_ api: StubAPI) -> FleetViewModel {
        let model = FleetViewModel(api: api, autostart: false)
        // Keep the first-launch flag and window opener out of the real
        // environment — these tests exercise other behavior.
        model.defaults = testDefaults
        model.openWindow = { _ in }
        model.loginItems = FakeLoginItems()
        return model
    }

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "privacyMode")
        UserDefaults.standard.removeObject(forKey: "iconMode")
        testDefaults = UserDefaults(suiteName: "FleetViewModelTests")
        testDefaults.removePersistentDomain(forName: "FleetViewModelTests")
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
        XCTAssertEqual(model.autopilotLine, "autopilot on · switches at 85%")
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

    /// The bug this closes: once the first account was adopted, every OTHER
    /// Claude sign-in on the Mac went invisible forever because detect only
    /// ran while the fleet was empty and got cleared once it wasn't. Detect
    /// must keep running, and `detected` must survive a non-empty fleet.
    func testDetectSurvivesNonEmptyFleet() async throws {
        let api = StubAPI()
        api.stateResult = .success(Fixtures.twoAccounts())
        api.detectResult = [
            DetectedDir(configDir: "/Users/x/.claude-other", email: "c@example.dev",
                        registered: false)
        ]
        let model = makeModel(api)
        try await model.refresh()
        XCTAssertFalse(model.accounts.isEmpty)
        XCTAssertEqual(model.detected.map(\.configDir), ["/Users/x/.claude-other"])
        XCTAssertEqual(model.unadoptedDetectedCount, 1)

        // A second refresh with the same non-empty fleet must not clear it.
        try await model.refresh()
        XCTAssertEqual(model.detected.map(\.configDir), ["/Users/x/.claude-other"])
    }

    func testUnadoptedDetectedCountExcludesAlreadyRegistered() async throws {
        let api = StubAPI()
        api.stateResult = .success(Fixtures.twoAccounts())
        api.detectResult = [
            DetectedDir(configDir: "/Users/x/.claude-a", email: "a@example.dev", registered: true),
            DetectedDir(configDir: "/Users/x/.claude-b", email: "b@example.dev", registered: false),
        ]
        let model = makeModel(api)
        try await model.refresh()
        XCTAssertEqual(model.unadoptedDetectedCount, 1)
    }

    func testEnsureRunningSurfacesLauncherError() async {
        let api = StubAPI()
        api.stateResult = .failure(DaemonError.down)
        let model = makeModel(api)
        model.legacyPlistPresent = { true }
        model.bundleLocationBlocked = { false }
        model.launch = { "llmpilot CLI not found — install it first, then relaunch" }
        await model.ensureRunning()
        XCTAssertEqual(model.lastError,
                       "llmpilot CLI not found — install it first, then relaunch")
    }

    func testEnsureRunningTimeoutSetsError() async {
        let api = StubAPI()
        api.stateResult = .failure(DaemonError.down)
        let model = makeModel(api)
        model.legacyPlistPresent = { true }
        model.bundleLocationBlocked = { false }
        model.launch = { nil }
        model.startupProbeNanos = 1_000_000 // keep the probe loop fast
        await model.ensureRunning()
        XCTAssertEqual(model.status, .down)
        let err = model.lastError ?? ""
        XCTAssertTrue(err.contains("never became reachable"), err)
    }

    func testEnsureRunningClearsErrorOnceReachable() async {
        let api = StubAPI()
        api.stateResult = .success(Fixtures.twoAccounts())
        let model = makeModel(api)
        model.legacyPlistPresent = { true }
        model.bundleLocationBlocked = { false }
        model.launch = { nil }
        model.startupProbeNanos = 1_000_000
        await model.ensureRunning()
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
        model.defaults = testDefaults
        model.openWindow = { _ in }
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

    // Sparkle replaces the bundle in place but leaves the daemon's separate
    // launchd job running the PREVIOUS binary out of the bundle the updater
    // moved aside. Two shipped attempts at this check could not fire: 1.2.1
    // compared the version the daemon reports (a stale daemon predates that
    // field), and 1.2.2 required a readable executable path (the updater has
    // already deleted the file by then). Both were proven live on a real
    // machine, never by a test — because every test here handed the check the
    // fact it should have been reading.
    private func staleModel(_ exe: DaemonLauncher.DaemonExecutable) -> FleetViewModel {
        let api = StubAPI()
        api.stateResult = .success(Fixtures.twoAccounts())
        let model = makeModel(api)
        model.bundlePath = "/Applications/llmpilot.app"
        model.daemonExecutable = { exe }
        return model
    }

    func testDaemonLeftBehindByAnUpdateIsBounced() async throws {
        let model = staleModel(
            .path("/Users/x/Library/Caches/dev.llmpilot.menubar/org.sparkle-project.Sparkle/Installation/AA/BB/llmpilot.app/Contents/Resources/llmpilot"))
        let restarts = Counter()
        model.restartAgent = { () -> String? in restarts.bump(); return nil }
        try await model.refresh()
        await model.restartStaleDaemon()
        XCTAssertEqual(restarts.value, 1, "a daemon running from the updater's staging area must be bounced")
        await model.restartStaleDaemon()
        XCTAssertEqual(restarts.value, 1, "one bounce per launch — retrying would loop")
    }

    func testDaemonFromOurOwnBundleIsLeftAlone() async throws {
        let model = staleModel(.path("/Applications/llmpilot.app/Contents/Resources/llmpilot"))
        let restarts = Counter()
        model.restartAgent = { () -> String? in restarts.bump(); return nil }
        try await model.refresh()
        await model.restartStaleDaemon()
        XCTAssertEqual(restarts.value, 0, "the daemon from this bundle is not stale")
    }

    // A from-source or Homebrew install legitimately runs the daemon from
    // PATH. Bouncing it would be an endless restart loop.
    func testHomebrewDaemonIsNeverBounced() async throws {
        let model = staleModel(.path("/opt/homebrew/bin/llmpilot"))
        let restarts = Counter()
        model.restartAgent = { () -> String? in restarts.bump(); return nil }
        try await model.refresh()
        await model.restartStaleDaemon()
        XCTAssertEqual(restarts.value, 0, "a PATH install must never be bounced")
    }

    func testNoDaemonJobIsLeftAlone() async throws {
        let model = staleModel(.noJob)
        let restarts = Counter()
        model.restartAgent = { () -> String? in restarts.bump(); return nil }
        try await model.refresh()
        await model.restartStaleDaemon()
        XCTAssertEqual(restarts.value, 0, "no job means nothing to bounce")
    }

    // THE case both shipped versions missed. An in-place update deletes the
    // bundle it moved aside, so the stale daemon is left executing a file that
    // no longer exists and there is no path to compare against ours.
    func testDaemonWhoseExecutableWasDeletedIsBounced() async throws {
        let model = staleModel(.executableGone)
        let restarts = Counter()
        model.restartAgent = { () -> String? in restarts.bump(); return nil }
        try await model.refresh()
        await model.restartStaleDaemon()
        XCTAssertEqual(restarts.value, 1,
                       "a daemon whose executable was deleted under it is what an update leaves behind")
        await model.restartStaleDaemon()
        XCTAssertEqual(restarts.value, 1, "one bounce per launch — retrying would loop")
    }

    func testParsesThePIDLaunchctlPrints() {
        let out = "\tstate = running\n\tpid = 64372\n\tprogram identifier = x\n"
        XCTAssertEqual(DaemonLauncher.parsePID(out), 64372)
        XCTAssertNil(DaemonLauncher.parsePID("no pid here"))
    }

    /// The reader itself, against a REAL process — the missing coverage that
    /// let two versions of this check ship unable to fire. The tests above can
    /// only prove the classifier; this proves what the classifier is fed.
    ///
    /// Builds its own fixture because a copy of an Apple platform binary will
    /// not execute (the copy is not a platform binary, so it dies on launch
    /// and the probe would report `executableGone` for the wrong reason).
    func testProbeReadsARealPathThenReportsItGoneOnceDeleted() throws {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("llmpilot-probe-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let source = dir.appendingPathComponent("sleeper.c")
        try "#include <unistd.h>\nint main(void){sleep(120);return 0;}\n"
            .write(to: source, atomically: true, encoding: .utf8)
        let binary = dir.appendingPathComponent("sleeper")

        let clang = Process()
        clang.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        clang.arguments = ["-o", binary.path, source.path]
        clang.standardError = Pipe()
        clang.standardOutput = Pipe()
        do { try clang.run() } catch { throw XCTSkip("clang is unavailable: \(error)") }
        clang.waitUntilExit()
        guard clang.terminationStatus == 0 else {
            throw XCTSkip("clang could not build the probe fixture")
        }

        let victim = Process()
        victim.executableURL = binary
        try victim.run()
        defer { victim.terminate() }

        // Non-vacuity: the probe must genuinely READ a path before this test
        // is entitled to assert anything about losing one.
        //
        // Compared through realpath(3), not URL.resolvingSymlinksInPath() —
        // that one STRIPS a /private prefix, while proc_pidpath returns the
        // fully resolved path, so the two disagree on every temp directory.
        func resolved(_ path: String) -> String {
            guard let r = realpath(path, nil) else { return path }
            defer { free(r) }
            return String(cString: r)
        }
        guard case .path(let live) = DaemonLauncher.executable(ofPID: victim.processIdentifier) else {
            return XCTFail("the probe must report a live process's real executable")
        }
        XCTAssertEqual(live, resolved(binary.path),
                       "the probe must report the executable this process is actually running")

        try fm.removeItem(at: binary)
        XCTAssertTrue(victim.isRunning,
                      "the process must still be running — a live daemon with a deleted binary IS the state under test")
        XCTAssertEqual(DaemonLauncher.executable(ofPID: victim.processIdentifier),
                       .executableGone,
                       "a running process whose executable was deleted has no path left to compare")
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

/// Sendable counter for the @Sendable restart seam.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
