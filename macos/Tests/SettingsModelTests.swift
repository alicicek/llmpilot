import XCTest
@testable import llmpilot

@MainActor
final class SettingsModelTests: XCTestCase {
    /// `patch()` spawns a fire-and-forget `Task` for the PUT — poll the
    /// stub's recorded requests instead of sleeping a fixed amount (same
    /// pattern as StashLogicTests' `busy` poll).
    private func waitForPUT(_ api: StubCockpitAPI, count: Int = 1) async {
        for _ in 0..<50 where api.putConfigRequests.count < count {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - copy strings, pinned against SettingsDialog.tsx

    func testCopyStringsMatchTheWebSource() {
        XCTAssertEqual(SettingsCopy.title, "Settings") // SettingsDialog.tsx:86
        XCTAssertEqual(
            SettingsCopy.unreachable,
            "Settings unreachable — daemon not running or too old.") // :68
        XCTAssertEqual(
            SettingsCopy.saveFailed,
            "Save failed — the daemon didn't take the change.") // :75
        XCTAssertEqual(SettingsCopy.showHistory, "Show History") // :102
        XCTAssertEqual(SettingsCopy.showHistoryHint, "The charts section under the board.") // :102
        XCTAssertEqual(SettingsCopy.autoSwitch, "Auto-switch") // :106
        // An explicit threshold = fixed mode, the hint states the user's
        // number; nil = adaptive time-to-wall (owner 2026-08-13).
        XCTAssertEqual(SettingsCopy.autoSwitchHint(90), "Switches to the account with headroom near 90%.") // :107
        XCTAssertEqual(
            SettingsCopy.autoSwitchHint(nil),
            "Switches when an account is ≈8 min from its limit, judged from live burn.")
        XCTAssertEqual(SettingsCopy.usageNotifications, "Usage notifications") // :128
    }

    // MARK: - the native sheet's own copy (no web twin)

    /// One status line row: its hint says what the line does, in the words
    /// of whether it is already there.
    func testStatuslineRowCopy() {
        XCTAssertEqual(SettingsCopy.statusline, "Status line")
        XCTAssertEqual(SettingsCopy.statuslineHint(installed: true), "Your limits show at the bottom of Claude Code.")
        XCTAssertEqual(SettingsCopy.statuslineHint(installed: false), "Show your limits at the bottom of Claude Code.")
        XCTAssertEqual(SettingsCopy.customizeStatusline, "Customize…")
    }

    func testNotificationsHintNamesThePercentages() {
        XCTAssertEqual(SettingsCopy.notificationsHint(SettingsCopy.defaultThresholdsText),
                       "Notifies when a limit passes 75% and 90%.")
        XCTAssertEqual(SettingsCopy.thresholdsList([50, 75, 90]), "50%, 75% and 90%")
        XCTAssertEqual(SettingsCopy.thresholdsList([80]), "80%")
    }

    /// The row's installed state is the doctor's statusline check: only
    /// "ok" (llmpilot's own line) counts; a finding is absent or another
    /// tool's; no report, or not checked, is unknown.
    func testStatuslineInstalledReadsTheDoctorsCheck() throws {
        func report(_ state: String?) throws -> DoctorReport {
            let checks = state.map { #"[{"id":"statusline","title":"Claude Code's statusline","state":"\#($0)"}]"# } ?? "[]"
            let json = #"{"as_of":"2026-11-01T00:00:00Z","clean":true,"problems":0,"findings":[],"checks":\#(checks)}"#
            return try DaemonDates.decoder().decode(DoctorReport.self, from: Data(json.utf8))
        }
        XCTAssertEqual(SettingsSheet.statuslineInstalled(try report("ok")), true)
        XCTAssertEqual(SettingsSheet.statuslineInstalled(try report("finding")), false)
        XCTAssertNil(SettingsSheet.statuslineInstalled(try report("not_checked")))
        XCTAssertNil(SettingsSheet.statuslineInstalled(try report(nil)))
        XCTAssertNil(SettingsSheet.statuslineInstalled(nil))
    }

    // MARK: - the fix's fail case: no PUT before a successful GET

    // The guard's OTHER fail case: a successful load followed by a FAILED
    // reload must disarm patch() again — otherwise a stale config from the
    // previous open gets full-replace-PUT over newer on-disk state.
    func testFailedReloadDisarmsPatch() async {
        let api = StubCockpitAPI()
        api.cockpitConfigResult = .success(CockpitConfig())
        let model = SettingsModel(api: api)
        await model.load()

        api.cockpitConfigResult = .failure(DaemonError.down)
        await model.load()
        model.setAutoSwitch(false)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(api.putConfigRequests.isEmpty,
                      "a failed reload must disarm the full-replace PUT")
    }

    func testNoPUTBeforeLoadGuard() async {
        let api = StubCockpitAPI() // cockpitConfigResult defaults to .failure — never call load()
        let model = SettingsModel(api: api)
        XCTAssertFalse(model.loaded)

        model.setAutoSwitch(true)
        model.setUsageNotifications(true)

        // Give any errant fire-and-forget Task a chance to run.
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(api.putConfigRequests.isEmpty, "must never PUT before a successful GET")
    }

    func testLoadFailureSetsUnreachableCopyAndLeavesUnloaded() async {
        let api = StubCockpitAPI() // default cockpitConfigResult = .failure(DaemonError.down)
        let model = SettingsModel(api: api)
        await model.load()
        XCTAssertEqual(model.err, SettingsCopy.unreachable)
        XCTAssertFalse(model.loaded)
        XCTAssertNil(model.config)
    }

    func testLoadSuccessClearsAnyPriorError() async {
        let api = StubCockpitAPI()
        api.cockpitConfigResult = .success(CockpitConfig(autopilot: nil, notifications: nil, planCostMonthly: nil))
        let model = SettingsModel(api: api)
        model.err = "stale banner"
        await model.load()
        XCTAssertNil(model.err)
        XCTAssertTrue(model.loaded)
    }

    // MARK: - full-object round-trip preservation

    func testFullObjectRoundTripPreservesUntouchedFields() async {
        let api = StubCockpitAPI()
        let initial = CockpitConfig(
            autopilot: CockpitAutopilotConfig(disabled: false, thresholdPercent: 85, cooldownMinutes: 30, runwayMinutes: 12),
            notifications: CockpitNotificationsConfig(disabled: false, thresholds: [60, 80]),
            planCostMonthly: ["acc1": 200]
        )
        api.cockpitConfigResult = .success(initial)
        api.putConfigResult = .success(initial)
        let model = SettingsModel(api: api)
        await model.load()

        // Touch exactly ONE field.
        model.setUsageNotifications(false)
        await waitForPUT(api)

        let put = try? XCTUnwrap(api.putConfigRequests.first)
        XCTAssertEqual(put?.autopilot?.thresholdPercent, 85, "no UI for this field — must round-trip unmodified")
        XCTAssertEqual(put?.autopilot?.cooldownMinutes, 30, "no UI for this field — must round-trip unmodified")
        XCTAssertEqual(
            put?.autopilot?.runwayMinutes, 12,
            "adaptive's floor override has no UI — a Settings toggle wiping it would silently change switching behavior")
        XCTAssertEqual(put?.autopilot?.disabled, false, "untouched control must be preserved")
        XCTAssertEqual(put?.notifications?.thresholds, [60, 80], "no UI for this field — must round-trip unmodified")
        XCTAssertEqual(put?.notifications?.disabled, true, "the ONE field we actually toggled")
        XCTAssertEqual(put?.planCostMonthly, ["acc1": 200], "untouched map must be preserved")
    }

    // MARK: - autopilot / notifications inversion mapping

    func testSetAutoSwitchOnClearsDisabledFlag() async {
        let api = StubCockpitAPI()
        let initial = CockpitConfig(
            autopilot: CockpitAutopilotConfig(disabled: true, thresholdPercent: nil, cooldownMinutes: nil),
            notifications: nil, planCostMonthly: nil
        )
        api.cockpitConfigResult = .success(initial)
        api.putConfigResult = .success(initial)
        let model = SettingsModel(api: api)
        await model.load()
        XCTAssertFalse(model.autoOn, "disabled: true reads as the switch being off")

        model.setAutoSwitch(true)
        await waitForPUT(api)
        XCTAssertEqual(api.putConfigRequests.first?.autopilot?.disabled, false, "turning the switch ON must clear `disabled`")
    }

    func testSetUsageNotificationsOffSetsDisabledFlag() async {
        let api = StubCockpitAPI()
        let initial = CockpitConfig(
            autopilot: nil,
            notifications: CockpitNotificationsConfig(disabled: false, thresholds: nil),
            planCostMonthly: nil
        )
        api.cockpitConfigResult = .success(initial)
        api.putConfigResult = .success(initial)
        let model = SettingsModel(api: api)
        await model.load()
        XCTAssertTrue(model.notifOn, "disabled: false reads as the switch being on")

        model.setUsageNotifications(false)
        await waitForPUT(api)
        XCTAssertEqual(api.putConfigRequests.first?.notifications?.disabled, true, "turning the switch OFF must set `disabled`")
    }

    func testMissingAutopilotBlockDefaultsToOnWithNoDisabledFlag() async {
        // No `autopilot` key on the wire at all (an absent block, not an
        // explicit disabled:false) must still read as "on".
        let api = StubCockpitAPI()
        api.cockpitConfigResult = .success(CockpitConfig(autopilot: nil, notifications: nil, planCostMonthly: nil))
        let model = SettingsModel(api: api)
        await model.load()
        XCTAssertTrue(model.autoOn)
        XCTAssertTrue(model.notifOn)
        // Absent threshold = adaptive time-to-wall (owner 2026-08-13) —
        // reading a fabricated 90 here would make the hint claim a fixed
        // mode the autopilot is not running.
        XCTAssertNil(model.thresholdPercent)
        XCTAssertEqual(model.thresholdsText, SettingsCopy.defaultThresholdsText)
    }

    // MARK: - save failure keeps local state + sets the error

    func testSaveFailureKeepsLocalStateAndSetsError() async {
        let api = StubCockpitAPI()
        let initial = CockpitConfig(
            autopilot: CockpitAutopilotConfig(disabled: false, thresholdPercent: nil, cooldownMinutes: nil),
            notifications: nil, planCostMonthly: nil
        )
        api.cockpitConfigResult = .success(initial)
        api.putConfigResult = .failure(DaemonError.down)
        let model = SettingsModel(api: api)
        await model.load()

        model.setAutoSwitch(false)
        for _ in 0..<50 where model.err == nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(model.err, SettingsCopy.saveFailed)
        XCTAssertEqual(model.config?.autopilot?.disabled, true, "the local mutation must survive a failed PUT so retry works")
        XCTAssertFalse(model.autoOn, "the toggle reads the preserved local state, not a reverted one")
    }
}
