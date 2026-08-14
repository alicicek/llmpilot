import SwiftUI

// Native port of web/src/pro/Education.tsx's three exported screens — ①
// WallScreen, ② BlindSpotScreen, ⑤ WindowsScreen. Every screen is built
// from already-shipped native cockpit pieces (`CockpitRunwayBar`,
// `avatarColor` — both FleetLanesView.swift, untouched) exactly as the
// source insists the web side is: "the real RunwayBar computes its own
// severity from the percent we animate... not because this file picked a
// colour." Each screen re-mounts its beat model whenever reduced motion
// flips (`.id(reduceMotion)`), mirroring the source effect's `[reduced]`
// dependency array tearing down and re-running from scratch.

// internal (not `private`/`fileprivate`): also used by
// WindowsScreenView.swift's ⑤ header bar.
func eduSessionBucket(percent: Int, resetsAt: Date) -> Bucket {
    Bucket(kind: "session", scope: nil, percent: Double(percent), resetsAt: resetsAt, severity: nil, active: true)
}

func eduWeeklyBucket(percent: Int) -> Bucket {
    Bucket(kind: "weekly_all", scope: nil, percent: Double(percent), resetsAt: nil, severity: nil, active: nil)
}

// MARK: - ① THE WALL

struct WallScreen: View {
    let step: Int
    let total: Int
    /// The user's own first identity when one is known — this is their
    /// app, and a placeholder address on the opening screen reads like a
    /// brochure.
    var email: String?
    let onContinue: () -> Void
    var clock: EduClock = SystemEduClock()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        WallScreenBody(step: step, total: total, email: email, reducedMotion: reduceMotion, clock: clock, onContinue: onContinue)
            .id(reduceMotion)
    }
}

private struct WallScreenBody: View {
    let step: Int
    let total: Int
    let email: String?
    let reducedMotion: Bool
    let clock: EduClock
    let onContinue: () -> Void

    @StateObject private var beat: WallBeatModel
    @State private var reset: Date

    init(step: Int, total: Int, email: String?, reducedMotion: Bool, clock: EduClock, onContinue: @escaping () -> Void) {
        self.step = step
        self.total = total
        self.email = email
        self.reducedMotion = reducedMotion
        self.clock = clock
        self.onContinue = onContinue
        _beat = StateObject(wrappedValue: WallBeatModel(reducedMotion: reducedMotion, clock: clock))
        _reset = State(initialValue: EducationMath.futureInstant(hoursFromNow: 3))
    }

    var body: some View {
        EducationFrame(
            step: step, total: total,
            headline: "You know ", keyPhrase: "this moment", tail: ".",
            lede: "Deep in a refactor. Claude has the whole thing in its head. And then it stops.",
            example: true,
            note: "Five hours of waiting. Or another login, and your place is gone.",
            continueLabel: "See account headroom",
            onContinue: onContinue
        ) {
            VStack(alignment: .leading, spacing: 6) {
                EduDemoLane(
                    id: email ?? "demo-one",
                    email: email ?? "Your Claude account",
                    badge: .active,
                    // No "— resets HH:MM" here (audit 2026-08-11): the bar's
                    // own caption states it and the spent toast repeats it —
                    // three copies of one fact on a single screen.
                    status: beat.spent ? "Spent" : "Mid-window",
                    statusTone: beat.spent ? .crit : .warn
                ) {
                    VStack(alignment: .leading, spacing: 5) {
                        CockpitRunwayBar(bucket: eduSessionBucket(percent: beat.percent, resetsAt: reset), refAsOf: reset, stale: false)
                            // The beat publishes 71→100 as ONE jump; this is
                            // what turns that jump into the "smooth fill"
                            // the brief asks for — a single 900ms animation,
                            // not 34ms steps (WallBeatModel.fillMs).
                            .animation(.easeInOut(duration: Double(WallBeatModel.fillMs) / 1000), value: beat.percent)
                        CockpitRunwayBar(bucket: eduWeeklyBucket(percent: 34), refAsOf: reset, stale: false)
                    }
                    .padding(.top, 2)
                }
                .accessibilityIdentifier("edu-wall-lanes")

                HStack(spacing: 8) {
                    Circle().fill(CockpitTheme.crit).frame(width: 7, height: 7)
                    Text("Usage limit reached · resets \(EducationMath.hhmm(reset))")
                }
                .font(CockpitTheme.Onboarding.status)
                .foregroundColor(CockpitTheme.hudTx)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 9).fill(CockpitTheme.hudBg))
                .opacity(beat.spent ? 1 : 0)
                // Fades AND moves 4pt (design critique 2026-08-09) over
                // 180ms — was a 200ms fade with no movement.
                .offset(y: beat.spent ? 0 : 4)
                .animation(.easeInOut(duration: 0.18), value: beat.spent)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("edu-wall-toast")
            }
            .padding(.top, 22)
        }
        .onAppear { beat.start() }
        .onDisappear { beat.stop() }
    }
}

// MARK: - ② THE BLIND SPOT

// Design critique 2026-08-09: this screen's ONE job is to reveal the
// available account INVENTORY — it used to duplicate ④'s own grammar (two
// accounts, usage bars, an ACTIVE badge, a static blue "SWITCH" capsule
// that looked like a control and wasn't) and gave away ④'s payoff before
// ④ ever ran. Redesigned as a plain, honest identity list: avatar, email,
// "Signed in" — no bars, no badges, no false affordances. `OnboardingModel.
// phases` (OnboardingModel.swift) now SKIPS this screen entirely on a
// machine with fewer than two distinct identities — there is no more
// "solo" variant here to substitute a wall-warning screen with; a caller
// only ever reaches this view with `emails.count >= 2`.

struct BlindSpotScreen: View {
    let step: Int
    let total: Int
    /// Every distinct Claude identity on this Mac: the fleet's accounts
    /// plus any signed-in folder not yet added. Callers only reach this
    /// screen once `OnboardingModel.phases` has already decided there are
    /// ≥2 — see that file's `identityCount` gate.
    let emails: [String]
    /// Subscription tier per email ("Max 20×", "Pro") when known — the
    /// daemon's claudecfg adapter maps the raw vocabulary; an absent entry
    /// shows nothing, never a guess (owner 2026-08-12).
    var tiers: [String: String] = [:]
    let onContinue: () -> Void
    var clock: EduClock = SystemEduClock()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var frozen: [String]

    init(step: Int, total: Int, emails: [String], tiers: [String: String] = [:], onContinue: @escaping () -> Void, clock: EduClock = SystemEduClock()) {
        self.step = step
        self.total = total
        self.emails = emails
        self.tiers = tiers
        self.onContinue = onContinue
        self.clock = clock
        _frozen = State(initialValue: emails)
    }

    var body: some View {
        BlindSpotScreenBody(
            step: step, total: total, emails: frozen, tiers: tiers,
            reducedMotion: reduceMotion, clock: clock, onContinue: onContinue
        )
        .id(reduceMotion)
        .onChange(of: emails) { newValue in
            // An EMPTY list is a pending answer, not an answer: /v1/detect
            // has no upstream timeout and starts empty, so freezing that
            // would permanently strand this screen with nothing to show.
            // Empty upgrades; anything else holds.
            if frozen.isEmpty, !newValue.isEmpty { frozen = newValue }
        }
    }
}

private struct BlindSpotScreenBody: View {
    let step: Int
    let total: Int
    let emails: [String]
    let tiers: [String: String]
    let reducedMotion: Bool
    let clock: EduClock
    let onContinue: () -> Void

    @StateObject private var beat: BlindSpotBeatModel

    init(step: Int, total: Int, emails: [String], tiers: [String: String], reducedMotion: Bool, clock: EduClock, onContinue: @escaping () -> Void) {
        self.step = step
        self.total = total
        self.emails = emails
        self.tiers = tiers
        self.reducedMotion = reducedMotion
        self.clock = clock
        self.onContinue = onContinue
        _beat = StateObject(wrappedValue: BlindSpotBeatModel(reducedMotion: reducedMotion, clock: clock))
    }

    /// "llmpilot can watch both from one place." generalized for 3+
    /// accounts — never hardcodes "second account" (brief).
    private var closingFact: String {
        emails.count == 2
            ? "llmpilot can watch both from one place."
            : "llmpilot can watch all \(emails.count) from one place."
    }

    private var revealFadeDuration: Double { Double(BlindSpotBeatModel.revealFadeMs) / 1000 }

    var body: some View {
        EducationFrame(
            step: step, total: total,
            headline: "You already have ", keyPhrase: "\(emails.count) accounts", tail: ".",
            lede: "Every one of these is signed in and ready — llmpilot already sees them all.",
            // NOT example (audit follow-up 2026-08-11, first live render of
            // this screen): the redesigned inventory lists the user's REAL
            // identities and shows no numbers at all — an "Example numbers"
            // disclaimer here disclaims nothing and undercuts the one claim
            // the screen exists to make.
            example: false,
            note: closingFact,
            continueLabel: "See how switching works",
            onContinue: onContinue
        ) {
            // 10pt between lanes (owner 2026-08-12: the 6pt stack read as
            // one clump with uneven air around it).
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(emails.enumerated()), id: \.offset) { i, email in
                    // EduDemoLane's own `revealed` transition is a fixed
                    // 500ms — always pass `true` (its default) and drive
                    // ONLY the extra identities' 350ms-pause/200ms-fade
                    // beat ourselves so the timing matches the brief
                    // exactly.
                    EduDemoLane(
                        id: email, email: email, badge: nil,
                        // The tier is a fact worth showing the moment the
                        // inventory is revealed ("Max 20×" is exactly why
                        // watching both matters) — absent when unknown.
                        status: tiers[email].map { "Signed in · \($0)" } ?? "Signed in",
                        statusTone: .idle
                    ) { EmptyView() }
                        .opacity(i == 0 ? 1 : (beat.revealed ? 1 : 0))
                        .animation(i == 0 ? nil : .easeInOut(duration: revealFadeDuration), value: beat.revealed)
                }
            }
            .padding(.top, 22)
            .accessibilityIdentifier("edu-blind-inventory")
        }
        .accessibilityIdentifier("edu-blind-pair")
        .onAppear { beat.start() }
        .onDisappear { beat.stop() }
    }
}

// ⑤ THE SCHEDULED WINDOW — WindowsScreen lives in WindowsScreenView.swift
// (this file's WallScreen + BlindSpotScreen were already close to the
// chunk's ~400-line guidance; the board reproduction pushed it over).
