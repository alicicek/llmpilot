import XCTest
@testable import llmpilot

/// Phase 2 chunk A coverage: the SWITCH verb's button-visibility rule
/// (LaneHeader.tsx:68) and the toolbar's error-flash dismiss state
/// (App.tsx:206-212, 429-439).
@MainActor
final class SwitchToolbarTests: XCTestCase {
    // MARK: - switch button visibility (LaneHeader.tsx:68)

    func testSwitchButtonVisibilityTable() {
        struct Vector { let active: Bool; let pinned: Bool; let expected: Bool }
        let vectors: [Vector] = [
            // Neither active nor pinned — the common case, button shows.
            Vector(active: false, pinned: false, expected: true),
            // Active lane never gets a switch verb — it's already there.
            Vector(active: true, pinned: false, expected: false),
            // Pinned (watched) lane shows the pin icon, never a switch
            // affordance — the daemon's 409-pinned copy must stay
            // unreachable from the native UI too.
            Vector(active: false, pinned: true, expected: false),
            // Active AND pinned (degenerate, but the guard is an AND of
            // two independent negations — must still refuse).
            Vector(active: true, pinned: true, expected: false),
        ]
        for v in vectors {
            XCTAssertEqual(
                switchButtonVisible(active: v.active, pinned: v.pinned), v.expected,
                "active=\(v.active) pinned=\(v.pinned)")
        }
    }

    // MARK: - flash dismissal clears the source (App.tsx:206-212, 429-439)

    // The banner renders whenever FleetViewModel.lastError is non-nil and
    // dismissal sets it to nil (the setFlash(null) twin) — so a REPEATED
    // identical error (same 409 on a retried switch) re-surfaces because
    // switchTo writes lastError fresh. A local "last dismissed text" memory
    // would swallow it forever; this pins the source-clearing design.
    func testFlashDismissClearsSourceSoRepeatsResurface() async {
        let api = StubAPI()
        api.stateResult = .success(Fixtures.twoAccounts())
        api.switchResult = .failure(DaemonError.http(409, "cooldown active"))
        let model = FleetViewModel(api: api, autostart: false)
        model.defaults = UserDefaults(suiteName: "SwitchToolbarTests")!
        model.openWindow = { _ in }
        model.loginItems = FakeLoginItems()
        try? await model.refresh()

        await model.switchTo("acct-b")
        XCTAssertEqual(model.lastError, "cooldown active")

        model.lastError = nil // the banner's onDismiss
        XCTAssertNil(model.lastError)

        await model.switchTo("acct-b")
        XCTAssertEqual(model.lastError, "cooldown active",
                       "the same error on a retry must surface again after dismissal")
    }
}
