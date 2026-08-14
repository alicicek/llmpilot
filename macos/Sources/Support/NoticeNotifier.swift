import Foundation
import UserNotifications

/// Seam over `UNUserNotificationCenter` — the only calls a notifier ever
/// needs. Exists so `NoticeNotifier` can be driven by a recorder in tests,
/// and so the LLMPILOT_TEST interlock below has something to gate: under
/// test the real center is never constructed, never mind called.
protocol UNCenter: Sendable {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization() async throws -> Bool
    /// Installs the foreground-presentation delegate (idempotent).
    func enableForegroundBanners()
    func add(id: String, title: String, body: String) async throws
}

/// The real macOS notification center. Constructed only by `NoticeNotifier`'s
/// default, and only reached when the LLMPILOT_TEST interlock is off.
struct RealUNCenter: UNCenter {
    func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func requestAuthorization() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    func enableForegroundBanners() {
        UNUserNotificationCenter.current().delegate = ForegroundBannerDelegate.shared
    }

    func add(id: String, title: String, body: String) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        try await UNUserNotificationCenter.current().add(request)
    }
}

/// Without a delegate, macOS SILENTLY suppresses a notification delivered
/// while this app is frontmost — and the cockpit window activates the app,
/// so "user is looking at the cockpit when an account crosses 90%" is the
/// common case, not the edge (review 2026-08-08 P0-2). The osascript banner
/// this pipeline replaces showed regardless of the frontmost app; presenting
/// the banner here restores that behavior.
final class ForegroundBannerDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ForegroundBannerDelegate()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

/// Posts daemon notices (from GET /v1/notices, via NoticeStream) through
/// UNUserNotificationCenter.
///
/// DELIVERY CONTRACT (review 2026-08-08 P0-1): the daemon suppresses its own
/// osascript fallback whenever a /v1/notices subscriber is connected —
/// "connected" must therefore mean "can actually deliver". `canDeliver()` is
/// the client's subscribe gate: it resolves authorization FIRST (prompting
/// once if undetermined), and a denial means the client never subscribes, so
/// the daemon's banner path stays live instead of every notice silently
/// evaporating. `post` re-checks status per notice and reports failure so a
/// mid-stream revocation tears the subscription down (one notice is lost at
/// the revocation instant — it was already consumed off the stream; every
/// later one falls back).
///
/// This moves the authorization prompt from "first notice" to "notice client
/// start" — deliberate: the lazy prompt was exactly what made a denial
/// undetectable before the daemon had already committed to the subscriber.
///
/// LLMPILOT_TEST interlock (chunk 5B brief: never weaken, only extend): under
/// LLMPILOT_TEST=1 — or hosted under XCTest — this NEVER calls into
/// UNUserNotificationCenter, not even to ask for authorization: the sandboxed
/// e2e apps share the REAL bundle id, so a live system permission prompt on
/// the dev machine is forbidden. Under the interlock `canDeliver()` is false,
/// so the interlocked app also never SUBSCRIBES — which routes sandbox
/// notices to the daemon's slog stub where the e2e can observe them (the
/// pre-fix behavior had the sandbox app subscribing and dropping notices
/// invisibly).
@MainActor
final class NoticeNotifier {
    /// One instance app-wide: the notice client's subscribe gate and the
    /// UI's permission-prompt triggers must share authorization state.
    static let shared = NoticeNotifier()

    private let center: UNCenter
    private let testInterlocked: Bool
    private var prompted = false

    init(
        center: UNCenter = RealUNCenter(),
        testInterlocked: Bool =
            ProcessInfo.processInfo.environment["LLMPILOT_TEST"] == "1"
                || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    ) {
        self.center = center
        self.testInterlocked = testInterlocked
    }

    /// The subscribe gate. Under the interlock: false, center untouched.
    /// NEVER prompts — `.notDetermined` parks exactly like `.denied` (the
    /// daemon's osascript fallback covers both identically), so the one
    /// system permission ask is not spent at app launch with zero context
    /// (delta re-review 2026-08-08: launch is the highest-denial-rate
    /// moment; `requestPermission()` below hangs it on user-visible moments
    /// instead). Callable repeatedly — a grant from System Settings or from
    /// `requestPermission` is picked up on the client's next poll.
    func canDeliver() async -> Bool {
        guard !testInterlocked else { return false }
        switch await center.authorizationStatus() {
        case .authorized, .provisional:
            center.enableForegroundBanners()
            return true
        default:
            return false
        }
    }

    /// The ONE permission ask, fired from moments where the user already
    /// understands what the app is: the end of first-run onboarding, and
    /// flipping Settings → "Usage notifications" on. Prompts only from
    /// `.notDetermined`, at most once per process; every other status is
    /// just reported. Interlocked: never touches the center.
    @discardableResult
    func requestPermission() async -> Bool {
        guard !testInterlocked else { return false }
        let status = await center.authorizationStatus()
        switch status {
        case .authorized, .provisional:
            center.enableForegroundBanners()
            return true
        case .notDetermined where !prompted:
            prompted = true
            let granted = (try? await center.requestAuthorization()) ?? false
            if granted { center.enableForegroundBanners() }
            return granted
        default:
            return false
        }
    }

    /// Posts one notice. Returns whether delivery LANDED — `false`
    /// (revoked mid-stream, a delivery error, or the interlock) tells the
    /// client to drop its subscription so the daemon's fallback takes over
    /// (a persistently-failing `add` must not keep suppressing the
    /// fallback; delta re-review P2). Under the interlock this never
    /// touches `center` at all — not status, not add — so a recorder
    /// swapped in for a test can prove zero calls happened.
    func post(_ notice: Notice) async -> Bool {
        guard !testInterlocked else { return false }
        let status = await center.authorizationStatus()
        guard status == .authorized || status == .provisional else { return false }
        do {
            try await center.add(id: notice.id, title: notice.title, body: notice.body)
            return true
        } catch {
            return false
        }
    }
}

/// Owns the /v1/notices connection lifecycle: verify deliverability,
/// connect, ride NoticeStream until it drops, reconnect with exponential
/// backoff, forever. Mirrors FleetViewModel's own SSE loop (start()/
/// connectOnce()) in shape, but as an independent component — the notice
/// pipeline must keep running across a daemon restart without depending on
/// FleetViewModel's state.
@MainActor
final class NoticeClient {
    private let base: () -> URL?
    private let token: () -> String?
    private let notifier: NoticeNotifier
    private let minDelayNanos: UInt64
    private let maxDelayNanos: UInt64
    private var loop: Task<Void, Never>?

    // `notifier` has no default: a default VALUE of a @MainActor type is
    // evaluated in a synchronous, non-isolated context by the compiler (a
    // Swift actor-isolation rule, not a stylistic choice), which
    // `NoticeNotifier()` can't satisfy. Every caller — LLMPilotApp and every
    // test — already constructs one explicitly at its own (isolated) call
    // site instead.
    init(
        base: @escaping () -> URL? = { HTTPDaemonClient().baseURL() },
        token: @escaping () -> String? = { HTTPDaemonClient.installToken() },
        notifier: NoticeNotifier,
        minDelayNanos: UInt64 = 1_000_000_000,
        maxDelayNanos: UInt64 = 30_000_000_000
    ) {
        self.base = base
        self.token = token
        self.notifier = notifier
        self.minDelayNanos = minDelayNanos
        self.maxDelayNanos = maxDelayNanos
    }

    /// Starts the loop; a second call while already running no-ops. Safe to
    /// call once at app launch — a dropped stream, a daemon restart, or the
    /// port/token files not existing yet all just feed the same
    /// backoff-and-retry path, since `base()`/`token()` re-read
    /// daemon.port/daemon.token from disk on every attempt.
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            guard let self else { return }
            var delay = self.minDelayNanos
            while !Task.isCancelled {
                // Subscribe ONLY while deliverable (review P0-1): a denied
                // or interlocked notifier means the daemon must keep its own
                // banner path, so stay off the wire and re-check at the max
                // interval (a later grant in System Settings is picked up).
                guard await self.notifier.canDeliver() else {
                    try? await Task.sleep(nanoseconds: self.maxDelayNanos)
                    continue
                }
                guard let base = self.base(), let token = self.token() else {
                    try? await Task.sleep(nanoseconds: delay)
                    delay = min(delay * 2, self.maxDelayNanos)
                    continue
                }
                do {
                    for try await notice in NoticeStream.connect(base: base, token: token) {
                        delay = self.minDelayNanos // a live notice proves the stream is healthy
                        guard await self.notifier.post(notice) else {
                            // Revoked mid-stream: drop the subscription so
                            // the daemon's fallback covers every later
                            // notice (this one was already consumed — the
                            // unavoidable single loss at revocation).
                            break
                        }
                    }
                } catch {
                    // Falls through to the backoff below — connect() already
                    // folded every failure (down, non-200, drop) into a throw.
                }
                guard !Task.isCancelled else { break }
                try? await Task.sleep(nanoseconds: delay)
                delay = min(delay * 2, self.maxDelayNanos)
            }
        }
    }

    /// Cancels the loop — app teardown and tests.
    func stop() {
        loop?.cancel()
        loop = nil
    }

    deinit {
        loop?.cancel()
    }
}
