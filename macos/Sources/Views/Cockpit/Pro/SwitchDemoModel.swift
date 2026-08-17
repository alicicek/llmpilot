import Foundation

// Native port of web/src/pro/SwitchDemo.tsx's data derivation
// (`Lane`/`demoLanes`/`lineFor`) and its animation loop (`SwitchDemo`'s
// effect). OnboardingModel.swift's own header comment marks these
// (percentages, reset clocks, the animation itself) explicitly OUT of its
// scope and hands them to "the screens chunk" — this file.

/// SwitchDemo.tsx's `Lane` (SwitchDemo.tsx:15-21).
struct EduLane: Equatable {
    let email: String
    /// The lane's resting number — its real session percent at render.
    let low: Int
    /// HH:MM the lane's live window resets, when the snapshot knows it.
    let resets: String?
}

/// SwitchDemo.tsx:23-25 `sessionBucket` — the session-shaped bucket a
/// snapshot carries, by either of its two kind spellings.
private func eduSessionBucket(_ account: AccountState) -> Bucket? {
    account.snapshot?.buckets.first { $0.kind == "session" || $0.kind == "five_hour" }
}

/// SwitchDemo.tsx:27-33 `toLane`.
private func eduToLane(_ account: AccountState) -> EduLane {
    let bucket = eduSessionBucket(account)
    let resets = bucket?.resetsAt.map(EducationMath.hhmm)
    return EduLane(email: account.email, low: Int((bucket?.percent ?? 0).rounded()), resets: resets)
}

/// SwitchDemo.tsx:38-50 `demoLanes` — the switch story's two lanes: the
/// active account, then the genuinely separate account with the LEAST
/// headroom (ties break toward array order, mirroring `Array.sort`'s
/// stable sort). `nil` when the fleet cannot tell the story (fewer than
/// two distinct, non-empty emails).
func eduDemoLanes(_ state: DaemonState) -> [EduLane]? {
    var byEmail: [String: AccountState] = [:]
    var order: [String] = []
    for account in state.accounts where !account.email.isEmpty {
        if byEmail[account.email] == nil {
            byEmail[account.email] = account
            order.append(account.email)
        }
    }
    let uniq = order.compactMap { byEmail[$0] }
    guard uniq.count >= 2 else { return nil }
    let active = uniq.first { $0.id == state.activeID } ?? uniq[0]
    let target = uniq
        .filter { $0.email != active.email }
        .sorted { eduSessionBucket($0)?.percent ?? 0 < eduSessionBucket($1)?.percent ?? 0 }
        .first
    guard let target else { return nil }
    return [eduToLane(active), eduToLane(target)]
}

/// SwitchDemo.tsx's fallback when `demoLanes` can't tell a real story:
/// `demoLanes(fixtureState)` against web/src/fixtures.ts's masked pair.
/// `active_id` is "kai" (9%, resets 17:19); the remaining two are alex
/// (98%) and mira (0%, no reset) — sorted ascending by percent, mira wins
/// the target slot. Hardcoded rather than decoded from a ported fixture
/// state: only the resulting `Lane` pair is ever observable here.
///
/// Demo identities read as real addresses everywhere user-visible — the
/// fresh-user audit 2026-08-16 (F10) caught this fallback pair still on
/// the old @example.dev placeholder.
let eduMaskedLanes: [EduLane] = [
    EduLane(email: "kai@llmpilot.dev", low: 9, resets: "17:19"),
    EduLane(email: "mira@llmpilot.dev", low: 0, resets: nil),
]

/// The animated beat behind `SwitchDemoView` — design critique 2026-08-09
/// replaced `SwitchDemo.tsx`'s forever-looping effect with a ONE-SHOT
/// demonstration. Owner 2026-08-13 (ship walk) retold the climb: lane A
/// rides from 71% deep into the red band and the switch fires at 97% — one
/// tick under the wall — matching the adaptive time-to-wall engine landing
/// in the same release (97 is its Max-20× ceiling; "before the wall" stays
/// literally true). This supersedes the 2026-08-09 "amber only, never red"
/// rule, which was pegged to the old fixed-90 default. A's percents are a
/// fixed narrative device, not `lanes[0].low`; lane B's resting number IS
/// its real `low` (already genuinely low — that's why `eduDemoLanes`
/// picked it).
///
/// Timeline (ms from `start()`):
///   0      — A active at 71%, B ready at its own low number.
///   300    — rest elapses: "Approaching session limit"; A begins its
///            71→97 climb — `percentA` ticks up every `climbTickMs`
///            (F9, 2026-08-16 audit: the NUMBER climbs, not just the bar
///            the view eases under it — see SwitchDemoView.swift), crossing
///            amber into red as it climbs.
///   1700   — A reaches 97%, one tick under the wall: "Switching to B…".
///   1900   — handoff: `active` flips to B, A becomes the resting lane —
///            copy and visual state change in the SAME beat, fixing the
///            original 1500ms lag between "Switched to…" and the flip.
///            B's creep also starts here (F9): `percentB` ticks up a few
///            points over `creepMs` — "you keep working" on the account
///            that just took over.
///   2200   — settled: the composed summary line, `settled = true` (the
///            creep keeps running in the background past this point).
///
/// Runs once and stops — `start()` is also what a "Replay" control calls
/// (SwitchDemoView.swift) to run it again on demand.
@MainActor
final class SwitchDemoModel: ObservableObject {
    @Published private(set) var active: Int
    @Published private(set) var percentA: Int
    @Published private(set) var percentB: Int
    /// The index of the lane now resting (nil until the handoff lands) —
    /// drives each row's "Resting until HH:MM" caption.
    @Published private(set) var restingIndex: Int?
    @Published private(set) var line: String?
    @Published private(set) var settled: Bool

    /// 2026-08-09 beat table, climb retold by the owner 2026-08-13: 26
    /// points over 1400ms — the long, visible approach the old 2-point
    /// climb never delivered (the audit called it "nearly invisible").
    static let restMs = 300
    static let climbMs = 1400
    static let handoffMs = 200
    static let settleDelayMs = 300
    /// A's fixed narrative bookends. 71 is ①'s own starting number (one
    /// story, two screens); 97 is the adaptive engine's Max-20× ceiling —
    /// the switch fires one tick under the wall, riding the red band the
    /// way the shipped policy actually does at its edge.
    static let startPercent = 71
    static let switchPercent = 97
    /// Fresh-user audit 2026-08-16 (F9): the old code JUMPED `percentA` to
    /// 97 the instant the climb began — the bar eased visually over
    /// `climbMs` but the trailing "N%" text sat static at 97 the whole
    /// time, so the number never actually looked like it was climbing.
    /// These ticks make the TEXT climb in lockstep with the bar: 1400ms /
    /// 50ms = 28 ticks, landing on exactly 97 (71+26) the instant the last
    /// tick fires — no rounding slop at the boundary.
    static let climbTickMs = 50
    /// From the 2026-08-16 ship walk: the second account should visibly
    /// start climbing too, so a switch reads as work continuing — B's
    /// post-handoff creep. 4s / 200ms = 20 ticks;
    /// +8 points sits mid the requested 6–12% band.
    static let creepMs = 4000
    static let creepTickMs = 200
    static let creepAmount = 8

    /// Exactly two lanes — `SwitchDemo.tsx`'s original `[Lane, Lane]` tuple
    /// type; enforced at init since Swift arrays carry no fixed-length type.
    let lanes: [EduLane]
    private let reducedMotion: Bool
    private let clock: EduClock
    private var tokens: [EduTimerToken] = []
    private var climbTickToken: EduTimerToken?
    private var climbTicksElapsed = 0
    private var creepTickToken: EduTimerToken?
    private var creepTicksElapsed = 0
    private var creepStartPercent = 0
    private var creepTargetPercent = 0

    init(lanes: [EduLane], reducedMotion: Bool, clock: EduClock = SystemEduClock()) {
        precondition(lanes.count == 2, "SwitchDemoModel needs exactly two lanes")
        self.lanes = lanes
        self.reducedMotion = reducedMotion
        self.clock = clock
        if reducedMotion {
            // One settled frame: the switch already happened.
            active = 1
            percentA = Self.switchPercent
            percentB = lanes[1].low
            restingIndex = 0
            line = Self.lineFor(lanes: lanes, spent: 0, next: 1)
            settled = true
        } else {
            active = 0
            percentA = Self.startPercent
            percentB = lanes[1].low
            restingIndex = nil
            line = nil
            settled = false
        }
    }

    func start() {
        stop()
        guard !reducedMotion else { return }
        active = 0
        percentA = Self.startPercent
        percentB = lanes[1].low
        restingIndex = nil
        line = nil
        settled = false
        tokens.append(clock.after(Self.restMs) { [weak self] in self?.beginApproach() })
    }

    func stop() {
        tokens.forEach { $0.invalidate() }
        tokens.removeAll()
        climbTickToken = nil
        creepTickToken = nil
    }

    /// F9: the number now climbs WITH the bar instead of jumping straight
    /// to 97 — `climbTick()` re-derives `percentA` from elapsed ticks every
    /// `climbTickMs`, and `hitLimit` (still scheduled off the unchanged
    /// `climbMs` `after`, so the "Switching to…" beat timing is untouched)
    /// pins the exact final value.
    private func beginApproach() {
        line = Self.approachingLine
        climbTicksElapsed = 0
        let tick = clock.every(Self.climbTickMs) { [weak self] in self?.climbTick() }
        climbTickToken = tick
        tokens.append(tick)
        tokens.append(clock.after(Self.climbMs) { [weak self] in self?.hitLimit() })
    }

    private func climbTick() {
        climbTicksElapsed += 1
        let elapsedMs = min(climbTicksElapsed * Self.climbTickMs, Self.climbMs)
        let progress = Double(elapsedMs) / Double(Self.climbMs)
        let span = Double(Self.switchPercent - Self.startPercent)
        percentA = Self.startPercent + Int((progress * span).rounded())
    }

    private func hitLimit() {
        climbTickToken?.invalidate()
        climbTickToken = nil
        percentA = Self.switchPercent // pin the exact bookend regardless of tick rounding
        line = Self.switchingLine(to: lanes[1])
        tokens.append(clock.after(Self.handoffMs) { [weak self] in self?.handoff() })
    }

    /// Copy and visual state change TOGETHER here — the fix for the
    /// original bug where `switchLine` said "Switched to…" 1500ms before
    /// `active` actually moved. F9: B's creep starts in this SAME beat —
    /// "you keep working" reads from the moment the handoff lands, not
    /// after the settled summary shows up.
    private func handoff() {
        active = 1
        restingIndex = 0
        startCreep()
        tokens.append(clock.after(Self.settleDelayMs) { [weak self] in self?.settle() })
    }

    /// B's post-handoff creep (F9) — a few points over a few seconds so the
    /// demo shows work continuing on the account that just took over.
    /// Independent of `settle()`: the narrative line settles at 2200ms
    /// while the creep keeps running in the background past it.
    private func startCreep() {
        creepTicksElapsed = 0
        creepStartPercent = percentB
        creepTargetPercent = min(100, percentB + Self.creepAmount)
        guard creepTargetPercent > creepStartPercent else { return }
        let tick = clock.every(Self.creepTickMs) { [weak self] in self?.creepTick() }
        creepTickToken = tick
        tokens.append(tick)
    }

    private func creepTick() {
        creepTicksElapsed += 1
        let elapsedMs = min(creepTicksElapsed * Self.creepTickMs, Self.creepMs)
        let progress = Double(elapsedMs) / Double(Self.creepMs)
        let span = Double(creepTargetPercent - creepStartPercent)
        percentB = creepStartPercent + Int((progress * span).rounded())
        if elapsedMs >= Self.creepMs {
            creepTickToken?.invalidate()
            creepTickToken = nil
        }
    }

    private func settle() {
        line = Self.lineFor(lanes: lanes, spent: 0, next: 1)
        settled = true
    }

    static let approachingLine = "Approaching session limit"

    static func switchingLine(to lane: EduLane) -> String { "Switching to \(lane.email)…" }

    /// SwitchDemo.tsx's original `lineFor` — the settled summary sentence.
    static func lineFor(lanes: [EduLane], spent: Int, next: Int) -> String {
        let spentLane = lanes[spent]
        let nextLane = lanes[next]
        let rest = spentLane.resets.map { "\(spentLane.email) rests until \($0)" }
            ?? "\(spentLane.email) rests until its window resets"
        return "Switched to \(nextLane.email) — \(rest)"
    }

    /// ONE coherent VoiceOver sentence for the settled demo — fixes VO
    /// previously reading fragments (the gauge was AX-hidden and the
    /// repeating line wasn't a live region at all).
    static func voiceOverSummary(lanes: [EduLane], spent: Int, next: Int) -> String {
        let spentLane = lanes[spent]
        let nextLane = lanes[next]
        let rest = spentLane.resets.map { "\(spentLane.email) rests until \($0)." }
            ?? "\(spentLane.email) rests until its window resets."
        return "Switched to \(nextLane.email). \(rest)"
    }
}
