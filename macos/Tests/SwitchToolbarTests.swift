import XCTest
@testable import llmpilot

/// Phase 2 chunk A coverage: the SWITCH verb's button-visibility rule
/// (LaneHeader.tsx:68), the "＋ Add account" badge's unregistered-count
/// derivation (Toolbar.tsx:43-53 / App.tsx:422, via FleetViewModel's own
/// `unadoptedDetectedCount`), and the toolbar's error-flash dismiss state
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

    // MARK: - unregistered detected-count badge (Toolbar.tsx:43-53, App.tsx:422)

    private func detected(registered: [Bool]) -> [DetectedDir] {
        registered.enumerated().map { i, isRegistered in
            DetectedDir(configDir: "/tmp/dir-\(i)", email: "u\(i)@example.dev", registered: isRegistered, moved: false)
        }
    }

    func testUnregisteredDetectedCountDerivation() async throws {
        let api = StubAPI()
        api.stateResult = .success(Fixtures.twoAccounts())

        // Mixed registered/unregistered — only the unregistered ones count.
        api.detectResult = detected(registered: [false, true, false, false])
        let model = FleetViewModel(api: api, autostart: false)
        model.defaults = UserDefaults(suiteName: "SwitchToolbarTests")!
        model.openWindow = { _ in }
        model.loginItems = FakeLoginItems()
        try await model.refresh()
        XCTAssertEqual(model.unadoptedDetectedCount, 3)

        // All registered — badge count (and so the badge itself) is 0.
        api.detectResult = detected(registered: [true, true])
        try await model.refresh()
        XCTAssertEqual(model.unadoptedDetectedCount, 0)

        // Nothing detected at all — still 0, never negative or nil-crashing.
        api.detectResult = []
        try await model.refresh()
        XCTAssertEqual(model.unadoptedDetectedCount, 0)
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
