import Foundation

// Native port of web/src/pro/Onboarding.tsx's PHASE state machine only — the
// first-run ladder ① wall ② blind spot ③ your accounts ④ the switch
// ⑤ fresh windows, with ⑥-⑨ (the ask) owned by AskMachine.swift and handed
// the "ask" phase. No screen ships in this chunk; this is the model a later
// screens chunk drives.
//
// SwitchDemo.tsx's `Lane` values (percentages, reset clocks, the animation
// itself) are OUT OF SCOPE here — this pins only the `masked` boolean
// Onboarding.tsx freezes once (real fleet vs. the masked fixture pair); the
// screens chunk owns building actual `Lane`s.

/// Onboarding.tsx's `Phase` (Onboarding.tsx:56). `.ask` is deliberately NOT
/// a member of `phases` — see `advance()`. `.switchDemo` ports the web
/// `"switch"` phase name (`switch` is a Swift keyword).
enum OnboardingPhase: Equatable {
    case wall
    case blind
    case accounts
    case switchDemo
    case windows
    case ask
}

/// Onboarding.tsx:163-176 — the accounts screen's two forward controls
/// (Continue, and the zero-detected "I'll sign in later"). Both must route
/// the SAME way: with a tour, further into the ladder; without one, straight
/// out. The forward path must never depend on `tour` alone deciding ONE of
/// the two and stranding the other (reviewer P0: a source build with
/// nothing detected and no toolbar behind the flow was a zero-control dead
/// end).
enum AccountsForwardAction: Equatable {
    case advance
    case exit
}

@MainActor
final class OnboardingModel: ObservableObject {
    @Published private(set) var tour: Bool
    @Published private(set) var phase: OnboardingPhase

    /// Frozen at construction — adding the first account flips the fleet
    /// non-empty mid-walk, and that would rewrite the ladder (and the step
    /// dots with it) under the user (Onboarding.tsx:59-61).
    let startedEmpty: Bool

    /// Design critique 2026-08-09 — the number of distinct Claude
    /// identities on this Mac (`OnboardingModel.identities(...).count`).
    /// Defaults to 2 (the inclusion threshold) so every existing caller
    /// that doesn't yet pass the real count keeps today's behaviour — ②
    /// stays in the ladder — until it's wired to the real fleet/detected
    /// count.
    ///
    /// NOT fully frozen at construction any more (audit 2026-08-11): the
    /// flow arms on the first render with a `DaemonState`, one full round
    /// trip BEFORE `/v1/detect` answers, so a construction-time freeze read
    /// 0 on every fresh machine and ② never rendered for the exact
    /// multi-account audience it teaches. `updateIdentityCount` below lets
    /// detection settle the count while the user is still on ① — the same
    /// bounded-mutability compromise `updateTour` already makes.
    @Published private(set) var identityCount: Int

    private var cachedMasked: Bool?
    private var lastLicense: LicenseInfo?

    init(tour: Bool, startedEmpty: Bool, identityCount: Int = 2) {
        self.tour = tour
        self.startedEmpty = startedEmpty
        self.identityCount = identityCount
        self.phase = tour ? .wall : (startedEmpty ? .accounts : .ask)
    }

    /// Onboarding.tsx:63-80 — `tour` may only go UP. A plain downgrade
    /// (activating flips `props.tour` false mid-flow) is ignored, matching
    /// the web comment exactly. A LATE upgrade — an empty fleet mounts the
    /// flow the instant state arrives, which can be BEFORE `/v1/license`
    /// answers, so `tour` starts false on a perfectly normal unlicensed
    /// build — resets to the wall: the ladder just gained its education
    /// screens and the user has been looking at the accounts step for the
    /// length of a fetch, so start at the beginning rather than dropping
    /// them into the middle.
    func updateTour(_ newValue: Bool) {
        guard newValue, !tour else { return }
        tour = true
        phase = .wall
    }

    /// Audit 2026-08-11 — the reason ② exists at all. The count may settle
    /// ONLY while the user is still on ① (`.wall`): detection answers
    /// within the wall's own ~1.4 s beat, so in practice the dots adjust in
    /// the first moments of the first screen — while past ① the ladder is
    /// committed and a late answer must not rewrite the dots (or mount/
    /// unmount ②) under the user, which is what the freeze was FOR. A flow
    /// without a tour has no ② either way, and `updateTour`'s reset back to
    /// `.wall` deliberately reopens this window along with the rest of the
    /// ladder.
    func updateIdentityCount(_ newValue: Int) {
        guard phase == .wall, newValue != identityCount else { return }
        identityCount = newValue
    }

    /// Onboarding.tsx:82-88 — ② (`.blind`) is SKIPPED entirely (not
    /// replaced by another wall-warning screen) when this machine has
    /// fewer than two distinct identities: a solo account has nothing for
    /// an "available inventory" screen to reveal, and the ladder's step
    /// total/dot count shrink accordingly rather than reserving a slot for
    /// a screen that won't render (design critique 2026-08-09).
    var phases: [OnboardingPhase] {
        var p: [OnboardingPhase] = []
        if tour { p.append(.wall) }
        if tour, identityCount >= 2 { p.append(.blind) }
        if startedEmpty { p.append(.accounts) }
        if tour { p.append(contentsOf: [.switchDemo, .windows]) }
        return p
    }

    /// Onboarding.tsx:131 — the step-dots total (the ask's own 4 steps are
    /// added on top of the education/accounts phases).
    var total: Int { phases.count + (tour ? 4 : 0) }

    /// Onboarding.tsx:132 `stepOf`.
    func stepOf(_ p: OnboardingPhase) -> Int? {
        phases.firstIndex(of: p)
    }

    /// Onboarding.tsx:133-139 — "ask" is never a member of `phases`, so an
    /// unguarded `indexOf(-1)` fallback would select `phases[0]` and send
    /// the user back to screen ① — a loop with no exit now that the
    /// corridor has removed the per-screen ✕. This makes that fallback
    /// explicit rather than accidental.
    func advance() {
        guard let i = phases.firstIndex(of: phase) else {
            phase = .ask
            return
        }
        phase = (i + 1 < phases.count) ? phases[i + 1] : .ask
    }

    /// Onboarding.tsx:163-176.
    var accountsForward: AccountsForwardAction { tour ? .advance : .exit }

    /// Onboarding.tsx:122-129 — the ask must survive a transient license
    /// failure: `useLicense` nulls the license on any failed fetch, and it
    /// refetches exactly during checkout activation. Without this, a null
    /// here rendered a fully blank window behind the suppressed toolbar
    /// (reviewer P0) — the last known license carries the ask screen
    /// through the gap. Call this with the CURRENT license on every update;
    /// it remembers the last non-nil one internally.
    func resolvedLicense(_ current: LicenseInfo?) -> LicenseInfo? {
        if let current { lastLicense = current }
        return current ?? lastLicense
    }

    /// Onboarding.tsx:101-115 — case-INSENSITIVE dedupe, first spelling
    /// seen wins: the fleet and `.claude.json` can disagree on casing for
    /// one person, and a raw case-sensitive dedupe would count them twice —
    /// announcing a second account that doesn't exist. Distinct from
    /// `LadderLogic.groupByEmail` (FirstRun.tsx), which is case-SENSITIVE —
    /// ground truth, not a typo; see that function's doc comment.
    static func identities(accounts: [AccountState], detected: [DetectedDir]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        let emails = accounts.map(\.email) + detected.filter { $0.signedIn != false }.map(\.email)
        for email in emails {
            guard !email.isEmpty else { continue }
            let key = email.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            out.append(email)
        }
        return out
    }

    /// SwitchDemo.tsx `demoLanes`' null-guard: the switch story needs two
    /// GENUINE (distinct, non-empty email) accounts.
    static func demoLanesAvailable(_ accounts: [AccountState]) -> Bool {
        var seen = Set<String>()
        for a in accounts where !a.email.isEmpty {
            seen.insert(a.email)
        }
        return seen.count >= 2
    }

    /// Onboarding.tsx:117-121,210-218 — the switch demo's lane SOURCE
    /// freezes on first need (a live SSE push must not re-derive it and
    /// restart the loop before it ever reaches the switch): real fleet
    /// lanes when the fleet holds ≥2 genuine accounts at that moment, else
    /// the masked fixture pair, decided ONCE and cached from then on.
    func resolvedMasked(accounts: [AccountState]) -> Bool {
        if let cachedMasked { return cachedMasked }
        let masked = !OnboardingModel.demoLanesAvailable(accounts)
        cachedMasked = masked
        return masked
    }
}
