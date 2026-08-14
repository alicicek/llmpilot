import XCTest

/// Boot smoke against the sandboxed demo daemon. scripts/e2e-native.sh owns
/// the sandbox (fake $HOME, fixed $LLMPILOT_HOME, LLMPILOT_TEST interlock,
/// throwaway defaults suite) and invokes this via E2E_XCUI=1 with the
/// TEST_RUNNER_ env passthrough.
///
/// The guard is a refusal, not a convenience: XCUITest launches the REAL app,
/// and outside the sandbox that app would run ensureRunning() against the
/// developer's real machine — launchd enrollment included. Skipping is the
/// only safe default.
final class SmokeUITests: XCTestCase {
    func testCockpitWindowAppearsAgainstSandboxDaemon() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["LLMPILOT_TEST"] == "1",
              let home = env["LLMPILOT_HOME"], !home.isEmpty
        else {
            throw XCTSkip("sandbox-only: run via scripts/e2e-native.sh with E2E_XCUI=1")
        }

        let app = XCUIApplication()
        // The runner's env carries the sandbox (TEST_RUNNER_ passthrough);
        // the app under test inherits none of it unless forwarded here.
        for key in [
            "LLMPILOT_TEST", "LLMPILOT_HOME", "HOME", "CLAUDE_CONFIG_DIR",
            "LLMPILOT_DISABLE_SMAPPSERVICE", "LLMPILOT_DEFAULTS_SUITE",
            "LLMPILOT_USAGE_URL", "LLMPILOT_KEYCHAIN", "LLMPILOT_NO_LAUNCHD",
        ] {
            if let v = env[key] { app.launchEnvironment[key] = v }
        }
        app.launch()

        // Fresh defaults suite → the app auto-opens the cockpit window once
        // (FleetViewModel.maybeAutoOpenWindow). Match it by TITLE
        // (CockpitWindow sets win.title = "llmpilot") — firstMatch would
        // also accept an error alert or a stray panel and report a false
        // pass.
        let window = app.windows["llmpilot"]
        XCTAssertTrue(
            window.waitForExistence(timeout: 30),
            "cockpit window (title 'llmpilot') never appeared against the sandbox demo daemon")
    }
}
