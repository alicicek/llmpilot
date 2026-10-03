import XCTest
@testable import llmpilot

/// U8 (audit 2026-10-02): one wording for watched lanes on every surface,
/// and no surface routes sign-in through the terminal.
final class FleetCopyTests: XCTestCase {
    // MARK: - U8 one wording for watched lanes; no surface sends anyone to the terminal

    func testPopoverCopyPointsAtAddAccountAndMatchesTheCockpit() {
        let lower = FleetCopy.noAccountsHint.lowercased()
        XCTAssertTrue(lower.contains("add account"), "the zero-account hint names the button beneath it")
        for terminal in ["`claude`", "log in with", "terminal", "reopen this menu"] {
            XCTAssertFalse(lower.contains(terminal), "the popover must not route sign-in through the terminal: \(terminal)")
        }
        XCTAssertTrue(FleetCopy.watchedLane.hasPrefix("Watched — "), "one word for the lane state, on every surface")
        XCTAssertFalse(FleetCopy.watchedLane.lowercased().contains("config dir"), "internal vocabulary stays internal")
    }
}
