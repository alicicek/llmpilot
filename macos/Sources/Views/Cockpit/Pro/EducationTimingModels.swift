import Foundation

// Testable beat drivers for the education screens — one model per screen.
// Every model takes an injected `EduClock` (EducationClock.swift) so a test
// drives the full beat with `ManualEduClock.advance(byMs:)`, never a real
// sleep, and takes `reducedMotion` as an init parameter (not read from the
// environment itself) so both branches are directly testable without a
// view.
//
// DESIGN CRITIQUE (owner 2026-08-09) replaced the original literal port of
// Education.tsx's 34ms `setInterval` ticks with ONE-SHOT causal beats: each
// model publishes an end value exactly once and the VIEW animates the
// resulting geometry smoothly over the beat's own duration ("a single
// animation, not 34ms steps") — the repeating tick was a React port
// artifact (each 180ms bar animation replaced 34ms later, perpetually
// chasing itself), not a real product requirement. Every DISCRETE UI
// transition (toasts, fades, crossfades, badge moves) stays inside the
// 150-250ms motion budget (CockpitTheme.Motion.state); the "smooth fill"
// climbs are the one exception the brief names explicitly, timed as given.
//
// `start()`/`stop()` mirror the original effect's run/cleanup pair: a view
// calls `start()` from `.onAppear` (and again whenever `reducedMotion`
// flips — see EducationViews.swift's `.id(reduceMotion)` re-mount pattern)
// and `stop()` from `.onDisappear`.

/// ① WallScreen — the session bar smooth-fills 71→100%, then the "spent"
/// toast lands.
@MainActor
final class WallBeatModel: ObservableObject {
    @Published private(set) var percent: Int
    @Published private(set) var spent: Bool

    static let startPercent = 71
    static let endPercent = 100
    /// Beat: 300ms rest, then ONE jump to `endPercent` — the view animates
    /// the bar's width over `fillMs` (a single SwiftUI animation), not a
    /// stepped climb. The percent TEXT resolves the instant this fires (no
    /// interpolation) — "the number may resolve coarsely" (brief).
    static let restMs = 300
    static let fillMs = 900

    private let reducedMotion: Bool
    private let clock: EduClock
    private var tokens: [EduTimerToken] = []

    init(reducedMotion: Bool, clock: EduClock = SystemEduClock()) {
        self.reducedMotion = reducedMotion
        self.clock = clock
        if reducedMotion {
            percent = Self.endPercent
            spent = true
        } else {
            percent = Self.startPercent
            spent = false
        }
    }

    func start() {
        stop()
        guard !reducedMotion else { return }
        percent = Self.startPercent
        spent = false
        tokens.append(clock.after(Self.restMs) { [weak self] in self?.fill() })
    }

    func stop() {
        tokens.forEach { $0.invalidate() }
        tokens.removeAll()
    }

    private func fill() {
        percent = Self.endPercent
        tokens.append(clock.after(Self.fillMs) { [weak self] in self?.spent = true })
    }
}

/// ② BlindSpotScreen — the identity inventory beyond the first account
/// reveals after a short pause.
@MainActor
final class BlindSpotBeatModel: ObservableObject {
    @Published private(set) var revealed: Bool

    /// Design critique 2026-08-09 — 350ms pause, then a 200ms fade
    /// (replaces the original 900ms pause / 500ms fade pair).
    static let revealDelayMs = 350
    /// The reveal's own fade duration — the VIEW applies this as an
    /// `.easeInOut` animation duration around `revealed`.
    static let revealFadeMs = 200

    private let reducedMotion: Bool
    private let clock: EduClock
    private var tokens: [EduTimerToken] = []

    init(reducedMotion: Bool, clock: EduClock = SystemEduClock()) {
        self.reducedMotion = reducedMotion
        self.clock = clock
        revealed = reducedMotion
    }

    func start() {
        stop()
        guard !reducedMotion else {
            revealed = true
            return
        }
        revealed = false
        tokens.append(clock.after(Self.revealDelayMs) { [weak self] in self?.revealed = true })
    }

    func stop() {
        tokens.forEach { $0.invalidate() }
        tokens.removeAll()
    }
}

/// ⑤ WindowsScreen — the block appears (the booking), then the window is
/// OPEN and in use (owner 2026-08-12: booked 07:00 → in use at 10:20 —
/// the old second beat showed the window already spent/idle, which told a
/// "you missed it" story instead of "it's running for you right now").
@MainActor
final class WindowsBeatModel: ObservableObject {
    @Published private(set) var booked: Bool
    @Published private(set) var opened: Bool

    /// Design critique 2026-08-09 — 450ms (was 900ms). The block's own
    /// transition is a 200ms OPACITY fade only, no scale (WindowsScreenView.
    /// swift).
    static let bookedDelayMs = 450
    /// 1500ms (was 2100ms). The status swap crossfades over 200ms
    /// (WindowsScreenView.swift).
    static let openedDelayMs = 1500

    private let reducedMotion: Bool
    private let clock: EduClock
    private var tokens: [EduTimerToken] = []

    init(reducedMotion: Bool, clock: EduClock = SystemEduClock()) {
        self.reducedMotion = reducedMotion
        self.clock = clock
        booked = reducedMotion
        opened = reducedMotion
    }

    func start() {
        stop()
        guard !reducedMotion else {
            booked = true
            opened = true
            return
        }
        booked = false
        opened = false
        tokens.append(clock.after(Self.bookedDelayMs) { [weak self] in self?.booked = true })
        tokens.append(clock.after(Self.openedDelayMs) { [weak self] in self?.opened = true })
    }

    func stop() {
        tokens.forEach { $0.invalidate() }
        tokens.removeAll()
    }
}
