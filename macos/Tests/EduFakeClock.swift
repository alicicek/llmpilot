import Foundation
@testable import llmpilot

/// Deterministic virtual-time double for `EduClock` (Pro/EducationClock.
/// swift) — tests advance time explicitly via `advance(byMs:)`; nothing
/// here ever sleeps. Mirrors `TrackDragModelTests`' `CountingTicker`: a
/// small test-only conformance to the model's own injected protocol.
final class ManualEduClock: EduClock {
    private struct Entry {
        let token: EduTimerToken
        var dueMs: Int
        let intervalMs: Int?
        let action: () -> Void
    }

    private var entries: [Entry] = []
    private(set) var nowMs = 0

    func after(_ ms: Int, _ action: @escaping () -> Void) -> EduTimerToken {
        schedule(ms: ms, intervalMs: nil, action: action)
    }

    func every(_ ms: Int, _ action: @escaping () -> Void) -> EduTimerToken {
        schedule(ms: ms, intervalMs: ms, action: action)
    }

    private func schedule(ms: Int, intervalMs: Int?, action: @escaping () -> Void) -> EduTimerToken {
        var token: EduTimerToken!
        token = EduTimerToken(cancel: { [weak self] in self?.remove(token) })
        entries.append(Entry(token: token, dueMs: nowMs + ms, intervalMs: intervalMs, action: action))
        return token
    }

    private func remove(_ token: EduTimerToken) {
        entries.removeAll { $0.token === token }
    }

    /// Advances virtual time by `ms`, firing every due callback in
    /// chronological order — including ones newly scheduled by an
    /// already-firing callback (e.g. `SwitchDemoModel.fire()` chaining
    /// more timers mid-advance).
    func advance(byMs ms: Int) {
        let target = nowMs + ms
        while let idx = nextDueIndex(upTo: target) {
            let entry = entries[idx]
            nowMs = entry.dueMs
            if let interval = entry.intervalMs {
                entries[idx].dueMs += interval
            } else {
                entries.remove(at: idx)
            }
            entry.action()
        }
        nowMs = target
    }

    private func nextDueIndex(upTo target: Int) -> Int? {
        var best: Int?
        for i in entries.indices where entries[i].dueMs <= target {
            if best == nil || entries[i].dueMs < entries[best!].dueMs { best = i }
        }
        return best
    }
}
