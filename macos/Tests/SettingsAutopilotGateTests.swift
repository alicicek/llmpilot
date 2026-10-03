import XCTest
@testable import llmpilot

/// U7 (audit 2026-10-02): the Auto-switch row shows a live toggle only
/// while the daemon says the autopilot is running.
@MainActor
final class SettingsAutopilotGateTests: XCTestCase {
    // MARK: - U7 Auto-switch never looks ON while the autopilot is not running

    func testAutoSwitchRowNeedsTheAutopilot() {
        XCTAssertFalse(SettingsSheet.autopilotRunning(license: nil), "no licence info = not running")
        XCTAssertFalse(SettingsSheet.autopilotRunning(license: license(status: "none", active: false)))
        XCTAssertFalse(SettingsSheet.autopilotRunning(license: license(status: "lapsed", active: false)))
        XCTAssertTrue(SettingsSheet.autopilotRunning(license: license(status: "trialing", active: true)))
        XCTAssertTrue(SettingsSheet.autopilotRunning(license: license(status: "lifetime", active: true)))
        XCTAssertEqual(SettingsCopy.autoSwitchNeedsAutopilot, "Needs the autopilot — nothing switches until it is on.")
    }

    /// The OFFER only where it can be honoured: a source build (available
    /// false) answers 501 to quote and checkout, and a nil licence has no
    /// paywall to open — neither gets a "Turn on the autopilot" button.
    func testAutoSwitchOfferOnlyWhereTheLicenceSurfaceExists() {
        XCTAssertFalse(SettingsSheet.autopilotOfferable(license: nil))
        XCTAssertFalse(SettingsSheet.autopilotOfferable(license: license(status: "unavailable", active: false, available: false)))
        XCTAssertTrue(SettingsSheet.autopilotOfferable(license: license(status: "none", active: false)))
        XCTAssertTrue(SettingsSheet.autopilotOfferable(license: license(status: "lapsed", active: false)))
        XCTAssertFalse(SettingsSheet.autopilotOfferable(license: license(status: "trialing", active: true)), "running: the toggle, not the offer")
    }

    // MARK: - helpers

    private func license(status: String, active: Bool, available: Bool = true) -> LicenseInfo {
        try! DaemonDates.decoder().decode(
            LicenseInfo.self,
            from: Data(#"{"available":\#(available),"active":\#(active),"status":"\#(status)","nocard_trial_used":false}"#.utf8))
    }
}
