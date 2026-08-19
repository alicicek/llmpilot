import Foundation

// Phase 4 chunk 4E (integration) — the composition-root logic
// NativeCockpitWindow.swift wires the ALREADY-BUILT money-path chunks
// (LadderLogic/OnboardingModel/AskMachine, the education/paywall screens,
// CheckoutSheet) through. Pulled into pure functions + two small models
// here, the same split this repo already uses (LadderLogic/OnboardingModel/
// AskMachine themselves), so the mount decision, the corridor flag, and the
// post-checkout reload sequence are directly testable without hosting a
// window.

/// App.tsx:268-279's pro-gating + first-run mount decision. Every input
/// here is something the caller (NativeCockpitWindow.swift) already reads
/// off `fleet.state`/`cockpit.license`/its own persisted flags — this only
/// reproduces the BOOLEAN ALGEBRA, matching App.tsx line-for-line.
enum ProFlowLogic {
    /// App.tsx:268 `firstRun` (the `state !== null` half is the caller's
    /// job: this is only ever called once a `DaemonState` exists).
    static func firstRun(accounts: [AccountState]) -> Bool { accounts.isEmpty }

    /// App.tsx:273-275 `showOnboarding` — the first-launch hard paywall: an
    /// official build (`available`), unlicensed (`!active`), status "none"
    /// (never lapsed/revoked — those are the honest-paused banner's job,
    /// not first-run), not already dismissed this Mac.
    static func showOnboarding(license: LicenseInfo?, onboarded: Bool) -> Bool {
        guard let license, license.available, !license.active else { return false }
        return license.status == "none" && !onboarded
    }

    /// App.tsx:278 `wantFlow` — one path during first run: the flow owns
    /// the screen from the accounts step through the activation facts.
    static func wantFlow(firstRun: Bool, flowClosed: Bool, showOnboarding: Bool) -> Bool {
        (firstRun && !flowClosed) || showOnboarding
    }

    /// App.tsx:279 `showFlow` — the latch holds the flow open through
    /// activation (`showOnboarding` flips false the instant `license.active`
    /// does) until an explicit close (`closeFlow`/`dismissOnboarding`).
    static func showFlow(wantFlow: Bool, flowLatched: Bool) -> Bool { wantFlow || flowLatched }

    /// Paywall.tsx:173 `guided = dots !== undefined` — which `AskMachine.
    /// guided` value a given open source uses. Only the first-run flow's
    /// embedded ask is guided (SPEC-127 D9's one-way corridor, ⑧'s ✕ its
    /// only door); every reopen trigger this chunk wires — the board's pro
    /// CTA, and Settings → License "Turn on the autopilot" (the paused/
    /// lapsed reopen path) — opens the STANDALONE, non-guided paywall,
    /// where every screen keeps its ✕. Named so a test can pin this mapping
    /// without touching the window-owning composition root.
    enum AskSource: Equatable {
        case firstRunFlow
        case reopenedPaywall
    }

    static func guided(for source: AskSource) -> Bool {
        switch source {
        case .firstRunFlow: return true
        case .reopenedPaywall: return false
        }
    }

    /// App.tsx:289-293 `caughtThisWeek` — switch/rotate events inside the
    /// last 7 days. `now` injected (App.tsx reads `Date.now()` per render).
    static func caughtThisWeek(events: [DaemonEvent], now: Date) -> Int {
        let cutoff = now.addingTimeInterval(-7 * 86_400)
        return events.filter { e in
            (e.kind == "switch" || e.kind == "rotate") && e.at > cutoff
        }.count
    }

    /// The fleet's watch-only lanes a freshly-activated buyer can promote
    /// (owner 2026-08-12, "layer 1"): pinned accounts whose folder still
    /// holds a usable sign-in. A CONFIRMED signed-out folder is excluded —
    /// offering the move there could only produce the raw engine refusal —
    /// and doubt (dir absent from detect, signed_in unknown) stays listed,
    /// the same never-hide-a-real-account rule /v1/detect itself follows.
    static func watchOnlyLanes(accounts: [AccountState], detected: [DetectedDir]) -> [WatchOnlyLane] {
        let signedOut = Set(detected.filter { $0.signedIn == false }.map(\.configDir))
        return accounts.compactMap { account in
            // A pinned lane without its own dir has nothing to move —
            // `configDir` is optional on the wire and only pinned/watched
            // accounts reliably carry their folder (Models.swift).
            guard account.pinned, let dir = account.configDir, !dir.isEmpty,
                !signedOut.contains(dir)
            else { return nil }
            return WatchOnlyLane(configDir: dir, email: account.email.isEmpty ? account.label : account.email)
        }
    }

    /// The live account stats the web passes as props on every render
    /// (App.tsx:544,577 + Onboarding.tsx:204-205); the composition root
    /// pushes these into every held `AskMachine` whenever state changes
    /// (review 2026-08-08 P1-4: nothing assigned them before).
    static func askStats(state: DaemonState?, now: Date) -> (watched: Int, switchable: Int, caught: Int?) {
        guard let state else { return (0, 0, nil) }
        let caught = caughtThisWeek(events: state.events, now: now)
        return (
            watched: state.accounts.count,
            switchable: state.accounts.filter { !$0.pinned }.count,
            // App.tsx:544 `caughtThisWeek || undefined` — zero passes as
            // absent so the paused screen omits the line rather than
            // bragging about 0.
            caught: caught > 0 ? caught : nil)
    }
}

// MARK: - the win-back rung (audit F13, owner 2026-08-16 reverses
// the 2026-08-11 ladder removal)

/// The ladder's whole lifecycle, one direction only: intact → armed → spent.
/// `intact` quotes full; a decline trigger (the first ✕ on an askable
/// paywall, or a checkout abandoned) arms it; `armed` quotes the REAL
/// `discount_trial` terms from the live quote; any activation spends it
/// permanently — a later lapse is not being asked for the first time and
/// never sees the rung again.
enum WinbackState: String {
    case intact
    case armed
    case spent
}

/// Which checkout an abandon verdict is about: one install-wide checkout
/// event number. Minted ONLY by `WinbackModel.noteCheckoutHandoff()` — the
/// stored member is fileprivate, so nothing outside this file can forge
/// one — the moment a handoff lands, captured by the composition root when
/// it presents that handoff's sheet, and presented back through
/// `AskMachine.checkoutAbandoned(_:)` when the sheet's post-close decider
/// reports. Any checkout event after it (a press anywhere on this
/// install, or a later handoff) makes it stale, and a stale identity's
/// verdict is discarded.
struct CheckoutIdentity: Equatable {
    fileprivate let event: Int
}

/// The persisted once-per-install win-back state. Keyed to the SAME
/// `fleet.defaults` suite the `proOnboarded`/`proFlowClosed` flags use
/// (NativeCockpitWindow.swift), so an e2e sandbox run never leaks it into a
/// developer's real defaults domain — and a relaunch neither re-arms the
/// offer nor forgets it (the wave's once-per-install line).
@MainActor
final class WinbackModel: ObservableObject {
    static let key = "proWinback"

    @Published private(set) var state: WinbackState
    private let defaults: UserDefaults
    /// Every checkout event on this install, in order: a press that got
    /// past `AskMachine.pressCheckout`'s guards, and a handoff that landed.
    /// Counted HERE, not per AskMachine — every ask (the corridor's, and
    /// each reopened paywall's; `openPaywall` builds a fresh machine per
    /// open) shares this one model, and the harm an abandon verdict can do
    /// lands here on the shared ladder, so the identity it is checked
    /// against must be install-wide too. Process-lifetime only: a decider
    /// does not survive a relaunch either.
    private var checkoutEvents = 0
    /// Presses currently between their guards and their exit, on any ask —
    /// the install-wide "a checkout session is being created right now"
    /// fact. A verdict minted AFTER such a press (a later sheet's) is the
    /// newest event and would otherwise arm while that session is still on
    /// the wire; the abandon decider refuses while this is non-zero, and so
    /// does the ✕ (`AskMachine.close()`). Published: every ask republishes
    /// this model, so the ✕'s enabled state follows it.
    @Published private(set) var checkoutsInFlight = 0
    /// Post-close decisions still running (`PostCheckoutReload.run`, ~10s
    /// after a sheet closes): the verdict on the checkout that just closed
    /// — paid or abandoned — is not in yet. A ✕ in that window must not
    /// arm ahead of it: a buyer who just PAID leaves through the same
    /// Cancel an abandoner uses, the activation push has not landed, and
    /// `license.active` still reads false — arming there would paint the
    /// lower offer over a price they already paid. The ✕ still dismisses;
    /// the decider decides, on this shared ladder, when its window ends.
    @Published private(set) var decisionsPending = 0

    init(defaults: UserDefaults) {
        self.defaults = defaults
        state = defaults.string(forKey: Self.key).flatMap(WinbackState.init) ?? .intact
    }

    /// A checkout press got past its guards somewhere on this install.
    /// Intent to buy exists from here on — whether or not the press lands
    /// — so every abandon verdict still pending for an earlier sheet is
    /// stale from this moment; and until `noteCheckoutPressEnded()` the
    /// press counts as in flight.
    func noteCheckoutPressed() {
        checkoutEvents += 1
        checkoutsInFlight += 1
    }

    /// The press exited — landed, diverted, or failed. Paired with
    /// `noteCheckoutPressed()` by `AskMachine.pressCheckout`'s defer.
    func noteCheckoutPressEnded() {
        checkoutsInFlight = max(0, checkoutsInFlight - 1)
    }

    /// A post-close decision started / ended (`PostCheckoutReload.run`
    /// brackets its whole window). While any is pending, `AskMachine.close()`
    /// dismisses without arming.
    func noteDecisionPending() { decisionsPending += 1 }
    func noteDecisionEnded() { decisionsPending = max(0, decisionsPending - 1) }

    /// A handoff landed — the sheet about to present. Returns the identity
    /// its post-close abandon verdict must carry. Also an event of its own
    /// (not just the press): a slow wire call landing AFTER a later press
    /// still supersedes that press's verdict, whichever machine took it.
    func noteCheckoutHandoff() -> CheckoutIdentity {
        checkoutEvents += 1
        return CheckoutIdentity(event: checkoutEvents)
    }

    /// The abandon decider's identity leg: is `closed` still the newest
    /// checkout event on this install?
    func isNewestCheckout(_ closed: CheckoutIdentity) -> Bool {
        closed.event == checkoutEvents
    }

    /// A decline trigger fired. Only `intact` arms — `armed` is already the
    /// last offer (a second trigger has nothing lower to reach), and `spent`
    /// never resurrects (activation ended the ladder permanently).
    func arm() {
        guard state == .intact else { return }
        persist(.armed)
    }

    /// A license activated — on any rung, through any door (checkout,
    /// claim, recovery link, background poll). The ladder is over for good.
    func noteActivated() {
        guard state != .spent else { return }
        persist(.spent)
    }

    private func persist(_ new: WinbackState) {
        state = new
        defaults.set(new.rawValue, forKey: Self.key)
    }
}

/// Native port of web/src/pro/useQuote.ts's fetch/validate/retry contract —
/// the paywall's consent terms, prefetched once the app knows it is
/// unlicensed. `failed` flips true on EITHER a transport error or a
/// malformed-terms rejection, mirroring api.ts's `fetchQuote` throwing for
/// both (LadderQuote.validated is that second guard, done here instead of
/// inside a throwing fetch function since Swift's `CockpitDaemonAPI.
/// licenseQuote()` already returns the raw, unvalidated `LicenseQuote`).
///
/// DEVIATION (scope-trimmed, documented — see this chunk's report): useQuote
/// also re-quotes on a 15-minute TTL via a background interval so a cockpit
/// left open overnight never shows a stale charge date. That timer is NOT
/// ported here — the guided flow and the reopened paywall are both
/// short-lived per-open surfaces, `reload()` (wired to "Try again"/
/// `AskMachine.reloadQuote`) already self-heals a network blip on demand,
/// and porting a background `Task` polling loop plus its cancellation
/// discipline was judged not worth the risk for this integration chunk's
/// budget. Follow-up if the paywall is ever left open across a real TTL
/// window in practice.
@MainActor
final class ProQuoteModel: ObservableObject {
    @Published private(set) var quote: LadderQuote?
    @Published private(set) var failed = false

    private let api: CockpitDaemonAPI
    private var inFlight = false

    init(api: CockpitDaemonAPI) {
        self.api = api
    }

    /// Fetch once, only if nothing usable is already on hand — the caller
    /// invokes this whenever the app newly knows it is unlicensed (useQuote's
    /// `enabled` gate), so a re-render doesn't refetch a quote it already has.
    func loadIfNeeded() {
        guard quote == nil, !failed else { return }
        reload()
    }

    /// useQuote.ts's `reload` — single-flight (a double "Try again" click
    /// must not race two fetches), and superseded terms must never stay
    /// clickable while the refetch runs: `quote`/`failed` clear FIRST.
    func reload() {
        guard !inFlight else { return }
        inFlight = true
        quote = nil
        failed = false
        Task { [weak self] in
            guard let self else { return }
            do {
                let raw = try await self.api.licenseQuote()
                if let validated = LadderQuote.validated(from: raw) {
                    self.quote = validated
                } else {
                    self.failed = true
                }
            } catch {
                self.failed = true
            }
            self.inFlight = false
        }
    }
}

/// One promotable watch-only lane on the "Pro is on" screen.
struct WatchOnlyLane: Equatable, Identifiable {
    let configDir: String
    let email: String
    var id: String { configDir }
}

/// The "Pro is on" screen's make-switchable action (owner 2026-08-12,
/// "layer 1"): a freshly-activated buyer whose accounts were auto-added as
/// watch-only must be able to promote them AT the activation moment — not
/// discover on the board that the autopilot can't switch to anything.
/// Moving a sign-in is consequential (it leaves the folder; a terminal
/// still using it must sign in again), so this keeps AddAccountModel's
/// exact consent idiom: two clicks, the warning between them, and a 3s
/// auto-disarm.
@MainActor
final class ActivationMoveModel: ObservableObject {
    @Published private(set) var busyDir: String?
    @Published private(set) var confirmDir: String?
    /// Section-level, keyed by dir, and kept after a moved row leaves the
    /// list — a partial-retirement warning must not vanish with the row it
    /// was about (AddAccountModel's own lesson, AddAccountDialog.tsx:206-209).
    @Published private(set) var notes: [String: String] = [:]

    /// Same 3s auto-disarm as AddAccountModel.confirmResetDelay.
    var confirmResetDelay: TimeInterval = 3
    /// Wired by the composition root to a fleet refresh, so the promoted
    /// lane unpins on screen and the facts line recounts itself.
    var onMoved: () -> Void = {}

    private let api: CockpitDaemonAPI & DaemonAPI
    private var confirmResetTask: Task<Void, Never>?

    init(api: CockpitDaemonAPI & DaemonAPI) {
        self.api = api
    }

    /// First press arms the confirm (and shows the leave-the-folder
    /// warning); the second press within the disarm window runs the move.
    func requestMove(_ dir: String) {
        guard busyDir == nil else { return }
        if confirmDir == dir {
            confirmResetTask?.cancel()
            confirmDir = nil
            run(dir)
        } else {
            confirmDir = dir
            confirmResetTask?.cancel()
            let delay = confirmResetDelay
            confirmResetTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(delay, 0) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.resetConfirm(for: dir)
            }
        }
    }

    /// Disarms an armed confirm — the timeout calls this in production;
    /// tests call it directly (StashPanelModel/AddAccountModel precedent).
    func resetConfirm(for dir: String) {
        if confirmDir == dir { confirmDir = nil }
    }

    private func run(_ dir: String) {
        busyDir = dir
        notes[dir] = nil
        Task {
            do {
                let result = try await api.adoptMove(configDir: dir, label: nil)
                // "complete" carries an empty note; "clone_suspect" (and any
                // future outcome) explains itself — show it verbatim, it is
                // the daemon's own user-facing copy.
                if !result.note.isEmpty { notes[dir] = result.note }
                onMoved()
            } catch {
                notes[dir] =
                    (error as? LocalizedError)?.errorDescription ?? "The move didn't take — try again."
            }
            busyDir = nil
        }
    }
}

/// The one native-only step App.tsx has no equivalent of: a checkout
/// SUCCESS there is a page navigation the browser's own SSE reconnect
/// quietly catches up on afterward — nothing in App.tsx explicitly reloads
/// on "checkout closed" because there is no such event. The native
/// `CheckoutSheet` is presented IN-APP with no page reload, so closing it
/// must actively pull the three surfaces an SSE reconnect would otherwise
/// refresh for free: license, state, quote (this chunk's brief, deliverable
/// 4) — then, if the reload landed an ACTIVE license, route the still-open
/// `AskMachine` to the "Pro is on" screen via `applyReloadedLicense`, the
/// native equivalent of Paywall.tsx re-rendering against a live `license`
/// prop.
@MainActor
enum PostCheckoutReload {
    /// The production abandon-decision window. These constants ARE the F1
    /// fix — their product must span several ticks of the daemon's 3s
    /// activation poll (license.go pollEvery), and every behavior test
    /// passes fast overrides, so a dedicated test pins the product
    /// (review delta: "the one part of the fix no gate defends").
    static let defaultRereads = 4
    static let defaultRereadDelay: TimeInterval = 2.5

    /// `closed` is the identity of the checkout whose sheet just closed
    /// (`ask.liveCheckout`, captured by the composition root when it
    /// presented that sheet); the abandon verdict is presented back through
    /// it, so any newer checkout event on the install — a press on any ask,
    /// live or in flight, or a later sheet closed with its own decider still
    /// running — voids this one instead of being armed behind. Nil — no
    /// ask, or no identity captured — decides nothing: the reload still
    /// pulls license/state/quote and still routes an activation, but never
    /// arms.
    static func run(
        api: CockpitDaemonAPI, fleet: FleetViewModel, quote: ProQuoteModel, ask: AskMachine?,
        closed: CheckoutIdentity?,
        rereads: Int = PostCheckoutReload.defaultRereads,
        rereadDelay: TimeInterval = PostCheckoutReload.defaultRereadDelay
    ) async {
        // The whole window is a pending decision on the shared ladder: a ✕
        // pressed inside it dismisses but does not arm (see
        // `WinbackModel.decisionsPending`) — this run decides.
        ask?.winback.noteDecisionPending()
        defer { ask?.winback.noteDecisionEnded() }
        var license = try? await api.license(reveal: false)
        _ = try? await fleet.refresh()
        quote.reload()
        // this reload is ALSO the abandoned-checkout decider (the
        // wave's decision line: the post-checkout license reload decides,
        // not a timer). One instantaneous read is NOT enough evidence
        // (adversarial review F1, P0): in production checkout the embedded
        // Stripe page completes IN the sheet (worker checkout.ts:
        // redirect_on_completion "never" — /pro/activated never navigates),
        // so a buyer who just PAID leaves via the same Cancel button an
        // abandoner uses, and GET /v1/license answers from the local store
        // that only the daemon's ~3s activation poll (license.go pollEvery)
        // updates. Deciding on the first read would arm the win-back — and
        // strike a "lower price" over the amount they just paid — for a
        // paying buyer. So the reload re-reads across several poll ticks
        // (~10s), exits the moment activation lands, and only a license
        // that is STILL inactive at the end counts as abandoned. The
        // license reload remains the sole decider; it is just given long
        // enough to be right. A reload that never succeeds (nil throughout)
        // proves neither and triggers nothing.
        var remaining = rereads
        while remaining > 0, license?.active != true {
            remaining -= 1
            try? await Task.sleep(nanoseconds: UInt64(max(rereadDelay, 0) * 1_000_000_000))
            // The DECIDING read is the final one: a failed re-read replaces
            // earlier evidence with nil rather than letting a stale
            // inactive first read call a still-activating purchase
            // abandoned (found in review).
            license = try? await api.license(reveal: false)
        }
        if let license {
            if license.active {
                ask?.applyReloadedLicense(license)
            } else if let closed {
                // The verdict names the checkout it is about; the machine
                // discards it if any newer checkout event has happened.
                ask?.checkoutAbandoned(closed)
            }
        }
    }
}
