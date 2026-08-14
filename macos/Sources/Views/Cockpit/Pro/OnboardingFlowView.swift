import SwiftUI

// Native CHROME for OnboardingModel.swift (web/src/pro/Onboarding.tsx's
// phase machine): progress dots, phase sequencing, the accounts/detection
// step, and the exit paths. wall/blind/switchDemo/windows are EDUCATION
// SCREENS, ported by a sibling Pro/ builder onto WallScreen/BlindSpotScreen/
// WindowsScreenView.swift (EducationViews.swift/WindowsScreenView.swift) and
// SwitchDemoView.swift — Phase 4 chunk 4E (integration) wires them in here,
// replacing the placeholder this file used to render in their place.
// Reduced motion is honored for free: every one of those screens already
// reads `@Environment(\.accessibilityReduceMotion)` internally.
//
// DEVIATION (brief-directed, see this chunk's report): FirstRun.tsx's
// accounts step does its OWN fetchDetected()/adoptAccount() orchestration
// inline (checkbox multi-add, per-row busy/error state). OnboardingModel
// carries no API reference and no such state machine, and this chunk's
// brief directs a different native shape for the accounts step instead:
// grouped identities read-only (LadderLogic.groupByEmail/sessionPercent)
// plus a single "Add account" entry point that hands off to the ALREADY-
// BUILT native AddAccountSheet via a callback closure — never presented by
// this file. See `OnboardingAccountsStepView`.

/// Onboarding.tsx's phase → screen selection, pulled out as a pure,
/// directly-testable function (mirrors `PaywallDots.position`/
/// `PriceBottomControl.resolve` in PaywallViews.swift). `.ask` resolves to
/// `.askFallback` exactly when the caller has no `AskMachine` yet — the
/// no-license-at-all gap Onboarding.tsx:210-218 falls through to, which the
/// web renders as the switch-demo education screen.
enum OnboardingRenderKind: Equatable {
    case educationSlot(phase: String)
    case accounts
    case ask
    case askFallback

    static func resolve(phase: OnboardingPhase, hasAsk: Bool) -> OnboardingRenderKind {
        switch phase {
        case .wall: return .educationSlot(phase: "wall")
        case .blind: return .educationSlot(phase: "blind")
        case .switchDemo: return .educationSlot(phase: "switch")
        case .windows: return .educationSlot(phase: "windows")
        case .accounts: return .accounts
        case .ask: return hasAsk ? .ask : .askFallback
        }
    }
}

/// FirstRun.tsx's `continueLabel` prop (FirstRun.tsx:78, wired from
/// Onboarding.tsx:168): "Continue" with a tour ahead, "Open the cockpit"
/// when the accounts step is the whole flow.
enum OnboardingAccountsCopy {
    static func continueLabel(tour: Bool) -> String { tour ? "Continue" : "Open the cockpit" }

    /// design critique 2026-08-09 — the accounts step used to open with
    /// "Let's find yours.", which contradicted the very next line once
    /// detection actually landed (the app has already found them by then).
    /// States the outcome instead, pulled out as a pure function so a test
    /// pins every detection state without mounting a view.
    static func headline(detected: [DetectedDir]?, groupCount: Int) -> String {
        guard detected != nil else { return "Finding your accounts…" }
        // The zero case used to report "No signed-in accounts found." — a
        // dead end that stated a negative and asked for nothing, and which
        // the lede below then flatly contradicted ("Add the ones you
        // want…" when there are no ones). Name the ACTION instead; the
        // hint under it still explains where accounts come from.
        if groupCount == 0 { return "Add your Claude account." }
        return groupCount == 1 ? "We found 1 account." : "We found \(groupCount) accounts."
    }

    /// The lede has to track the headline's state — a single fixed line
    /// ("Add the ones you want llmpilot to watch live.") referred to "the
    /// ones" on a screen that had just said it found none.
    static func lede(detected: [DetectedDir]?, groupCount: Int) -> String {
        guard detected != nil else { return "Checking this Mac for signed-in Claude accounts." }
        if groupCount == 0 {
            return "Sign in once. llmpilot watches its limits live and moves you before you hit the wall."
        }
        // Detected accounts are adopted automatically (owner 2026-08-11),
        // so the copy states that rather than asking for an action the
        // screen no longer requires.
        return "Signed in on this Mac — llmpilot is adding them and will watch their limits live."
    }

    /// The corridor's view of /v1/detect — dirs whose sign-in is actually
    /// USABLE. A folder that kept its `oauthAccount` block after its
    /// credential aged out ("phantom sign-in", the exact state 1.2.6 taught
    /// the app to stop offering) must not be listed as a found account here:
    /// the web source filtered these at fetch time (FirstRun.tsx:104
    /// `signed_in !== false`), and the native port had lost that filter —
    /// listing dead folders as "We found N accounts." and then auto-adopting
    /// them into a raw engine refusal. `nil` (still detecting) passes
    /// through; a REGISTERED dir stays listed on purpose — auto-adoption
    /// registers rows while this screen is up, and web-style `!registered`
    /// filtering would make them vanish mid-screen. Signed-out folders keep
    /// their remedy in the Add-account sheet, same as the web.
    static func corridorCandidates(_ detected: [DetectedDir]?) -> [DetectedDir]? {
        detected.map { dirs in dirs.filter { $0.signedIn != false } }
    }

    /// Which detected config dirs still need registering. Pure, so the
    /// filter that decides what automatic adoption touches is pinned by a
    /// test rather than living only inside a view's lifecycle: an
    /// already-registered dir must never be adopted twice, a nil
    /// (still-detecting) answer must adopt nothing at all, and a SIGNED-OUT
    /// dir must never be adopted — the engine can only refuse it ("no
    /// credential in Keychain service …"), and that refusal used to surface
    /// nowhere until the board's flash banner after the corridor closed.
    static func dirsToAdopt(_ detected: [DetectedDir]?) -> [String] {
        (corridorCandidates(detected) ?? []).filter { !$0.registered }.map(\.configDir)
    }

    /// design critique 2026-08-09 — a group's raw config-dir path is an
    /// implementation detail (can be long/identifying) EXCEPT the one case
    /// it genuinely disambiguates: another group in the same list reading
    /// as the same email at a glance. `LadderLogic.groupByEmail`'s
    /// case-SENSITIVE dedupe is the only way two such rows can coexist.
    static func rowIsAmbiguous(_ email: String, among groups: [EmailGroup]) -> Bool {
        groups.filter { $0.email.lowercased() == email.lowercased() }.count > 1
    }

    /// VOICE.md register — what happened, then what to do next; never the
    /// engine's raw refusal (that message names Keychain services).
    static func adoptFailureLine(_ count: Int) -> String {
        count == 1
            ? "1 account could not be added — open Add account to finish setting it up."
            : "\(count) accounts could not be added — open Add account to finish setting them up."
    }

    // MARK: ③-empty content (owner 2026-08-13)
    // The deleted Terminal hint (owner 2026-08-12) left the corridor's
    // sparsest screen a bare headline over a ~350pt void. What fills it
    // answers the two questions a user actually has with "Add account"
    // under their finger: what happens when I press this, and is it safe
    // to hand this app my account.

    /// What pressing "Add account" does, in order. The third step's "here"
    /// points at the example lane rendered directly beneath the list.
    static let emptySteps = [
        "Sign in with your browser",
        "llmpilot adds the account to your fleet",
        "Its limit bars go live here in seconds",
    ]

    /// The example lane's identity — ④'s masked demo persona, reused so
    /// the corridor doesn't invent a second fake-identity vocabulary.
    static let emptyExampleEmail = "kai@example.dev"

    /// ④/⑤'s trust discipline (audit 2026-08-11): fabricated numbers never
    /// render without saying so. Not `EducationMath.exampleNote` — its
    /// "your live ones are on the board" tail refers to accounts this
    /// screen exists because the user doesn't have yet.
    static let emptyExampleNote = "Example — an added account renders like this."

    /// Both claims hold by the daemon's own rules: credentials live in the
    /// login Keychain and are only ever presented to Anthropic's endpoints,
    /// and the app ships no telemetry. Deliberately NOT "nothing leaves
    /// this Mac" — the licensing worker, Sparkle, and checkout are real
    /// network surfaces, just never ones that see the credential.
    static let emptyTrustLine =
        "Your sign-in stays in your Mac's Keychain — only Anthropic ever sees it. No telemetry."
}

/// ③'s zero-accounts body (owner 2026-08-13, walk-A feedback): three steps
/// stating what the primary button does, one masked example lane showing
/// the outcome (disclosed as an example — ④/⑤'s trust discipline), then
/// the Keychain fact, nearest the button where the hesitation peaks.
private struct OnboardingEmptyAccountsView: View {
    @State private var reset = EducationMath.futureInstant(hoursFromNow: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(OnboardingAccountsCopy.emptySteps.enumerated()), id: \.offset) { i, step in
                    HStack(alignment: .center, spacing: 10) {
                        Text("\(i + 1)")
                            .font(CockpitTheme.numeric(11, weight: .semibold))
                            .foregroundColor(CockpitTheme.sec)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(CockpitTheme.panel))
                            .overlay(Circle().stroke(CockpitTheme.hairSoft, lineWidth: 1))
                        Text(step)
                            .font(CockpitTheme.Onboarding.body)
                            .foregroundColor(CockpitTheme.text)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("onboarding-empty-steps")

            EduDemoLane(
                id: OnboardingAccountsCopy.emptyExampleEmail,
                email: OnboardingAccountsCopy.emptyExampleEmail,
                badge: nil,
                status: "Signed in",
                statusTone: .idle
            ) {
                VStack(alignment: .leading, spacing: 5) {
                    // Calm-band percents on purpose: the example shows the
                    // steady state the user is buying, not ①'s crisis.
                    CockpitRunwayBar(bucket: eduSessionBucket(percent: 41, resetsAt: reset), refAsOf: reset, stale: false)
                    CockpitRunwayBar(bucket: eduWeeklyBucket(percent: 18), refAsOf: reset, stale: false)
                }
                .padding(.top, 2)
            }
            .padding(.top, FlowLayout.ledeToVisual)
            .accessibilityIdentifier("onboarding-empty-example")

            Text(OnboardingAccountsCopy.emptyExampleNote)
                .font(CockpitTheme.Onboarding.annotation)
                .lineSpacing(CockpitTheme.Onboarding.annotationLineSpacing)
                .foregroundColor(CockpitTheme.ter)
                .padding(.top, FlowLayout.visualToDisclosure)

            Text(OnboardingAccountsCopy.emptyTrustLine)
                .font(CockpitTheme.Onboarding.body)
                .lineSpacing(CockpitTheme.Onboarding.bodyLineSpacing)
                .foregroundColor(CockpitTheme.sec)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, FlowLayout.disclosureToClosing)
                .accessibilityIdentifier("onboarding-empty-trust")
        }
        .frame(maxWidth: FlowLayout.copyColumnMaxWidth, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding-accounts-empty")
    }
}

/// Onboarding.tsx:219-241 — the switch-demo section, reached both as the
/// real ④ phase AND as the fallback for an "ask" phase with no `AskMachine`
/// at all (Onboarding.tsx:210-218 — no license has resolved yet). Its own
/// small VStack rather than `EducationFrame` (Education.tsx's three
/// screens): the source gives this section a bespoke layout with no
/// `example`/`note` slots, and its Continue button routes to EITHER
/// `advance` or `onExit` depending on which case reached it — forcing it
/// through `EducationFrame`'s fixed slot shape would be a false
/// unification.
struct OnboardingSwitchStepView: View {
    let step: Int
    let total: Int
    let state: DaemonState
    let continueLabel: String
    let onContinue: () -> Void

    @State private var lanes: [EduLane]
    @State private var masked: Bool

    init(step: Int, total: Int, state: DaemonState, continueLabel: String, onContinue: @escaping () -> Void) {
        self.step = step
        self.total = total
        self.state = state
        self.continueLabel = continueLabel
        self.onContinue = onContinue
        // Onboarding.tsx:212-218 — frozen on first need: a live SSE push
        // must not re-derive the lane pair and restart the loop before it
        // ever reaches the switch. `@State`'s `State(initialValue:)` runs
        // once per view identity, exactly matching the source's
        // `useRef(null)`-guarded one-time freeze.
        let real = eduDemoLanes(state)
        _lanes = State(initialValue: real ?? eduMaskedLanes)
        _masked = State(initialValue: real == nil)
    }

    var body: some View {
        OnboardingStage(position: StepPosition(step: step, total: total)) {
            VStack(alignment: .leading, spacing: 0) {
                // Emphasis is WEIGHT, not the reserved accent blue
                // (design/DESIGN-SYSTEM.md: blue = booked/charging +
                // actions only — design critique 2026-08-09).
                (Text("It moves you ").font(CockpitTheme.Onboarding.headline)
                    + Text("before").font(CockpitTheme.Onboarding.headlineEmphasis)
                    + Text(" you hit the wall.").font(CockpitTheme.Onboarding.headline))
                    .tracking(CockpitTheme.Onboarding.headlineTracking)
                    .lineSpacing(CockpitTheme.Onboarding.headlineLineSpacing)
                    .foregroundColor(CockpitTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Watch it happen on \(masked ? "a demo fleet" : "your own accounts"). Nothing switches until you turn it on.")
                    .font(CockpitTheme.Onboarding.lede)
                    .lineSpacing(CockpitTheme.Onboarding.ledeLineSpacing)
                    .foregroundColor(CockpitTheme.sec)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, FlowLayout.headlineToLede)
                SwitchDemoView(lanes: lanes)
                    .padding(.top, FlowLayout.ledeToVisual)
                // Audit 2026-08-11: lane A's 71→97% is a fixed narrative
                // device (SwitchDemoModel.startPercent), shown beside REAL
                // emails on a real fleet — the same fabricated-beside-real
                // trust bug ⑤ was marked for. Disclose on BOTH variants
                // (①/⑤ already carry this note; ④ was the odd one out).
                Text(EducationMath.exampleNote)
                    .font(CockpitTheme.Onboarding.annotation)
                    .lineSpacing(CockpitTheme.Onboarding.annotationLineSpacing)
                    .foregroundColor(CockpitTheme.ter)
                    .padding(.top, FlowLayout.visualToDisclosure)
                Text("You keep working. It handles the accounts.")
                    .font(CockpitTheme.Onboarding.body)
                    .lineSpacing(CockpitTheme.Onboarding.bodyLineSpacing)
                    .foregroundColor(CockpitTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, FlowLayout.disclosureToClosing)
            }
        } footer: {
            HStack(spacing: FlowLayout.footerControlSpacing) {
                Spacer()
                Button(continueLabel, action: onContinue)
                    .pwPrimary()
                    .keyboardShortcut(.defaultAction) // Return advances (owner 2026-08-09)
                    // Same AX-stripping custom ButtonStyle as
                    // EducationChrome's Continue — same fix, same
                    // identifier (only one of the two is ever mounted at a
                    // time, so the shared identifier is unambiguous to the
                    // e2e AX walk).
                    .accessibilityIdentifier("edu-continue")
                    .accessibilityLabel(continueLabel)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding-switch-step")
    }
}

/// FirstRun.tsx's accounts step, in the native shape this chunk's brief
/// directs (see file header): a read-only, grouped identity list plus a
/// single "Add account" entry point, rather than FirstRun.tsx's own inline
/// multi-add orchestration.
struct OnboardingAccountsStepView: View {
    let accounts: [AccountState]
    /// `nil` while `/v1/detect` hasn't answered yet (FirstRun.tsx's
    /// `detected === null`) — supplied by the caller, which already owns an
    /// API reference (this view and OnboardingModel do not).
    let detected: [DetectedDir]?
    let position: StepPosition
    /// FirstRun.tsx's `continueLabel` prop: "Continue" with a tour ahead,
    /// "Open the cockpit" when the accounts step is the whole flow.
    let continueLabel: String
    var onAddAccount: () -> Void = {}
    var onContinue: () -> Void = {}
    /// Adopt every DETECTED-but-unregistered config dir (owner 2026-08-11:
    /// "can't we make this an automatic detection thing"). Detection was
    /// already automatic — this screen has always LISTED what it found —
    /// but nothing ever adopted it, so a user whose accounts were all
    /// detected could finish onboarding with none of them registered and
    /// nothing being watched. Adopting is what this step is FOR.
    var onAdoptDetected: () -> Void = {}
    /// How many automatic adopts FAILED (audit 2026-08-11: the lede claims
    /// "llmpilot is adding them" and failures used to surface nowhere until
    /// the board's flash banner, raw engine message and all, after the
    /// corridor was already gone). Zero renders nothing.
    var adoptFailedCount = 0

    /// Fires the adopt exactly once, on whichever comes first: the step
    /// appearing with detection already answered, or detection answering
    /// while the step is on screen (`/v1/detect` has no upstream timeout,
    /// so `detected` starts nil). Keyed on there being something ADOPTABLE,
    /// not merely something detected — a phantom-only answer must not burn
    /// the one shot before a usable sign-in ever appears.
    @State private var adoptRequested = false

    /// Signed-in dirs only — see `OnboardingAccountsCopy.corridorCandidates`.
    private var candidates: [DetectedDir]? { OnboardingAccountsCopy.corridorCandidates(detected) }

    @Environment(\.colorScheme) private var colorScheme

    private var groups: [EmailGroup] { LadderLogic.groupByEmail(candidates ?? []) }

    private func adoptDetectedOnce() {
        guard !adoptRequested, !OnboardingAccountsCopy.dirsToAdopt(detected).isEmpty else { return }
        adoptRequested = true
        onAdoptDetected()
    }

    /// Tabular via `CockpitTheme.Onboarding.headline`. Logic lives in
    /// `OnboardingAccountsCopy.headline` — pure, directly-testable.
    private var headline: String {
        OnboardingAccountsCopy.headline(detected: candidates, groupCount: groups.count)
    }

    private func isAmbiguous(_ g: EmailGroup) -> Bool {
        OnboardingAccountsCopy.rowIsAmbiguous(g.email, among: groups)
    }

    var body: some View {
        OnboardingStage(position: position) {
            VStack(alignment: .leading, spacing: 0) {
                Text(headline)
                    .font(CockpitTheme.Onboarding.headline)
                    .tracking(CockpitTheme.Onboarding.headlineTracking)
                    .lineSpacing(CockpitTheme.Onboarding.headlineLineSpacing)
                    .foregroundColor(CockpitTheme.text)
                    .accessibilityIdentifier("onboarding-accounts-heading")
                // The list below is READ-ONLY (design critique 2026-08-09)
                // — "Add them" used to imply the rows themselves were the
                // control; the actual add path is the separate button.
                Text(OnboardingAccountsCopy.lede(detected: candidates, groupCount: groups.count))
                    .font(CockpitTheme.Onboarding.lede)
                    .lineSpacing(CockpitTheme.Onboarding.ledeLineSpacing)
                    .foregroundColor(CockpitTheme.sec)
                    .padding(.top, FlowLayout.headlineToLede)
                content
                    .padding(.top, FlowLayout.ledeToVisual)
            }
        } footer: {
            HStack(spacing: FlowLayout.footerControlSpacing) {
                Spacer()
                // FirstRun.tsx:222 — the Continue/"Add" button only renders
                // once there IS something on screen; with zero groups it is
                // replaced entirely by the skip link, never shown beside it.
                if !groups.isEmpty {
                    Button(continueLabel, action: onContinue)
                        .pwPrimary()
                        .keyboardShortcut(.defaultAction) // Return advances (owner 2026-08-09)
                        .accessibilityIdentifier("onboarding-continue")
                } else {
                    // Plain `else`, NOT `else if detected != nil` (review
                    // 2026-08-11 NEW-1): the still-detecting state renders
                    // through here too, and a screen with no controls must
                    // not be able to exist — one slow or failed first
                    // /v1/detect would otherwise strand the user on a
                    // button-less corridor (the web's own guard:
                    // FirstRun.tsx:96-99, "the loading frame has no
                    // controls, so it must not be able to last").
                    // FirstRun.tsx:252-259 — the zero-detected state's other
                    // forward path (a failed add's error path is out of
                    // scope here: this view never adds inline, so there is
                    // no per-row error to gate on). Ghost/secondary — the
                    // primary action in this state is "Add account", in
                    // Zero detected: ADDING is the recommended action, so it
                    // takes the primary slot AND Return (owner 2026-08-10).
                    // Return used to fire the skip — a user walking the
                    // corridor on the keyboard skipped account setup with
                    // the same key that advanced every other screen. The
                    // postponement is also named as one: "Skip account
                    // setup" read as skipping a settings step rather than
                    // "not now", which is what it actually does.
                    Button("I'll do this later", action: onContinue)
                        .pwGhost()
                        .accessibilityIdentifier("onboarding-skip")
                    Button("Add account", action: onAddAccount)
                        .pwPrimary()
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("onboarding-add-account")
                }
            }
        }
        .onAppear { adoptDetectedOnce() }
        // Keyed on the ADOPTABLE set, not the array's length (review
        // 2026-08-11 P2-4): a same-length recomposition — e.g. a phantom
        // folder signed into again — changes what there is to adopt without
        // changing the count, and the count key would sleep through it.
        .onChange(of: OnboardingAccountsCopy.dirsToAdopt(detected)) { _ in adoptDetectedOnce() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding-accounts-screen")
    }

    @ViewBuilder
    private var content: some View {
        if detected == nil {
            Text("Looking for signed-in accounts…")
                .font(CockpitTheme.Onboarding.body)
                .foregroundColor(CockpitTheme.ter)
        } else if groups.isEmpty {
            // Owner 2026-08-13 (walk-A): the bare state that replaced the
            // deleted Terminal hint (owner 2026-08-12 — CLI mentions
            // confuse users) overshot into a ~350pt void. This block keeps
            // the no-CLI rule and fills the slot with the mechanism, an
            // example outcome, and the trust fact.
            OnboardingEmptyAccountsView()
        } else {
            VStack(spacing: 0) {
                ForEach(Array(groups.enumerated()), id: \.element.email) { i, g in
                    row(for: g)
                    // No divider trailing the LAST row (design critique
                    // 2026-08-09) — dividers separate rows, they don't cap
                    // the list.
                    if i < groups.count - 1 {
                        Divider().overlay(CockpitTheme.hairSoft)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("onboarding-accounts-list")

            // Automatic adoption's failure surface (audit 2026-08-11): the
            // lede above claims accounts are being added, so a refused add
            // must say so HERE, in plain words with the remedy — not as a
            // raw engine message on the board after the corridor is gone.
            if adoptFailedCount > 0 {
                Text(OnboardingAccountsCopy.adoptFailureLine(adoptFailedCount))
                    .font(CockpitTheme.Onboarding.status)
                    .lineSpacing(CockpitTheme.Onboarding.statusLineSpacing)
                    .foregroundColor(CockpitTheme.sec)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .background(CockpitTheme.panel)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(CockpitTheme.hair, lineWidth: 1))
                    .frame(maxWidth: FlowLayout.copyColumnMaxWidth, alignment: .leading)
                    .padding(.top, FlowLayout.visualToDisclosure)
                    .accessibilityIdentifier("onboarding-adopt-failed")
            }

            // Ghost/secondary here — the footer's Continue is the one
            // primary action once accounts are already on screen (design
            // critique 2026-08-09: never two primary-styled buttons at once).
            Button("Add account", action: onAddAccount)
                .pwGhost()
                .accessibilityIdentifier("onboarding-add-account")
        }
    }

    private func row(for g: EmailGroup) -> some View {
        // A non-nil percent means the identity is IN the fleet — for this
        // screen that IS the "it was added" signal (audit 2026-08-11: a bare
        // trailing "0%" was the only confirmation automatic adoption ever
        // gave, and it read as noise, not an outcome). Green is meaning
        // here — guaranteed/registered — not decoration.
        let pct = LadderLogic.sessionPercent(accounts: accounts, group: g)
        return HStack(alignment: .center, spacing: 10) {
            // Same avatar disc as the blind-spot inventory's lanes
            // (EduDemoLane) — adjacent screens shouldn't speak two identity
            // grammars for the same accounts.
            Circle()
                .fill(avatarColor(id: g.email, dark: colorScheme == .dark))
                .frame(width: 26, height: 26)
                .overlay(
                    Text(String((g.email.first.map(String.init) ?? "?")).uppercased())
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(g.email).font(CockpitTheme.Onboarding.controlLabel)
                if isAmbiguous(g) {
                    Text(g.dirs.map(\.configDir).joined(separator: " · "))
                        .font(CockpitTheme.Onboarding.annotation)
                        .foregroundColor(CockpitTheme.ter)
                }
            }
            Spacer()
            if let pct {
                Text(pct > 0 ? "Added · \(pct)%" : "Added")
                    .font(CockpitTheme.numeric(11, weight: .semibold))
                    .foregroundColor(CockpitTheme.okTx)
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("onboarding-account-row-\(g.email)")
    }
}

/// Top-level onboarding chrome: `OnboardingModel.phase` selects the screen,
/// exactly as `Onboarding.tsx`'s own if-chain does.
struct OnboardingFlowView: View {
    @ObservedObject var model: OnboardingModel
    let accounts: [AccountState]
    let detected: [DetectedDir]?
    /// Live daemon state — WallScreen/WindowsScreen's identity line and the
    /// switch-demo step's lane derivation need it (`OnboardingSwitchStepView`
    /// freezes its OWN copy the first time it renders, mirroring
    /// Onboarding.tsx's `frozenLanes` ref).
    let state: DaemonState
    /// Built by the caller once a license has FIRST resolved
    /// (`OnboardingModel.resolvedLicense`), and kept alive across
    /// re-renders — AskMachine owns its own progress (declined/stage/etc.),
    /// so the caller must not replace the instance on every render. `nil`
    /// only in the gap before any license has ever answered —
    /// Onboarding.tsx's own fallback for that gap (Onboarding.tsx:210-218)
    /// is ITSELF the switch-demo education screen, so it renders through
    /// the same placeholder as `.switchDemo`.
    let ask: AskMachine?
    var onAddAccount: () -> Void = {}
    /// Passed through to the accounts step — see its own doc comment.
    var onAdoptDetected: () -> Void = {}
    /// Passed through to the accounts step — its adopt-failure callout.
    var adoptFailedCount = 0
    var onExit: () -> Void = {}
    var onRecover: () -> Void = {}
    var quoteFailed = false
    var onRetryQuote: (() -> Void)? = nil
    var onCheckoutHandoff: (URL) -> Void = { _ in }
    /// Passed through to the ask's ⑨ (owner 2026-08-12, layer 1).
    var watchOnly: [WatchOnlyLane] = []
    var activationMove: ActivationMoveModel? = nil

    var body: some View {
        switch OnboardingRenderKind.resolve(phase: model.phase, hasAsk: ask != nil) {
        case .educationSlot(let phase):
            educationScreen(phase)
        case .accounts:
            OnboardingAccountsStepView(
                accounts: accounts, detected: detected,
                position: StepPosition(step: model.stepOf(.accounts) ?? 0, total: model.total),
                continueLabel: OnboardingAccountsCopy.continueLabel(tour: model.tour),
                onAddAccount: onAddAccount,
                onContinue: { model.accountsForward == .advance ? model.advance() : onExit() },
                onAdoptDetected: onAdoptDetected,
                adoptFailedCount: adoptFailedCount)
        case .ask:
            PaywallView(
                ask: ask!, dots: PaywallDots(base: model.phases.count, total: model.total),
                quoteFailed: quoteFailed, onRetryQuote: onRetryQuote, onRecover: onRecover,
                onCheckoutHandoff: onCheckoutHandoff,
                watchOnly: watchOnly, activationMove: activationMove)
        case .askFallback:
            // Onboarding.tsx:210-218's fallback — the ask has no license at
            // all yet. Reached through the SAME switch-demo section as the
            // real ④ phase (it is that screen, web-side), whose Continue
            // routes to `onExit` here (there is no ask to advance TO).
            OnboardingSwitchStepView(
                step: model.stepOf(.switchDemo) ?? max(model.total - 1, 0), total: model.total,
                state: state, continueLabel: "Open the cockpit", onContinue: onExit)
        }
    }

    /// Onboarding.tsx:141-187 — the four education phases. ①/②/⑤ are each a
    /// shipped `EducationFrame` screen; ④ is `OnboardingSwitchStepView`
    /// above.
    @ViewBuilder
    private func educationScreen(_ phase: String) -> some View {
        let identities = OnboardingModel.identities(accounts: accounts, detected: detected ?? [])
        switch phase {
        case "wall":
            WallScreen(
                step: model.stepOf(.wall) ?? 0, total: model.total,
                email: identities.first, onContinue: model.advance)
        case "blind":
            // Tier per email from the same detect answer the identities came
            // from — first spelling wins, matching identities()' own dedupe.
            BlindSpotScreen(
                step: model.stepOf(.blind) ?? 0, total: model.total,
                emails: identities,
                tiers: (detected ?? []).reduce(into: [String: String]()) { acc, d in
                    if d.signedIn != false, let tier = d.tier, acc[d.email] == nil {
                        acc[d.email] = tier
                    }
                },
                onContinue: model.advance)
        case "switch":
            // VOICE.md: buttons are verb+object — the real ④ phase's next
            // step is ⑤ (design critique 2026-08-09). The askFallback case
            // above keeps "Open the cockpit": there is no ⑤ to advance to
            // from there.
            OnboardingSwitchStepView(
                step: model.stepOf(.switchDemo) ?? 0, total: model.total,
                state: state, continueLabel: "See your fresh windows", onContinue: model.advance)
        case "windows":
            WindowsScreen(
                step: model.stepOf(.windows) ?? 0, total: model.total,
                email: identities.first, onContinue: model.advance)
        default:
            EmptyView()
        }
    }
}
