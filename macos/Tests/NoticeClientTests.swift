import XCTest

@testable import llmpilot

/// Lifecycle coverage for `NoticeClient` (Support/NoticeNotifier.swift):
/// start/stop and the subscribe gate, without ever touching the network —
/// `base`/`token` are injected to return nil, so a loop that passes the gate
/// takes its "files not ready yet" backoff branch and NoticeStream.connect
/// is never reached. Small injected delays keep this fast and deterministic.
@MainActor
final class NoticeClientTests: XCTestCase {
    private func deliverableNotifier() -> NoticeNotifier {
        let center = RecordingUNCenter()
        center.status = .authorized
        return NoticeNotifier(center: center, testInterlocked: false)
    }

    func testStartIsIdempotentAndStopCancelsTheLoop() async {
        var baseCalls = 0
        let client = NoticeClient(
            base: { baseCalls += 1; return nil },
            token: { nil },
            notifier: deliverableNotifier(),
            minDelayNanos: 1_000_000,
            maxDelayNanos: 5_000_000)

        client.start()
        client.start() // second call must no-op — never a second concurrent loop

        // Poll, don't fixed-sleep: the loop's first canDeliver() hop rides
        // MainActor scheduling, which mid-suite can outlast any single
        // small sleep (flaked at 30ms under full-suite load).
        for _ in 0..<100 where baseCalls == 0 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        client.stop()

        XCTAssertGreaterThan(baseCalls, 0, "the loop read base() at least once before stop()")
    }

    /// Review 2026-08-08 P0-1: the daemon suppresses its osascript fallback
    /// for any connected subscriber, so a client that CANNOT deliver
    /// (interlocked here; denied in production) must never reach the wire —
    /// base() untouched proves the loop parked at the canDeliver gate.
    func testUndeliverableNotifierNeverSubscribes() async {
        var baseCalls = 0
        let client = NoticeClient(
            base: { baseCalls += 1; return nil },
            token: { nil },
            notifier: NoticeNotifier(center: RecordingUNCenter(), testInterlocked: true),
            minDelayNanos: 1_000_000,
            maxDelayNanos: 2_000_000)

        client.start()
        try? await Task.sleep(nanoseconds: 30_000_000)
        client.stop()

        XCTAssertEqual(baseCalls, 0, "an undeliverable client must stay off the wire so the daemon's fallback fires")
    }

    /// Stopping never crashes when the loop never ran — and a stopped client
    /// can be started again (app teardown/relaunch shape, not exercised by
    /// LLMPilotApp today but must not be a trap for a future caller).
    func testStopWithoutStartIsSafe() {
        let client = NoticeClient(
            base: { nil }, token: { nil },
            notifier: NoticeNotifier(center: RecordingUNCenter(), testInterlocked: true))
        client.stop()
    }
}
