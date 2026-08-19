import AppKit
import SwiftUI

/// The native cockpit composition — mirroring the web App.tsx main-content
/// order: toolbar → flash → doctor → stash → fleet lanes → history, with the
/// events feed (plan-ordered, native-only) and version footer at the end.
/// Phase 4 chunk 4E wires the money path in: the first-run/paywall mount
/// decision (App.tsx:268-326), the checkout handoff + post-checkout reload,
/// and Settings → License.
struct NativeCockpitRootView: View {
    @ObservedObject var fleet: FleetViewModel
    @ObservedObject var cockpit: CockpitViewModel
    @StateObject private var doctorModel: DoctorPanelModel
    @StateObject private var stashModel: StashPanelModel
    @StateObject private var historyModel: HistorySectionModel
    @StateObject private var addModel: AddAccountModel
    @StateObject private var settingsModel: SettingsModel
    @StateObject private var statuslineModel: StatuslineEditorModel
    @StateObject private var scheduleActions: ScheduleActions
    @StateObject private var quoteModel: ProQuoteModel
    @StateObject private var licenseAccountModel: LicenseAccountModel
    /// ⑨'s make-switchable action (owner 2026-08-12, layer 1) — one model
    /// for both the guided and reopened paths, like quoteModel.
    @StateObject private var activationMove: ActivationMoveModel
    /// The once-per-install win-back ladder — ONE persisted
    /// instance over `fleet.defaults`, shared by the guided and reopened
    /// asks so a trigger on either surface arms the same rung.
    @StateObject private var winback: WinbackModel

    private let api: CockpitDaemonAPI & DaemonAPI
    /// `NativeCockpitWindowController.setFlowMode` — the corridor and the
    /// cockpit/board are different WINDOW SURFACES (design critique
    /// 2026-08-09: distinct content size, minimum, and frame-autosave
    /// name), and this is the one seam that tells the controller which is
    /// currently mounted. `true` exactly when `showFlow` (below) is.
    private let onFlowModeChange: (Bool) -> Void

    @State private var addOpen = false
    @State private var settingsOpen = false
    @State private var statuslineOpen = false
    /// Native twin of the web's localStorage llmpilot.showHistory — the
    /// Settings toggle writes the same key (SettingsSheet); this gates the
    /// section like App.tsx:569 does.
    @AppStorage("showHistory") private var showHistory = true

    // MARK: - Phase 4 chunk 4E: first-run/paywall mount state
    // (App.tsx:137-160's onboarded/flowLatched/flowClosed/paywallOpen).

    /// App.tsx:82,137-138,320-326 `onboarded`/ONBOARDED_KEY — persisted
    /// forever once the first-run tour is dismissed (declined all the way,
    /// OR walked through activation). Keyed to `fleet.defaults` — the
    /// LLMPILOT_DEFAULTS_SUITE-aware suite FleetViewModel's own first-launch
    /// bookkeeping already uses (FleetViewModel.swift:105-112) — rather than
    /// the plain `.standard` suite `showHistory` above uses, so a hosted
    /// e2e run never leaks this flag into a developer's real defaults
    /// domain.
    @AppStorage private var onboarded: Bool
    /// App.tsx:146,301-310 `flowClosed`. DEVIATION (brief-directed, see this
    /// chunk's report): the web's `flowClosed` is a plain, non-persisted
    /// `useState(false)` — it resets on every page reload, so an unfinished
    /// accounts-only flow reappears on the next visit ("session-only: the
    /// accounts screen returns... same semantics the old adoptSkipped had",
    /// App.tsx:140-144). The native window has no reload analogue — the app
    /// process, and this flag's natural "session", spans every window
    /// open/close — so this chunk's brief directs the nearest honest native
    /// mapping instead: persist it with `@AppStorage` in the SAME suite
    /// `onboarded` uses, so an explicitly-closed accounts-only flow does not
    /// reopen on the next window open either (there is no "reload" for it
    /// to survive).
    @AppStorage private var flowClosed: Bool
    /// App.tsx:145,303-305 `flowLatched` — arms whenever `wantFlow` becomes
    /// true and holds through the activation-facts screen (`showOnboarding`
    /// flips false the instant `license.active` does); only an explicit
    /// close releases it. In-memory only on BOTH sides — re-latching after
    /// every relaunch is correct (a mid-flow quit must not skip straight to
    /// the board next launch).
    @State private var flowLatched = false
    @State private var paywallOpen = false
    /// The corridor's automatic adopts that were refused, BY DIR — feeds the
    /// accounts step's failure line (audit 2026-08-11). A set, not a
    /// counter: the adopt can re-run (the accounts step remounts on the
    /// updateTour reset path), and a counter would announce one persistently
    /// failing account as two (review 2026-08-11 P2-3). A later success
    /// removes its dir.
    @State private var failedAdoptDirs: Set<String> = []

    // MARK: - Chunk 5A: guided tour (App.tsx:83-113,147-153,296-318,426;
    // web/src/shell/Tour.tsx)

    /// App.tsx:83 `TOUR_KEY = "llmpilot.tour.seen"` — same literal key, same
    /// `fleet.defaults` suite `onboarded`/`flowClosed` above already use, so
    /// an e2e sandbox run never leaks this into a developer's real domain.
    @AppStorage private var tourSeen: Bool
    @State private var tourOpen = false
    /// A fresh model per walk — mirrors the web's `{tourOpen && canGuide &&
    /// <Tour steps={TOUR_STEPS} onDone={endTour} />}` remounting a new
    /// component instance (and therefore a fresh `i = 0`) every time the
    /// guide opens, including a "Show me around" replay.
    @State private var tourModel: TourModel?

    /// Onboarding.tsx's phase machine — constructed once, the first time the
    /// flow is wanted (Onboarding.tsx:59-61's `startedEmpty` freeze), held
    /// for the life of the window.
    @State private var onboardingModel: OnboardingModel?
    /// The guided flow's `AskMachine` (OnboardingFlowView's `ask` param) —
    /// built once a license has FIRST resolved (`OnboardingModel.
    /// resolvedLicense`) and kept alive across re-renders, per that param's
    /// own contract.
    @State private var guidedAsk: AskMachine?
    /// The standalone reopened paywall's `AskMachine` — fresh each time
    /// `paywallOpen` flips true (App.tsx's `{paywallOpen && <Paywall/>}`
    /// remounts a fresh component instance on the web side too).
    @State private var reopenedAsk: AskMachine?
    /// `CheckoutSheetController.present`'s caller MUST hold the returned
    /// controller for as long as the sheet may be showing (WKWebView's
    /// `navigationDelegate` is weak; this is the only strong owner).
    /// Released the moment `onClosed` fires.
    @State private var checkoutController: CheckoutSheetController?

    init(
        fleet: FleetViewModel, cockpit: CockpitViewModel, api: CockpitDaemonAPI & DaemonAPI,
        onFlowModeChange: @escaping (Bool) -> Void = { _ in }
    ) {
        self.fleet = fleet
        self.cockpit = cockpit
        self.api = api
        self.onFlowModeChange = onFlowModeChange
        _doctorModel = StateObject(wrappedValue: DoctorPanelModel(
            api: api,
            onAddAccount: { LoginWindowController.shared.open() },
            onReviewStash: {}))
        _stashModel = StateObject(wrappedValue: StashPanelModel(api: api))
        _historyModel = StateObject(wrappedValue: HistorySectionModel(
            cockpit: cockpit))
        let add = AddAccountModel(api: api)
        add.openLoginWindow = { LoginWindowController.shared.open() }
        _addModel = StateObject(wrappedValue: add)
        _settingsModel = StateObject(wrappedValue: SettingsModel(api: api))
        _statuslineModel = StateObject(wrappedValue: StatuslineEditorModel(api: api))
        _scheduleActions = StateObject(wrappedValue: ScheduleActions(api: api))
        _quoteModel = StateObject(wrappedValue: ProQuoteModel(api: api))
        let licenseModel = LicenseAccountModel(api: api)
        // LicenseSection.tsx's `onReload` — re-fetches GET /v1/license so
        // Settings → License reflects a cancel/claim write immediately.
        licenseModel.onReload = { Task { await cockpit.loadLicense() } }
        _licenseAccountModel = StateObject(wrappedValue: licenseModel)
        let moveModel = ActivationMoveModel(api: api)
        // A landed move unpins the lane — refresh so the promoted row
        // leaves the ⑨ list and the facts line recounts itself.
        moveModel.onMoved = { Task { try? await fleet.refresh() } }
        _activationMove = StateObject(wrappedValue: moveModel)
        _winback = StateObject(wrappedValue: WinbackModel(defaults: fleet.defaults))
        _onboarded = AppStorage(wrappedValue: false, "proOnboarded", store: fleet.defaults)
        _flowClosed = AppStorage(wrappedValue: false, "proFlowClosed", store: fleet.defaults)
        _tourSeen = AppStorage(wrappedValue: false, "llmpilot.tour.seen", store: fleet.defaults)
    }

    /// Device-local minutes-of-day, the board/severity.ts strategy the lane
    /// staleness math expects. Rides fleet.now so the 30 s ticker refreshes
    /// stale states without any extra timer.
    private var nowMinutes: Int {
        Calendar.current.component(.hour, from: fleet.now) * 60
            + Calendar.current.component(.minute, from: fleet.now)
    }

    private var asOfAge: String? {
        guard let asOf = fleet.state?.asOf else { return nil }
        return ageLabel(from: asOf, now: fleet.now)
    }

    /// App.tsx:273-274 `proAvailable`/`proUnlicensed` — gates the quote
    /// prefetch (useQuote's own `enabled`).
    private var proUnlicensed: Bool {
        guard let license = cockpit.license else { return false }
        return license.available && !license.active
    }

    var body: some View {
        Group {
            if let state = fleet.state {
                content(state)
            } else {
                ConnectivityFullPageView(status: fleet.status)
            }
        }
        .background(CockpitTheme.win)
        // useLicense.ts: hydrate on mount, refetch whenever the SSE-derived
        // key changes. Native `DaemonState` carries `license_status` but not
        // `license_error` (never decoded — no native call site has needed
        // it) — the reload key here is narrower than the web's by exactly
        // that one field.
        .task(id: fleet.state?.license) { await cockpit.loadLicense() }
        // useQuote.ts: prefetched the moment the app knows it is unlicensed.
        .task(id: proUnlicensed) { if proUnlicensed { quoteModel.loadIfNeeded() } }
    }

    private func content(_ state: DaemonState) -> some View {
        let firstRun = ProFlowLogic.firstRun(accounts: state.accounts)
        let showOnboarding = ProFlowLogic.showOnboarding(license: cockpit.license, onboarded: onboarded)
        let wantFlow = ProFlowLogic.wantFlow(firstRun: firstRun, flowClosed: flowClosed, showOnboarding: showOnboarding)
        let showFlow = ProFlowLogic.showFlow(wantFlow: wantFlow, flowLatched: flowLatched)
        // App.tsx:283,287-288 `boardVisible`/`canGuide` — the board is up,
        // unobstructed, and has at least one account to point at. `state` is
        // always non-nil here (this function only runs once `fleet.state`
        // resolves), unlike the web's separate null check.
        let canGuide = tourEligible(state: state, showFlow: showFlow)

        return Group {
            if showFlow {
                flowContent(state)
            } else {
                board(state)
            }
        }
        .overlay { reopenedPaywallOverlay() }
        .sheet(isPresented: $addOpen) {
            SheetChrome(width: 440, onClose: { addOpen = false }) {
                AddAccountSheet(model: addModel)
            }
            .onAppear {
                // The in-fleet classification needs the CURRENT fleet emails
                // (empty ones filtered, App.tsx:605), the fleet's own dir so
                // it never lists itself with a move verb (App.tsx:604), and
                // the close seam so done/window-sign-in can dismiss.
                // (The sheet's own onAppear already calls opened() — no
                // duplicate detect() here.)
                addModel.fleetEmails = state.accounts.map(\.email).filter { !$0.isEmpty }
                addModel.fleetDir = state.accounts.first { !$0.pinned }?.configDir ?? ""
                addModel.onRequestClose = { addOpen = false }
            }
        }
        .sheet(isPresented: $settingsOpen) {
            SheetChrome(minWidth: 460, onClose: { settingsOpen = false }) {
                SettingsSheet(
                    model: settingsModel,
                    accounts: state.accounts,
                    onClose: { settingsOpen = false },
                    onOpenStatusline: {
                        settingsOpen = false
                        // Presenting a sibling sheet while the dismiss
                        // ANIMATION is still running is a known macOS
                        // SwiftUI flake — one runloop hop clears the update
                        // cycle but not the ~200ms animation, so wait it
                        // out.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            statuslineOpen = true
                        }
                    },
                    license: cockpit.license,
                    licenseModel: licenseAccountModel,
                    onTurnOn: {
                        // NATIVE DEVIATION: SettingsDialog.tsx's onTurnOn
                        // (openPaywall) does not close the Settings dialog on
                        // the web — the paywall renders in its own fixed
                        // overlay above everything, including an open modal.
                        // A native `.sheet` cannot stack a second sheet on
                        // top of an already-presented one, so the paused/
                        // lapsed reopen path here closes Settings first.
                        settingsOpen = false
                        openPaywall()
                    })
            }
            // LicenseSection.tsx's `revealed`/`note` die with the dialog
            // (component-local useState, :51); restore that lifecycle for
            // the window-scoped native model (review 2026-08-08 P1-6: one
            // Show click otherwise kept the full id on screen for every
            // later Settings open).
            .onDisappear { licenseAccountModel.resetTransientUI() }
        }
        .sheet(isPresented: $statuslineOpen) {
            SheetChrome(minWidth: 560, minHeight: 480, onClose: { statuslineOpen = false }) {
                StatuslineEditorView(model: statuslineModel, offline: fleet.status != .live)
            }
        }
        .onAppear { armFlowIfNeeded(wantFlow: wantFlow, showOnboarding: showOnboarding, firstRun: firstRun) }
        .onChange(of: wantFlow) { newValue in
            armFlowIfNeeded(wantFlow: newValue, showOnboarding: showOnboarding, firstRun: firstRun)
        }
        // App.tsx:296-299 — the ONE rule: the first time a real board is on
        // screen, the guide opens (once — `tourSeen` gates every later one).
        // A SINGLE handler for both canGuide reactions (delta re-review P3:
        // two handlers double-allocated the model on a false→true edge):
        // an already-open, deferred walk gets a fresh model (the web
        // remounts <Tour/> from scratch — fresh i = 0); otherwise the
        // auto-open rule runs (armTourIfNeeded no-ops while tourOpen, so
        // the branches are exclusive).
        .onAppear { armTourIfNeeded(canGuide: canGuide) }
        .onChange(of: canGuide) { newValue in
            if newValue, tourOpen {
                tourModel = TourModel()
            } else {
                armTourIfNeeded(canGuide: newValue)
            }
        }
        // Chunk 5A: the tour overlay — mounted at this ancestor of every
        // `.tourAnchor(_:)`-tagged view (fresh-window button, fleet lanes'
        // switch verb + runway) so its `TourAnchorPreferenceKey` collects
        // all three (F15, 2026-08-16: the toolbar's daemon pill lost its
        // anchor along with the dropped tour step and the healthy pill
        // itself). Wrapped in its own `GeometryReader` to resolve anchors
        // into local coordinates.
        //
        // `canGuide` is part of the MOUNT condition, exactly like the web's
        // `{tourOpen && canGuide && <Tour/>}` (App.tsx:599) — review
        // 2026-08-08 P1-1: without it, the first-run flow replacing the
        // board strips every anchor, the overlay reads "no live steps",
        // calls onDone, and BURNS tourSeen — the guide is consumed instead
        // of deferred (web/tests/tour.spec.ts:143-157 pins deferral). With
        // the gate, the overlay unmounts WITHOUT onDone: tourOpen stays
        // true, tourSeen stays false, and the walk restarts fresh when the
        // board returns. Same gate also keeps the tour off the reopened
        // paywall (canGuide excludes paywallOpen), which otherwise sat
        // BELOW this overlay in z-order.
        .overlayPreferenceValue(TourAnchorPreferenceKey.self) { anchors in
            if tourOpen, canGuide, let tourModel {
                GeometryReader { geo in
                    TourOverlayView(model: tourModel, anchors: anchors, geometry: geo, onDone: endTour)
                }
            }
        }
        // Onboarding.tsx:63-80 — `tour` may only go UP; OnboardingModel.
        // updateTour already ignores a downgrade, so this can fire freely.
        // The identity count is re-pushed in the SAME beat (review
        // 2026-08-11 P1-2): the late-tour path arms with tour=false on the
        // accounts step, where updateIdentityCount is rejected — the reset
        // back to ① reopens the count window, and without this push the
        // count already known from /v1/detect would stay 0 and ② would be
        // skipped on exactly the multi-account machines it teaches.
        .onChange(of: showOnboarding) { newValue in
            onboardingModel?.updateTour(newValue)
            onboardingModel?.updateIdentityCount(armedIdentityCount)
        }
        // Paywall.tsx takes `license`/`quote` as LIVE props (Paywall.tsx:162,
        // useQuote.ts) — a late quote fetch or a post-checkout activation
        // simply re-renders. The native machines are long-lived objects, so
        // the props become explicit pushes (review 2026-08-08 P0-1/P0-3:
        // constructor snapshots meant the guided ask held quote == nil
        // forever — "Loading the price…" with a dead retry — and a completed
        // purchase never flipped any open paywall to "Pro is on").
        .onChange(of: cockpit.license) { newValue in
            resolveGuidedAsk(newValue)
            if let license = newValue {
                guidedAsk?.applyReloadedLicense(license)
                reopenedAsk?.applyReloadedLicense(license)
                // activation through a door no ask ever sees (a
                // claim from Settings, the daemon's background poll) still
                // ends the win-back ladder permanently.
                if license.active { winback.noteActivated() }
            }
            // Phase 6 chunk A: the menu bar's upsell row asks for the
            // paywall before this window necessarily has a license fetched
            // yet (a fresh window's own `.task(id:)` load may still be in
            // flight) — this is the "license just arrived" half of that
            // seam; the "already had one" half is below.
            consumePendingPaywall()
        }
        // The "license was already resolved" half of the seam above — a
        // repeat click on the upsell row while the window is already open
        // sets the flag but never changes `cockpit.license`, so onChange
        // never fires.
        .onChange(of: fleet.pendingOpenPaywall) { _ in
            consumePendingPaywall()
        }
        .onChange(of: quoteModel.quote) { newValue in
            guidedAsk?.setQuote(newValue)
            reopenedAsk?.setQuote(newValue)
        }
        // App.tsx:289,544,577 + Onboarding.tsx:204-205 — the account stats
        // are re-computed per render on the web; push them on every state
        // change here (review 2026-08-08 P1-4). fleet.state is already the
        // new value when this handler runs.
        .onChange(of: fleet.state) { _ in
            syncAskStats()
            onboardingModel?.updateIdentityCount(armedIdentityCount)
        }
        // ②'s gate: the ladder arms one round trip before /v1/detect can
        // answer, so the construction-time count is 0 on every fresh machine
        // and ② never rendered (audit 2026-08-11). Detection landing settles
        // the count — the model itself only accepts the update while the
        // user is still on ① (OnboardingModel.updateIdentityCount).
        .onChange(of: fleet.detected) { _ in
            onboardingModel?.updateIdentityCount(armedIdentityCount)
        }
        // The corridor and the cockpit/board are different window
        // surfaces (design critique 2026-08-09) — tell the controller
        // which one is mounted so it can apply that mode's own content
        // size/minimum/frame-autosave name (NativeCockpitWindowController
        // .setFlowMode). Fires on first render too, not just on flip, so a
        // fresh first-run window lands at the corridor's size immediately
        // rather than only after `wantFlow` next changes.
        .onAppear { onFlowModeChange(showFlow) }
        .onChange(of: showFlow) { onFlowModeChange($0) }
    }

    /// App.tsx:495-549's `showFlow` branch — the flow owns the whole
    /// screen: no toolbar, no board. Scrollable, top-aligned, horizontally
    /// centered — the web's `items-start justify-center` page flow (each
    /// screen carries its own fixed column width, e.g. Receipt.tsx:68's
    /// 620px; the sprawl the owner caught on 2026-08-08 was these screens
    /// mounting without their column caps).
    @ViewBuilder
    private func flowContent(_ state: DaemonState) -> some View {
        // Each corridor screen fills the viewport: top-aligned content, CTA
        // pinned at the bottom (FlowLayout/OnboardingStage). `minHeight`,
        // NOT `height`: a fixed height would make the scroll content exactly
        // the viewport, so the ScrollView could never scroll and anything
        // taller (the receipt table at the corridor's 760×560 minimum) would
        // simply clip. A minimum still gives this subtree a real non-zero
        // size for NSHostingView (a bare `maxHeight: .infinity` subtree
        // reports ZERO and collapses the window; measured 2026-08-09) and
        // still lets OnboardingStage's one Spacer pin the footer when the
        // screen is short.
        GeometryReader { geo in
            ScrollView {
                Group {
                    if let model = onboardingModel {
                        OnboardingFlowView(
                            model: model,
                            accounts: state.accounts,
                            // nil until /v1/detect has ANSWERED — the
                            // accounts step's "Finding your accounts…"
                            // state rides that distinction; the plain
                            // `[]` default made it unreachable and flashed
                            // the empty state during the gap (review
                            // 2026-08-11 P2-8).
                            detected: fleet.detectAnswered ? fleet.detected : nil,
                            state: state,
                            ask: guidedAsk,
                            onAddAccount: { addOpen = true },
                            onAdoptDetected: adoptDetectedAccounts,
                            // Intersected with what still NEEDS adopting so
                            // the line self-heals when its own remedy works
                            // (review 2026-08-11 NEW-2): a dir registered
                            // later via the Add-account sheet drops out of
                            // dirsToAdopt, and the failure line with it.
                            adoptFailedCount: failedAdoptDirs
                                .intersection(OnboardingAccountsCopy.dirsToAdopt(fleet.detected))
                                .count,
                            onExit: closeFlow,
                            onRecover: { settingsOpen = true },
                            quoteFailed: quoteModel.failed,
                            onRetryQuote: quoteModel.reload,
                            onCheckoutHandoff: { url in
                                guard let ask = guidedAsk else { return }
                                presentCheckout(url, ask: ask)
                            },
                            watchOnly: ProFlowLogic.watchOnlyLanes(
                                accounts: state.accounts, detected: fleet.detected),
                            activationMove: activationMove)
                    }
                }
                .frame(width: geo.size.width)
                .frame(minHeight: geo.size.height, alignment: .top)
            }
        }
    }

    private func board(_ state: DaemonState) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    NativeToolbarRow(
                        status: fleet.status,
                        asOfAge: asOfAge,
                        unregisteredDetectedCount: fleet.unadoptedDetectedCount,
                        onAddAccount: { addOpen = true },
                        onSettings: { settingsOpen = true },
                        // Toolbar.tsx:426 `canGuide ? () => setTourOpen(true)
                        // : undefined` — reopens regardless of `tourSeen`.
                        onGuide: tourEligible(state: state, showFlow: false) ? { openTour() } : nil)
                    FreshWindowMenu(
                        accounts: state.accounts.map {
                            FreshWindowAccount(id: $0.id, label: $0.label, email: $0.email)
                        },
                        nowMinutes: nowMinutes,
                        laneState: { accountID in
                            let resets = state.schedules
                                .filter { $0.accountID == accountID }
                                .map { BoardSchedule.resetMinutes(hour: $0.hour, minute: $0.minute) }
                            let account = state.accounts.first { $0.id == accountID }
                            let mid = account.flatMap { BoardView.midWindow(for: $0) }
                            return (existingResets: resets, activeEndMinutes: mid?.end)
                        },
                        onCreate: { accountID, hour, minute in
                            Task { _ = await scheduleActions.create(accountID: accountID, hour: hour, minute: minute) }
                        },
                        onFullyBooked: { scheduleActions.flashLocal($0) })
                }
                // App.tsx:429-439 — the transient error flash (switch 409s
                // etc.). Dismiss clears the SOURCE (setFlash(null) twin), so
                // a repeated identical error still re-surfaces — local
                // "last dismissed text" state would swallow it forever.
                if let flash = fleet.lastError {
                    FlashBanner(message: flash, onDismiss: { fleet.lastError = nil })
                }
                DoctorPanelView(model: doctorModel, reloadKey: doctorReloadKey(state: state))
                StashPanelView(model: stashModel, stash: state.stash)
                sectionBox {
                    NativeBoardSection(
                        fleet: fleet,
                        actions: scheduleActions,
                        state: state,
                        nowMinutes: nowMinutes,
                        // Phase 4 chunk 4E: the CTA now opens the native
                        // paywall — it no longer routes to the interim web
                        // cockpit.
                        onProCTA: { openPaywall() })
                }
                if showHistory {
                    HistorySectionView(model: historyModel, state: state)
                }
                sectionBox { EventsFeedView(events: state.events, version: state.version) }
            }
            .padding(16)
        }
    }

    /// App.tsx:573-598 — the reopened, non-guided paywall overlay: a
    /// full-window backdrop with a scrollable, top-aligned column
    /// (`overflow-y-auto` + `items-start justify-center py-14`).
    ///
    /// N2 (audit 2026-08-17): the backdrop was `CockpitTheme.win` at 0.95
    /// with no opaque panel behind the content, and the cockpit read
    /// straight THROUGH the money screens — the doctor's
    /// `signin_live_elsewhere` warning ran under the comparison table's
    /// "Watch every limit, live" row, and again under the price screen's
    /// lede and "No payment due today." Text-on-text on the screen that
    /// asks for money. The backdrop is now fully opaque: the reopened flow
    /// gets the same clean surface the first-run corridor has (which was
    /// never affected — it is real window content, not an overlay).
    @ViewBuilder
    private func reopenedPaywallOverlay() -> some View {
        if paywallOpen, let ask = reopenedAsk {
            ZStack {
                CockpitTheme.win
                    .ignoresSafeArea()
                GeometryReader { geo in
                    ScrollView {
                        PaywallView(
                            ask: ask,
                            dots: nil,
                            quoteFailed: quoteModel.failed,
                            onRetryQuote: quoteModel.reload,
                            onRecover: {
                                paywallOpen = false
                                settingsOpen = true
                            },
                            onCheckoutHandoff: { url in presentCheckout(url, ask: ask) },
                            watchOnly: ProFlowLogic.watchOnlyLanes(
                                accounts: fleet.state?.accounts ?? [], detected: fleet.detected),
                            activationMove: activationMove)
                            // minHeight, not height — see flowContent: a
                            // fixed height cannot scroll, it clips.
                            .frame(width: geo.size.width)
                            .frame(minHeight: geo.size.height, alignment: .top)
                    }
                }
            }
        }
    }

    private func sectionBox(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .padding(12)
            .background(CockpitTheme.panel, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(CockpitTheme.hairSoft))
    }

    // MARK: - Chunk 5A: guided tour wiring (App.tsx:283-318,426)

    /// App.tsx:283,287-288 `boardVisible && accounts.length > 0`. The web
    /// also excludes its fixture harness unless `?tour=1` forces it
    /// (App.tsx:284-286) — there is no fixtures-mode analogue natively, so
    /// that half of the gate is simply absent here.
    private func tourEligible(state: DaemonState, showFlow: Bool) -> Bool {
        !showFlow && !paywallOpen && !state.accounts.isEmpty
    }

    /// App.tsx:296-299's one auto-open rule.
    private func armTourIfNeeded(canGuide: Bool) {
        guard canGuide, !tourSeen, !tourOpen else { return }
        openTour()
    }

    /// App.tsx:426's "Show me around" — and the auto-open path above, which
    /// funnels through here too so both share the same fresh-model rule.
    private func openTour() {
        tourModel = TourModel()
        tourOpen = true
    }

    /// App.tsx:312-318 `endTour` — the native window has no fixtures/forced
    /// mode to guard against (App.tsx:315-317's own comment), so persisting
    /// unconditionally is correct here.
    private func endTour() {
        tourOpen = false
        tourSeen = true
    }

    // MARK: - Phase 4 chunk 4E: mount/corridor/checkout wiring

    /// Onboarding.tsx's `startedEmpty`/`tour` freeze (Onboarding.tsx:59-61)
    /// plus the guided `AskMachine`'s own construction gate — both fire the
    /// instant the flow is first wanted, and never again for the life of
    /// this window.
    private func armFlowIfNeeded(wantFlow: Bool, showOnboarding: Bool, firstRun: Bool) {
        guard wantFlow else { return }
        flowLatched = true
        if onboardingModel == nil {
            onboardingModel = OnboardingModel(
                tour: showOnboarding, startedEmpty: firstRun,
                identityCount: armedIdentityCount)
        }
        resolveGuidedAsk(cockpit.license)
    }

    /// Register every detected-but-unregistered Claude config dir with the
    /// daemon (owner 2026-08-11). Detection was always automatic; ADOPTION
    /// was not, so the corridor could list a user's accounts and then leave
    /// with none of them registered. Sequential, not concurrent: each adopt
    /// is a credential-adjacent write and the daemon takes Claude Code's own
    /// locks per call. Already-registered dirs are skipped, so a re-entry
    /// (detection answering late) cannot double-adopt.
    private func adoptDetectedAccounts() {
        // @MainActor explicitly: a View method carries no isolation of its
        // own, and the failure set is @State — it must never be mutated off
        // the main actor.
        Task { @MainActor in
            var attempted = false
            for dir in OnboardingAccountsCopy.dirsToAdopt(fleet.detected) {
                attempted = true
                if await fleet.adopt(dir) {
                    failedAdoptDirs.remove(dir)
                } else {
                    failedAdoptDirs.insert(dir)
                }
            }
            // The corridor owns the reporting for adopts IT initiated
            // (review 2026-08-11 P1-1): `fleet.adopt` also records the raw
            // engine refusal in `lastError` ("no credential in Keychain
            // service …"), which the BOARD renders as a flash banner the
            // moment the corridor closes — the exact internals-leak the
            // in-flow failure line exists to replace. Cleared only when
            // this loop actually ran, so an unrelated error is never eaten.
            if attempted {
                fleet.lastError = nil
            }
        }
    }

    /// The identity count ② is gated on (`OnboardingModel.identityCount`).
    /// Detection is asynchronous, so at ARM time this usually under-counts —
    /// deliberately the safe direction: a low count SKIPS ② (a screen whose
    /// only job is to reveal an inventory), where a high count would mount
    /// it with nothing to show. The `.onChange(of: fleet.detected)`/
    /// `(of: fleet.state)` wiring above re-pushes this as answers land, and
    /// `OnboardingModel.updateIdentityCount` accepts the update only while
    /// the user is still on ① — past that the ladder is committed and the
    /// dots never rewrite themselves under the user.
    private var armedIdentityCount: Int {
        OnboardingModel.identities(
            accounts: fleet.state?.accounts ?? [], detected: fleet.detected
        ).count
    }

    /// Onboarding.tsx:122-129 `resolvedLicense` — call with the CURRENT
    /// license on every update so a transient fetch failure never blanks the
    /// ask screen; construct the guided `AskMachine` the FIRST time a
    /// license resolves, and never again (its `ask` param contract: kept
    /// alive across re-renders).
    private func resolveGuidedAsk(_ current: LicenseInfo?) {
        guard let model = onboardingModel else { return }
        let resolved = model.resolvedLicense(current)
        guard guidedAsk == nil, let license = resolved else { return }
        let ask = AskMachine(
            license: license, quote: quoteModel.quote,
            guided: ProFlowLogic.guided(for: .firstRunFlow),
            locale: Locale.current.identifier, winback: winback, api: api,
            onDismiss: dismissOnboarding)
        ask.reloadQuote = { [quoteModel] in quoteModel.reload() }
        seedAskStats(ask)
        guidedAsk = ask
    }

    /// The web's per-render prop computation, done once at construction and
    /// then on every state change (the `.onChange(of: fleet.state)` above).
    /// `accountsSwitchable` rides ONLY the guided ask: Onboarding.tsx:205
    /// passes it, the reopened <Paywall> (App.tsx:576-595) does not — its
    /// receipt keeps the generic headline (delta re-review P2).
    private func seedAskStats(_ ask: AskMachine) {
        let stats = ProFlowLogic.askStats(state: fleet.state, now: fleet.now)
        setIfChanged(ask, \.accountsWatched, stats.watched)
        setIfChanged(ask, \.caughtThisWeek, stats.caught)
        if ask.guided {
            setIfChanged(ask, \.accountsSwitchable, stats.switchable)
        }
    }

    private func syncAskStats() {
        for ask in [guidedAsk, reopenedAsk].compactMap({ $0 }) {
            seedAskStats(ask)
        }
    }

    /// Skip no-op writes so an SSE tick with unchanged numbers doesn't emit
    /// objectWillChange on an open paywall (delta re-review P3).
    private func setIfChanged(
        _ ask: AskMachine, _ path: ReferenceWritableKeyPath<AskMachine, Int?>, _ value: Int?
    ) {
        if ask[keyPath: path] != value { ask[keyPath: path] = value }
    }

    /// App.tsx:307-310 `closeFlow`.
    private func closeFlow() {
        flowLatched = false
        flowClosed = true
    }

    /// The menu bar upsell's landing logic (review 2026-08-08 Phase 6
    /// P1-1): the click means "I want the autopilot", and the FLOW decision
    /// — not the click — chooses the surface. If the first-run corridor is
    /// showing (or wanted), it already teaches then asks: consuming the
    /// flag by clearing it is the whole job, and calling `openPaywall()`
    /// here would have burned `onboarded`/`flowClosed` and spent the
    /// notification ask from a cold menu-bar click, killing the corridor
    /// forever. Only a user with the BOARD on screen routes to the
    /// reopened paywall — the same downstream-of-the-flow-decision position
    /// every web openPaywall call site holds (App.tsx:464,489,620).
    private func consumePendingPaywall() {
        guard fleet.pendingOpenPaywall, cockpit.license != nil,
            let state = fleet.state
        else { return }
        fleet.pendingOpenPaywall = false
        let firstRun = ProFlowLogic.firstRun(accounts: state.accounts)
        let showOnboarding = ProFlowLogic.showOnboarding(license: cockpit.license, onboarded: onboarded)
        let wantFlow = ProFlowLogic.wantFlow(firstRun: firstRun, flowClosed: flowClosed, showOnboarding: showOnboarding)
        if ProFlowLogic.showFlow(wantFlow: wantFlow, flowLatched: flowLatched) {
            return
        }
        openPaywall()
    }

    /// App.tsx:320-326 `dismissOnboarding`. Also the first of the two
    /// user-visible moments that may spend the ONE notification-permission
    /// ask (the other: Settings → "Usage notifications" on) — by now the
    /// app has explained itself, unlike at launch (delta re-review
    /// 2026-08-08). No-op unless status is still undetermined.
    private func dismissOnboarding() {
        onboarded = true
        closeFlow()
        Task { await NoticeNotifier.shared.requestPermission() }
    }

    /// App.tsx:407-411 `openPaywall` — clears on OPEN (not just dismiss),
    /// covering every path a stale refusal could ride back in. The two
    /// non-first-run triggers this chunk wires — the board's pro CTA
    /// (`onProCTA` above) and Settings → License "Turn on the autopilot"
    /// (the paused/lapsed reopen path, `LicenseCardView.showTurnOn` renders
    /// it exactly for status none/lapsed/revoked) — both call this SAME
    /// function, exactly as App.tsx's `showProBanner` click and
    /// `SettingsDialog.onTurnOn` do.
    private func openPaywall() {
        guard let license = cockpit.license else { return }
        dismissOnboarding()
        let ask = AskMachine(
            license: license, quote: quoteModel.quote,
            guided: ProFlowLogic.guided(for: .reopenedPaywall),
            locale: Locale.current.identifier, winback: winback, api: api,
            onDismiss: {
                paywallOpen = false
                reopenedAsk = nil
            })
        ask.reloadQuote = { [quoteModel] in quoteModel.reload() }
        seedAskStats(ask)
        reopenedAsk = ask
        paywallOpen = true
    }

    /// PaywallView's `onCheckoutHandoff` — presents `CheckoutSheet` on the
    /// window this root view is hosted in, HOLDS the returned controller,
    /// and on close runs the post-checkout reload (deliverable 4).
    private func presentCheckout(_ url: URL, ask: AskMachine) {
        guard let window = NativeCockpitWindowController.shared.window else { return }
        // Bind the post-close decider to THIS handoff now, at present time:
        // the sheet's onClosed may fire long after (or, for a superseded
        // sheet, out of order with) the machine's own state, so nothing is
        // read back from the machine at close.
        let presented = ask.liveCheckout
        // "Start again here": end any sheet already up before presenting the
        // new one. Its onClosed runs from beginSheet's completion — AFTER the
        // new assignment below — so the release is identity-guarded: only the
        // controller whose own sheet closed may vacate the slot, never a
        // successor's (review 2026-08-08 P2-10: an unconditional `nil` here
        // dropped the LIVE sheet's only strong delegate owner, silently
        // disabling policy enforcement on a payment surface).
        checkoutController?.dismiss()
        var controller: CheckoutSheetController?
        controller = CheckoutSheet.present(url: url, on: window) {
            // EVERY side effect is identity-guarded, not just the slot
            // release: a predecessor's deferred onClosed (endSheet's
            // completion runs async) must not clear the SUCCESSOR's live
            // handoff or fire a reload under its open sheet (delta
            // re-review P2).
            guard checkoutController === controller else { return }
            checkoutController = nil
            // The sheet is gone — the machine's "Checkout is open in the
            // payment window" line must not outlive it (P1-5).
            ask.checkoutSheetClosed()
            // The decider carries the identity captured above: a checkout
            // pressed after it — on this ask or a fresh one — is a newer
            // checkout event, and this sheet's stale "abandoned" verdict
            // must not arm behind the new sheet or inside its decider's
            // window.
            Task {
                await PostCheckoutReload.run(api: api, fleet: fleet, quote: quoteModel, ask: ask, closed: presented)
            }
        }
        checkoutController = controller
    }
}

/// Corridor vs. cockpit/board are different WINDOW SURFACES (design
/// critique 2026-08-09) — distinct content size, minimum, and their OWN
/// frame-autosave name, so an onboarding-sized frame is never restored
/// under the board (or vice versa). One controller/window serves both;
/// `NativeCockpitWindowController.applyMode` switches between them as
/// `NativeCockpitRootView.onFlowModeChange` reports whether the corridor
/// flow is currently mounted.
///
/// Decided in the 2026-08-16 audit walk (F16) — cockpit resizable at
/// min 1000×700, default 1180×820, corridor fixed: the
/// cockpit stays resizable (a fleet grows vertically with N accounts, and
/// screens range from a 13" Air to a 27" display — a size lock would fight
/// that); the corridor is a one-shot flow with no frame autosave already,
/// so `applyMode` now also drops `.resizable` from the window's styleMask
/// while it is mounted, and restores it going back to cockpit. Internal,
/// not private, so `WindowMode.cockpit.minSize`/`.targetContentSize` are
/// directly testable (MainMenuTests) without exercising the controller.
enum WindowMode: Equatable {
    case cockpit
    case corridor

    /// nil means NEVER persisted. The corridor is a once-only wizard opened
    /// at a designed size, so remembering a frame for it buys nothing and
    /// creates a way for a stale size to silently override the design:
    /// measured 2026-08-10, a leftover `NSWindow Frame llmpilot-onboarding`
    /// of 898x712 sat in dev.llmpilot.menubar from earlier dev runs and was
    /// restored in preference to the designed size. NSWindow's frame
    /// autosave writes to `UserDefaults.standard` — the app's own bundle
    /// domain — NOT the throwaway `LLMPILOT_DEFAULTS_SUITE` the sandboxes
    /// set, so even a "brand-new machine" harness inherited it.
    var autosaveName: NSWindow.FrameAutosaveName? {
        switch self {
        case .cockpit: return "llmpilot-cockpit"
        case .corridor: return nil
        }
    }

    /// The window's hard floor — also mirrored into the SwiftUI root's own
    /// `.frame(minWidth:minHeight:)` (`CockpitWindowSizeState`, below) so
    /// the two never disagree. See the CRITICAL fitting-size note at the
    /// hosting-view construction site in `open(fleet:api:)`: the root MUST
    /// carry a non-zero minimum or NSHostingView collapses the window to a
    /// title-bar sliver.
    var minSize: NSSize {
        switch self {
        case .cockpit: return NSSize(width: 1000, height: 700)
        // The corridor has no range: its floor IS its designed size, so this
        // must never drift from `targetContentSize`. It was left at 740x520
        // when the window shrank to fit its content, and 740 WON — this
        // value feeds `sizeState`, which becomes the hosted SwiftUI root's
        // `.frame(minWidth:)`, and a root that demands 740 stretches the
        // window past every `contentMinSize`/`contentMaxSize` pin AppKit
        // has. Measured 2026-08-18 off a real render (dot strip as the
        // ruler): the window came up 744pt wide, so the 560pt stage sat in
        // 92pt side margins against a 28pt top inset — the asymmetry the
        // owner caught by eye. MainMenuTests asserted 616 and passed,
        // because it pins the assignment, not the laid-out result.
        case .corridor: return Self.corridorContentSize
        }
    }

    /// The content size to center on when no sane saved frame exists yet
    /// for this mode's own autosave name.
    func targetContentSize(in visible: NSRect) -> NSSize {
        switch self {
        case .cockpit:
            // Scales to the display, clamped to a comfortable reading
            // width (owner 2026-08-09: a stale saved frame had restored a
            // window taller than the screen). `visible` excludes the menu
            // bar and Dock.
            return NSSize(width: min(1180, visible.width * 0.9), height: min(820, visible.height * 0.9))
        case .corridor:
            return Self.corridorContentSize
        }
    }

    /// The corridor's ONE size — floor, ceiling and target are all this, so
    /// they cannot drift from each other again.
    ///
    /// THE WINDOW IS THE CONTENT (owner 2026-08-18: centred content in a
    /// window sized to it, like a mobile app's onboarding). Width is
    /// DERIVED, not chosen:
    /// `FlowLayout.stageMaxWidth` (the corridor's one column) plus its two
    /// `minHorizontalInset` margins — so the side margins equal the top
    /// inset by construction, which is the shape the owner asked for. At
    /// 860 the same column floated in ~244pt of empty stage; sliding it
    /// left removed the misalignment but kept the hole, and the owner
    /// overruled that. Change the column, not this number.
    ///
    /// Height keeps the 2026-08-10 reasoning: the chrome is a fixed 151pt
    /// (28 top inset + 15 progress row + 20 to headline + 24 min gap + 40
    /// footer + 24 bottom inset), and 620 once left a hole under the
    /// sparsest screen. A narrower column wraps more, so the tallest screen
    /// needs measuring, not arithmetic. Read off real renders at this width
    /// (pixel scan for the last non-background row, not an eyeball): ⑤ the
    /// Free/Pro table 342pt, ⑦ the price card 327, ② accounts 316, ⑥ the
    /// reminder 207. 540 leaves 452pt for content after the 24pt min gap,
    /// the 40pt footer and the 24pt bottom inset — 110pt of headroom over
    /// the deepest screen, which is what a busier ② (more accounts, more
    /// signed-out rows) will eat into. Going tighter would trade a cosmetic
    /// hole on the sparse screens for a scrolling corridor on the full
    /// ones, which is the worse defect.
    static let corridorContentSize = NSSize(
        width: FlowLayout.stageMaxWidth + FlowLayout.minHorizontalInset * 2,
        height: 540)
}

/// Content size -> frame size for `win`. `NSWindow.minSize`/`maxSize` are
/// FRAME sizes — title bar included — while every size constant in this file
/// is a CONTENT size (the 2026-08-17 audit measured the cockpit's 1180x820
/// content as an 1180x852 frame: a 32pt bar). One conversion site so the two
/// spellings cannot drift apart.
func cockpitFrameSize(forContent content: NSSize, in win: NSWindow) -> NSSize {
    win.frameRect(forContentRect: NSRect(origin: .zero, size: content)).size
}

/// Mirrors the window's live minimum content size into SwiftUI. The root's
/// own `.frame(minWidth:minHeight:)` floor (the fitting-size collapse
/// workaround — see the CRITICAL note in `open(fleet:api:)`) is otherwise
/// baked in ONCE at hosting-view construction; wrapping it in an
/// `ObservableObject` lets `applyMode` change the floor later, when the
/// window switches between corridor and cockpit mode, without recreating
/// the hosting view.
@MainActor
final class CockpitWindowSizeState: ObservableObject {
    @Published var minSize: NSSize
    init(minSize: NSSize) { self.minSize = minSize }
}

/// Applies `sizeState`'s live minimum to `content` — see
/// `CockpitWindowSizeState`'s doc comment.
private struct SizedRootView<Content: View>: View {
    @ObservedObject var sizeState: CockpitWindowSizeState
    let content: Content

    var body: some View {
        content.frame(minWidth: sizeState.minSize.width, minHeight: sizeState.minSize.height)
    }
}

/// Window plumbing for the app's cockpit window — a shared instance,
/// remembered frame, accessory ↔ regular activation-policy flip on open and
/// close, and RESIZABLE: the native layout reflows, which is one of the
/// immediate native wins the plan named. Chunk 6A cutover: this is now THE
/// app cockpit — the interim web-cockpit window (CockpitWindowController)
/// is gone. The embedded web cockpit itself is unaffected: it still serves
/// CLI/browser users unchanged (web/embed.go, the daemon's webHandler).
final class NativeCockpitWindowController: NSWindowController, NSWindowDelegate {
    static let shared = NativeCockpitWindowController()

    /// On screen AND at least partially unoccluded — same rationale as the
    /// (now-removed) CockpitWindowController.isWindowVisible: cooperative
    /// activation can refuse to surface a window (a fullscreen Space in
    /// front), in which case isVisible alone still reads true while nobody
    /// can see it.
    var isWindowVisible: Bool {
        guard let w = window else { return false }
        return w.isVisible && w.occlusionState.contains(.visible)
    }

    /// Hosted unit tests exercise open() (MainMenuTests) but must not flip
    /// the activation policy, steal focus, or hit a real daemon — same
    /// two-signal discipline as FleetViewModel.sandboxInterlocked's XCTest
    /// half (delta re-review 2026-08-08 Phase 6 P2).
    private var hostedTest: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// The screen the window should size to — an existing window's own
    /// screen, else main. Split out so `open()` reads cleanly.
    private var win_screen: NSScreen? { window?.screen ?? NSScreen.main }

    /// The content size to apply once the window is on screen — see the
    /// note at the end of `open(fleet:api:)`. nil when a sane saved frame
    /// was restored (the user's own size wins).
    private var pendingContentSize: NSSize?

    /// Which surface is currently applied — cockpit until the corridor
    /// flow is reported mounted (`setFlowMode`). See `WindowMode`.
    private var mode: WindowMode = .cockpit
    /// The live CONTENT-size floor and ceiling `windowWillResize` enforces.
    /// `applyMode` is the only writer, so the delegate never re-derives
    /// which surface is up (the corridor pins itself to its own exact
    /// target, which is not `WindowMode.corridor.minSize`). N1, audit
    /// 2026-08-17.
    private var contentFloor: NSSize = WindowMode.cockpit.minSize
    private var contentCeiling: NSSize?
    /// Mirrors `mode.minSize` into the hosted SwiftUI root; see
    /// `CockpitWindowSizeState`.
    private let sizeState = CockpitWindowSizeState(minSize: WindowMode.cockpit.minSize)

    func open(fleet: FleetViewModel, api: (CockpitDaemonAPI & DaemonAPI)? = nil) {
        if window == nil {
            let api = api ?? HTTPDaemonClient()
            mode = .cockpit
            sizeState.minSize = mode.minSize
            let root = NativeCockpitRootView(
                fleet: fleet, cockpit: CockpitViewModel(api: api), api: api,
                onFlowModeChange: { [weak self] isFlow in self?.setFlowMode(isFlow) })
            // EditableWindow, not NSWindow: THE cockpit now hosts paste
            // targets (the license recovery email/code fields, the plan-cost
            // field, the statusline editor) and the deleted web-cockpit
            // window's own rationale still applies — the app-wide Edit menu
            // cannot be relied on to deliver ⌘V here (LoginWindow.swift's
            // comment; review 2026-08-08 Phase 6 P1-2). Sheets are their own
            // windows and ride the main menu's Edit items — pinned by
            // MainMenuTests; a manual ⌘V check in Settings → License is on
            // the ship checklist.
            let visible = (win_screen ?? NSScreen.main)?.visibleFrame
                ?? NSRect(x: 0, y: 0, width: 1180, height: 760)
            let target = mode.targetContentSize(in: visible)
            let win = EditableWindow(
                contentRect: NSRect(origin: .zero, size: target),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            win.title = "llmpilot"
            if let name = mode.autosaveName { win.setFrameAutosaveName(name) }
            applyFloor(mode, ceiling: nil, to: win)
            win.isReleasedWhenClosed = false
            win.delegate = self
            // The WINDOW owns its size, not the SwiftUI content. Left to
            // itself NSHostingView propagates the content's fitting size to
            // the window, and this root — whose sizing resolves to
            // `maxWidth/maxHeight: .infinity` (onboarding canvas, board) —
            // fits at ZERO, collapsing the window to a title-bar sliver
            // (measured live 2026-08-09: 0×0 in CGWindowList, which is why
            // "Open cockpit" looked like it did nothing). Clearing
            // sizingOptions stops that propagation; the hosting view then
            // simply fills whatever frame the window has. Same lesson as
            // LoginWindow's "pinned content view" comment.
            // The root MUST carry a non-zero minimum size. Its sizing
            // otherwise resolves to `maxWidth/maxHeight: .infinity` with
            // Spacers — a ZERO fitting size — and NSHostingView hands that
            // to the window, collapsing the cockpit to a title-bar sliver
            // the instant it appears (measured 2026-08-09: created
            // 1180×852, on-screen 0×0; "Open cockpit" looked dead). A
            // minimum frame is what measurably produced a real window.
            // Pinned with springs-and-struts, the LoginWindow.swift shape
            // ("a pinned content view keeps the 500×680 size"). Routed
            // through `sizeState`/`SizedRootView` rather than a plain
            // `.frame(minWidth:minHeight:)` literal so the floor can move
            // later when `applyMode` switches surfaces, without recreating
            // this hosting view.
            let hosting = NSHostingView(rootView: SizedRootView(sizeState: sizeState, content: root))
            // ACTUALLY clear sizingOptions (macOS 13+). The note above has
            // claimed this since the cutover, but the property was never
            // set, so NSHostingView went on propagating its own fitting
            // size to the window: measured 2026-08-10, the corridor came up
            // 809x642 — neither its designed size NOR the frame saved under
            // its autosave name. Every geometry constant here was dead
            // letter while that propagation was live.
            hosting.sizingOptions = []
            hosting.frame = NSRect(origin: .zero, size: target)
            hosting.autoresizingMask = [.width, .height]
            win.contentView = hosting
            win.setContentSize(target)
            // Restore the saved frame, but never trust it blindly. A frame
            // is only kept when it's SANE — at least the minimum size (owner
            // 2026-08-09: a corrupt 0-width saved frame passed a
            // "<= screen" check and restored an invisible title-bar-only
            // window), no larger than the display, and actually on-screen.
            // Anything else resets to the centered target.
            let restored = mode.autosaveName.map { win.setFrameUsingName($0) } ?? false
            let f = win.frame
            let sane = restored
                && f.width >= mode.minSize.width && f.height >= mode.minSize.height
                && f.width <= visible.width && f.height <= visible.height
                && visible.intersects(f)
            if !sane {
                win.setContentSize(target)
                win.center()
            }
            pendingContentSize = sane ? nil : target
            self.window = win
        }
        // The MenuBarExtra scene can clobber the delegate-installed main
        // menu (AppMainMenu's doc comment — measured); the cockpit's sheets
        // ride the Edit menu for ⌘V, so re-assert at the moment it matters.
        AppMainMenu.install()
        guard !hostedTest else {
            // Tests assert on the constructed window/menu; policy flips and
            // focus steals would leak into the rest of the suite and the
            // developer's session.
            return
        }
        NSApp.setActivationPolicy(.regular)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // SwiftUI's first layout settles this window at the hosting view's
        // minimum, not the size asked for at creation (measured), so the
        // intended size is applied once the window is actually on screen.
        // Only set when there was no sane saved frame to honour — a window
        // the user sized themselves is never fought.
        if let size = pendingContentSize, let win = window {
            win.setContentSize(size)
            win.center()
            pendingContentSize = nil
        }
    }

    /// `NativeCockpitRootView.onFlowModeChange` — corridor while the
    /// first-run/paywall flow is mounted, cockpit otherwise. See
    /// `WindowMode`'s doc comment for why the two carry separate geometry.
    func setFlowMode(_ isFlow: Bool) {
        applyMode(isFlow ? .corridor : .cockpit)
    }

    /// Switches the window to `newMode`'s geometry: saves whatever frame
    /// the OUTGOING mode was left at under its OWN autosave name first (a
    /// resize mid-corridor must not be silently lost the next time that
    /// mode opens), then restores a sane saved frame for the incoming mode
    /// or falls back to its centered default — the same sanity rules
    /// `open()` applies on first construction.
    ///
    /// F16 owner decision (2026-08-16, "keep cockpit resizable... corridor
    /// fixed"): also flips `styleMask`'s `.resizable` bit both ways —
    /// dropped while the corridor is up (so a user can't drag-resize a
    /// one-shot flow that never autosaves its frame), restored on the swap
    /// back to the cockpit (a stale non-resizable mask surviving the swap
    /// would leave the board un-resizable forever, which is exactly F16's
    /// bug: the axis stays clipped with no way to fix it by hand). Corridor
    /// also pins its floor AND ceiling to its exact target content size —
    /// belt-and-braces so AppKit cannot resize it even if `.resizable` ever
    /// leaked back in some other way; the cockpit's ceiling is restored to
    /// AppKit's own unbounded default. Both go through `applyFloor`, which
    /// is also what arms `windowWillResize` — see N1 there.
    private func applyMode(_ newMode: WindowMode) {
        guard let win = window, newMode != mode else { return }
        // This mode's geometry is the last word. `open()` applies
        // `pendingContentSize` AFTER showWindow (SwiftUI settles the window
        // at the hosting minimum first), and the root's own `.onAppear`
        // reports the mode from that same first layout — whichever lands
        // first, the outgoing mode's size must not be re-applied over this
        // one.
        pendingContentSize = nil
        if let outgoing = mode.autosaveName { win.saveFrame(usingName: outgoing) }
        mode = newMode
        sizeState.minSize = newMode.minSize
        // "" turns autosaving OFF for a mode that must not persist a frame.
        win.setFrameAutosaveName(newMode.autosaveName ?? "")
        let visible = win.screen?.visibleFrame ?? win_screen?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1180, height: 760)
        switch newMode {
        case .corridor:
            win.styleMask.remove(.resizable)
            // No saved frame is ever restored here (autosaveName is nil for
            // the corridor) — always the exact designed size, pinned as
            // both the floor and the ceiling so nothing can stretch it.
            let fixed = newMode.targetContentSize(in: visible)
            // The hosted root's own floor must be the size actually applied,
            // never the mode's nominal minimum: `SizedRootView` turns this
            // into `.frame(minWidth:)`, and a root demanding more than the
            // window stretches the window rather than the other way round
            // (measured 2026-08-18 — a stale 740pt corridor minimum made a
            // 616pt window come up 744pt wide).
            sizeState.minSize = fixed
            applyFloor(newMode, floor: fixed, ceiling: fixed, to: win)
            win.setContentSize(fixed)
            win.center()
        case .cockpit:
            win.styleMask.insert(.resizable)
            // The floor is re-applied AFTER the styleMask flip, not only
            // before it: AppKit rebuilds the frame view when `.resizable`
            // changes, and a floor written to the old one is exactly the
            // kind of silent loss N1 looked like from the outside.
            applyFloor(newMode, ceiling: nil, to: win)
            let restored = newMode.autosaveName.map { win.setFrameUsingName($0) } ?? false
            let f = win.frame
            let sane = restored
                && f.width >= newMode.minSize.width && f.height >= newMode.minSize.height
                && f.width <= visible.width && f.height <= visible.height
                && visible.intersects(f)
            if !sane {
                win.setContentSize(newMode.targetContentSize(in: visible))
                win.center()
            }
        }
    }

    /// Writes one surface's size limits into BOTH of AppKit's spellings —
    /// `contentMinSize`/`contentMaxSize` (what this file's constants mean)
    /// and their `minSize`/`maxSize` frame twins — and records them for
    /// `windowWillResize`, which is what actually enforces the floor.
    ///
    /// N1 (audit 2026-08-17): a real edge drag took the shipped 1.3.1
    /// cockpit to 226x231 — the header row vanished and body text was cut
    /// mid-word at BOTH edges — while `win.minSize` read 1000x700 the whole
    /// time (MainMenuTests asserted exactly that, and passed).
    ///
    /// MECHANISM, settled by experiment 2026-08-18, not by reasoning. With
    /// `windowWillResize` removed but BOTH spellings written correctly
    /// (`contentMinSize` 1000x700 AND `minSize` 1000x732),
    /// `scripts/e2e-real-resize.sh` still reached **228pt**. So AppKit's
    /// min/max properties are ADVISORY for this window — the delegate is
    /// what enforces, and everything this function writes is agreement, not
    /// enforcement. Two corollaries worth keeping: the content-vs-frame
    /// mix-up this also fixes was never the cause (a 1000pt frame floor
    /// cannot yield 226pt either), and `contentMinSize` is no better than
    /// `minSize` here. The likely reason is this window's content view — an
    /// `NSHostingView` with `sizingOptions = []`, a constraint-based view
    /// that publishes no size of its own — but that is inference; the
    /// measured fact is the 228pt above.
    ///
    /// Re-run the experiment before deleting `windowWillResize`: comment it
    /// out and run the gate. If it still stops at 1000, AppKit's behaviour
    /// changed and this can shrink.
    private func applyFloor(_ m: WindowMode, floor: NSSize? = nil, ceiling: NSSize?, to win: NSWindow) {
        let low = floor ?? m.minSize
        contentFloor = low
        contentCeiling = ceiling
        win.contentMinSize = low
        win.minSize = cockpitFrameSize(forContent: low, in: win)
        let unbounded = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        win.contentMaxSize = ceiling ?? unbounded
        win.maxSize = ceiling.map { cockpitFrameSize(forContent: $0, in: win) } ?? unbounded
    }

    /// `windowWillResize`'s whole body as a pure function of FRAME sizes —
    /// split out so the arithmetic is pinned by a test that needs no
    /// window, no display and no drag. That test pins THIS FUNCTION ONLY —
    /// it would pass unchanged if the delegate were never invoked, so it is
    /// not evidence that the floor holds. The only evidence for that is
    /// `scripts/e2e-real-resize.sh`, which posts a real drag (the AX suites
    /// cannot see a live resize at all — the same blind spot that hid F18).
    static func clampedFrameSize(_ proposed: NSSize, floor: NSSize, ceiling: NSSize?) -> NSSize {
        var w = max(proposed.width, floor.width)
        var h = max(proposed.height, floor.height)
        if let ceiling {
            w = min(w, ceiling.width)
            h = min(h, ceiling.height)
        }
        return NSSize(width: w, height: h)
    }

    /// N1: the cockpit's 1000x700 floor, enforced where AppKit actually
    /// asks — USER-DRIVEN resizes (a live edge/corner drag) and `zoom`.
    /// NOT programmatic frame changes: `setFrame(_:display:)` skips the
    /// delegate, and `setContentSize`, `setFrameUsingName` and `center`
    /// all go through it, so those rely on `applyFloor`'s property writes
    /// instead. Nothing here depends on that distinction — it is recorded
    /// because an earlier version of this comment got it wrong, which is
    /// the same class of assumption that produced N1.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        Self.clampedFrameSize(
            frameSize,
            floor: cockpitFrameSize(forContent: contentFloor, in: sender),
            ceiling: contentCeiling.map { cockpitFrameSize(forContent: $0, in: sender) })
    }

    func windowWillClose(_ notification: Notification) {
        guard !hostedTest else { return }
        // LSUIElement app: fall back to accessory when this window closes —
        // UNLESS a sign-in window is up (the cockpit's own Add-account paths
        // open LoginWindowController from here now; demoting mid-OAuth would
        // strand a live sign-in webview with no Dock icon to return to —
        // review 2026-08-08 Phase 6 P2-7). LoginWindowController's own
        // windowWillClose holds the reciprocal half: it demotes when IT
        // closes last. A CheckoutSheet is a modal sheet on THIS window,
        // never a separate top-level one — no check needed.
        let login = LoginWindowController.shared.window
        if !(login?.isVisible == true || login?.isMiniaturized == true) {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

/// One inset ring for every cockpit sheet (owner 2026-08-13, HIG dialog
/// layout: EQUAL margins on the sides and bottom — the classic metrics say
/// 20px, action button bottom-right, ≥16px between the content and the
/// bottom controls). The old shape double-padded: each sheet body carried
/// its own root padding INSIDE the wrapper's 16pt, so content sat 32-36pt
/// from the top/left edge while Close sat 16pt from the bottom-right — the
/// asymmetry the owner's walk caught. This chrome is now the ONLY inset
/// owner; the sheet bodies it wraps ship edge-to-edge.
struct SheetChrome<Content: View>: View {
    var width: CGFloat? = nil
    var minWidth: CGFloat? = nil
    var minHeight: CGFloat? = nil
    let onClose: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            content()
            HStack {
                Spacer()
                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: width)
        .frame(minWidth: minWidth, minHeight: minHeight)
    }
}
