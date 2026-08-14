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
    static func run(
        api: CockpitDaemonAPI, fleet: FleetViewModel, quote: ProQuoteModel, ask: AskMachine?
    ) async {
        let license = try? await api.license(reveal: false)
        _ = try? await fleet.refresh()
        quote.reload()
        if let license {
            ask?.applyReloadedLicense(license)
        }
    }
}
