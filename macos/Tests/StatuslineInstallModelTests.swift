import XCTest
@testable import llmpilot

/// U5 (audit 2026-10-02): the "Install statusline" button's state machine
/// — a foreign line is a question, never a default. Fails against a model
/// that sends a mode on the first press.
@MainActor
final class StatuslineInstallModelTests: XCTestCase {
    // MARK: - U5 the install button never writes over a foreign line unasked

    func testStatuslineInstallAsksBeforeTouchingAForeignLine() async {
        let api = StubCockpitAPI()
        api.installStatuslineScript = [.success(.foreign), .success(.foreign), .success(.kept)]
        var installed = 0
        let model = StatuslineInstallModel(api: api) { installed += 1 }

        model.install()
        await settle(model, until: { $0 == .needsConsent })
        XCTAssertEqual(api.installStatuslineModes, [nil], "the first press is a probe — no mode")
        XCTAssertEqual(installed, 0, "nothing was written, so nothing reloads")

        // Replace/keep are refused outside the consent state.
        model.cancel()
        XCTAssertEqual(model.phase, .idle)
        model.replace()
        XCTAssertEqual(api.installStatuslineModes.count, 1, "replace() from idle must not send")

        model.install()
        await settle(model, until: { $0 == .needsConsent })
        model.keep()
        await settle(model, until: { if case .done = $0 { return true } else { return false } })
        XCTAssertEqual(api.installStatuslineModes, [nil, nil, .keep])
        XCTAssertEqual(model.phase, .done(.kept))
        XCTAssertEqual(installed, 1)
    }

    func testStatuslineInstallPlainPathAndFailure() async {
        let api = StubCockpitAPI()
        api.installStatuslineResult = .success(.installed)
        let model = StatuslineInstallModel(api: api)
        model.install()
        await settle(model, until: { $0 == .done(.installed) })
        XCTAssertEqual(StatuslineInstallCopy.result(.installed), "Installed — Claude Code shows the line on its next prompt.")
        // Review 2026-10-03 P1: the person this button exists for has no
        // `llmpilot` on PATH — the copy names the backup, never a command.
        for text in [StatuslineInstallCopy.consent, StatuslineInstallCopy.result(.replaced), StatuslineInstallCopy.result(.kept)] {
            XCTAssertFalse(text.contains("llmpilot statusline"), "copy routes undo through a terminal: \(text)")
        }
        XCTAssertTrue(StatuslineInstallCopy.result(.replaced).contains("statusline-replaced.json"))
        // reset(): only a finished install goes back to the button.
        model.reset()
        XCTAssertEqual(model.phase, .idle)

        let down = StubCockpitAPI()
        let failing = StatuslineInstallModel(api: down)
        failing.install()
        await settle(failing, until: { if case .failed = $0 { return true } else { return false } })
    }

    // MARK: - helpers

    private func settle(_ model: StatuslineInstallModel, until done: (StatuslineInstallModel.Phase) -> Bool) async {
        for _ in 0..<200 where !done(model.phase) {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(done(model.phase), "phase settled at \(model.phase)")
    }
}
