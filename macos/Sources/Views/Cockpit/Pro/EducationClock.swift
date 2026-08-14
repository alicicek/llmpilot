import Foundation

// Injectable timer seam for the onboarding education screens' animated
// beats (WallScreen's climb, BlindSpotScreen's reveal, WindowsScreen's
// booked/ran beats, SwitchDemo's whole loop) — mirrors how
// `Board/TrackDragModel.swift` takes its side effects through an injected
// `BoardTicker` protocol rather than reaching for a concrete singleton:
// production gets `SystemEduClock` (real `DispatchQueue`/`Timer`), tests get
// a manual double (`macos/Tests/EduFakeClock.swift`'s `ManualEduClock`) that
// fires callbacks by advancing virtual milliseconds — no beat sequence ever
// needs a real sleep in a test.

/// A single scheduled callback, cancellable exactly once (repeat calls are
/// a safe no-op) — `SystemEduClock`'s tokens wrap a real timer/work item;
/// `ManualEduClock`'s wrap a virtual-time entry.
final class EduTimerToken {
    private var cancelAction: (() -> Void)?

    init(cancel: @escaping () -> Void) {
        self.cancelAction = cancel
    }

    func invalidate() {
        cancelAction?()
        cancelAction = nil
    }
}

/// `after`/`every` mirror the two timer primitives every ported beat
/// sequence uses (`window.setTimeout`/`window.setInterval` in the source
/// `useBeat`/`SwitchDemo` effects): a one-shot delay and a repeat that
/// fires ONLY after the first full interval elapses (no immediate first
/// tick — matches `setInterval`).
protocol EduClock {
    @discardableResult
    func after(_ ms: Int, _ action: @escaping () -> Void) -> EduTimerToken

    @discardableResult
    func every(_ ms: Int, _ action: @escaping () -> Void) -> EduTimerToken
}

/// Production clock: real main-queue/main-run-loop timers. Every beat
/// model driven by this is `@MainActor`, mirroring the DOM's single-
/// threaded timers the ported source relies on.
final class SystemEduClock: EduClock {
    func after(_ ms: Int, _ action: @escaping () -> Void) -> EduTimerToken {
        let work = DispatchWorkItem(block: action)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms), execute: work)
        return EduTimerToken(cancel: { work.cancel() })
    }

    func every(_ ms: Int, _ action: @escaping () -> Void) -> EduTimerToken {
        let timer = Timer.scheduledTimer(withTimeInterval: Double(ms) / 1000, repeats: true) { _ in
            action()
        }
        // .common keeps the tick alive while a window is mid-interaction
        // (e.g. the user is scrolling the onboarding card) — a default-mode
        // timer would silently stall the whole beat until tracking ends.
        RunLoop.main.add(timer, forMode: .common)
        return EduTimerToken(cancel: { timer.invalidate() })
    }
}
