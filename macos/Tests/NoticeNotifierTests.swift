import UserNotifications
import XCTest

@testable import llmpilot

/// Scriptable `UNCenter` stub — records every call so a test can prove
/// exactly what did or did not reach the (fake) notification center.
final class RecordingUNCenter: UNCenter, @unchecked Sendable {
    var status: UNAuthorizationStatus = .notDetermined
    var authorizationResult: Result<Bool, Error> = .success(true)
    private(set) var statusReads = 0
    private(set) var authorizationRequests = 0
    private(set) var foregroundBannersEnabled = 0
    private(set) var added: [(id: String, title: String, body: String)] = []

    func authorizationStatus() async -> UNAuthorizationStatus {
        statusReads += 1
        return status
    }

    func requestAuthorization() async throws -> Bool {
        authorizationRequests += 1
        let granted = try authorizationResult.get()
        status = granted ? .authorized : .denied
        return granted
    }

    func enableForegroundBanners() {
        foregroundBannersEnabled += 1
    }

    func add(id: String, title: String, body: String) async throws {
        added.append((id, title, body))
    }
}

@MainActor
final class NoticeNotifierTests: XCTestCase {
    private func notice(id: String = "1-1", title: String = "llmpilot", body: String = "a at 80%") -> Notice {
        Notice(id: id, at: Date(), title: title, body: body)
    }

    // MARK: - canDeliver (the subscribe gate; review 2026-08-08 P0-1)

    /// canDeliver must NEVER prompt (delta re-review: the one permission
    /// ask belongs to user-visible moments, not the notice client's launch
    /// poll) — `.notDetermined` parks exactly like `.denied`.
    func testCanDeliverParksWhileUndeterminedWithoutPrompting() async {
        let center = RecordingUNCenter()
        let sut = NoticeNotifier(center: center, testInterlocked: false)
        let outcome = await sut.canDeliver()
        XCTAssertFalse(outcome)
        XCTAssertEqual(center.authorizationRequests, 0, "canDeliver must never spend the permission prompt")
        XCTAssertEqual(center.foregroundBannersEnabled, 0)
    }

    func testCanDeliverIsTrueOnceAuthorizedAndInstallsTheForegroundDelegate() async {
        let center = RecordingUNCenter()
        center.status = .authorized
        let sut = NoticeNotifier(center: center, testInterlocked: false)
        let outcome = await sut.canDeliver()
        XCTAssertTrue(outcome)
        // P0-2: without the delegate, macOS silently suppresses banners
        // while the app is frontmost — deliverable must mean installed.
        XCTAssertEqual(center.foregroundBannersEnabled, 1)
        XCTAssertEqual(center.authorizationRequests, 0)
    }

    func testCanDeliverIsFalseWhenDenied() async {
        let center = RecordingUNCenter()
        center.status = .denied
        let sut = NoticeNotifier(center: center, testInterlocked: false)
        let outcome = await sut.canDeliver()
        XCTAssertFalse(outcome, "a denial must keep the client OFF the wire so the daemon's osascript fallback stays live")
        XCTAssertEqual(center.foregroundBannersEnabled, 0)
    }

    // MARK: - requestPermission (the one user-visible ask)

    func testRequestPermissionPromptsOnceFromUndeterminedThenGrants() async {
        let center = RecordingUNCenter()
        let sut = NoticeNotifier(center: center, testInterlocked: false)
        let granted = await sut.requestPermission()
        XCTAssertTrue(granted)
        XCTAssertEqual(center.authorizationRequests, 1)
        XCTAssertEqual(center.foregroundBannersEnabled, 1)

        // The grant is now visible to the subscribe gate.
        let deliverable = await sut.canDeliver()
        XCTAssertTrue(deliverable)

        // A second trigger (Settings toggle after onboarding) never
        // re-prompts.
        _ = await sut.requestPermission()
        XCTAssertEqual(center.authorizationRequests, 1)
    }

    func testRequestPermissionRespectsAStandingDenial() async {
        let center = RecordingUNCenter()
        center.status = .denied
        let sut = NoticeNotifier(center: center, testInterlocked: false)
        let granted = await sut.requestPermission()
        XCTAssertFalse(granted)
        XCTAssertEqual(center.authorizationRequests, 0, "a standing denial is never re-prompted — that's System Settings' job")
    }

    func testRequestPermissionNeverTouchesTheCenterUnderTheInterlock() async {
        let center = RecordingUNCenter()
        let sut = NoticeNotifier(center: center, testInterlocked: true)
        let granted = await sut.requestPermission()
        XCTAssertFalse(granted)
        XCTAssertEqual(center.statusReads, 0)
        XCTAssertEqual(center.authorizationRequests, 0)
    }

    // MARK: - foreground presentation (review 2026-08-08 P0-2)

    /// The async delegate spelling must actually expose the ObjC
    /// completion-handler selector — if the bridge ever broke, the delegate
    /// would install and then silently never be consulted, reintroducing
    /// "no banner while the cockpit is frontmost".
    func testForegroundBannerDelegateExposesTheWillPresentSelectorAndShowsBanners() async {
        let delegate = ForegroundBannerDelegate.shared
        XCTAssertTrue(
            delegate.responds(
                to: NSSelectorFromString("userNotificationCenter:willPresentNotification:withCompletionHandler:")),
            "the async willPresent spelling stopped bridging to the ObjC selector")
    }

    /// The interlock's fail case, called out explicitly by the chunk 5B
    /// brief: under LLMPILOT_TEST the notifier must NEVER touch the center
    /// — not status, not authorization, not add. A stray call here would
    /// mean a real system permission prompt on a dev machine or inside a
    /// sandboxed e2e run sharing the real bundle id.
    func testNeverCallsCenterUnderTestInterlock() async {
        let center = RecordingUNCenter()
        let sut = NoticeNotifier(center: center, testInterlocked: true)
        let deliverable = await sut.canDeliver()
        XCTAssertFalse(deliverable, "interlocked app must not subscribe — sandbox notices route to the daemon's slog stub")
        let posted = await sut.post(notice())
        XCTAssertFalse(posted)
        XCTAssertEqual(center.statusReads, 0)
        XCTAssertEqual(center.authorizationRequests, 0,
                        "requestAuthorization must never be called under the test interlock")
        XCTAssertEqual(center.added.count, 0, "add must never be called under the test interlock")
        XCTAssertEqual(center.foregroundBannersEnabled, 0)
    }

    // MARK: - post

    func testPostsThroughTheCenterWhenAuthorized() async {
        let center = RecordingUNCenter()
        center.status = .authorized
        let sut = NoticeNotifier(center: center, testInterlocked: false)
        let posted = await sut.post(notice())
        XCTAssertTrue(posted)
        XCTAssertEqual(center.added.count, 1)
        XCTAssertEqual(center.added.first?.title, "llmpilot")
        XCTAssertEqual(center.added.first?.body, "a at 80%")
        XCTAssertEqual(center.added.first?.id, "1-1")
    }

    /// A mid-stream revocation must be REPORTED, not swallowed: `false`
    /// tells NoticeClient to drop its subscription so the daemon's
    /// fallback covers every later notice (review 2026-08-08 P0-1).
    func testPostReportsRevocationSoTheClientCanDisconnect() async {
        let center = RecordingUNCenter()
        center.status = .authorized
        let sut = NoticeNotifier(center: center, testInterlocked: false)
        let first = await sut.post(notice(id: "1"))
        XCTAssertTrue(first)

        center.status = .denied
        let second = await sut.post(notice(id: "2"))
        XCTAssertFalse(second)
        XCTAssertEqual(center.added.map(\.id), ["1"], "a revoked post must not reach the center")
    }

    func testPostDoesNotPromptItself() async {
        // Authorization resolution belongs to canDeliver (the subscribe
        // gate) — post on an undetermined center refuses rather than
        // prompting at an arbitrary notice.
        let center = RecordingUNCenter()
        let sut = NoticeNotifier(center: center, testInterlocked: false)
        let posted = await sut.post(notice())
        XCTAssertFalse(posted)
        XCTAssertEqual(center.authorizationRequests, 0)
        XCTAssertEqual(center.added.count, 0)
    }
}
