import Foundation
import SwiftUI

@MainActor
final class FleetViewModel: ObservableObject {
    enum Status: Equatable {
        case connecting
        case starting // ensure-running in flight — transient, never an error
        case live
        case down
    }

    /// A start the app must not attempt — each gets a dedicated popover state.
    enum StartGate: Equatable {
        case requiresApproval // BTM holds the agent (or the user revoked it)
        case moveToApplications // translocated or running off the DMG
    }

    enum IconMode: String, CaseIterable, Identifiable {
        case ring        // default: 5h/weekly gauge at a glance
        case percent     // compact "23%"
        case bars        // tiny runway bars
        case iconOnly

        var id: String { rawValue }
        var label: String {
            switch self {
            case .ring: return "Ring gauge"
            case .percent: return "Compact %"
            case .bars: return "Runway bars"
            case .iconOnly: return "Icon only"
            }
        }
    }

    @Published private(set) var state: DaemonState?
    @Published private(set) var status: Status = .connecting
    @Published private(set) var startGate: StartGate?
    @Published private(set) var startAtLogin = false
    @Published private(set) var autopilot: DaemonConfig.Autopilot?
    @Published private(set) var switchingID: String?
    @Published private(set) var detected: [DetectedDir] = []
    /// Whether /v1/detect has answered at least once this session — the
    /// corridor distinguishes "still detecting" from "found nothing" on
    /// this (review 2026-08-11 P2-8).
    @Published private(set) var detectAnswered = false
    @Published private(set) var adoptingDir: String?
    @Published var lastError: String?
    @Published var now = Date()
    /// Set by the menu bar's upsell row: "the user wants the autopilot" —
    /// NOT "open the paywall". NativeCockpitRootView.consumePendingPaywall
    /// clears it once a license is resolved and routes by the FLOW decision:
    /// the first-run corridor when it holds (the flag is consumed by the
    /// flow already teaching-then-asking), the reopened paywall only for a
    /// board-visible user. A flag rather than a direct call because
    /// `openPaywall()` is private to that view and needs state
    /// (`cockpit.license`) this view model doesn't have.
    @Published var pendingOpenPaywall = false

    @AppStorage("privacyMode") var privacyMode = false
    @AppStorage("iconMode") private var iconModeRaw = IconMode.ring.rawValue

    var iconMode: IconMode {
        get { IconMode(rawValue: iconModeRaw) ?? .ring }
        set { iconModeRaw = newValue.rawValue }
    }

    private let api: DaemonAPI
    private let trialMarker: TrialMarkerStore
    private var markerReported = false
    private var loop: Task<Void, Never>?
    private var ticker: Task<Void, Never>?

    /// Injectable for tests — production launches via launchd.
    var launch: @Sendable () -> String? = { DaemonLauncher.start() }
    /// Bounces the daemon's launchd job. Injectable so the staleness check is
    /// testable without touching the real service.
    var restartAgent: @Sendable () -> String? = { DaemonLauncher.restartAgent() }
    /// What the daemon's launchd job is executing. Injectable so the
    /// staleness check is testable without a real job.
    var daemonExecutable: @Sendable () -> DaemonLauncher.DaemonExecutable = {
        DaemonLauncher.runningDaemonExecutable()
    }
    /// This bundle's path, injectable for the same reason.
    var bundlePath: String = Bundle.main.bundleURL.path
    /// One bounce per app launch: if the restart does not resolve it, the
    /// problem is not a stale process and retrying would loop.
    private var restartedThisLaunch = false
    var startupProbeNanos: UInt64 = 500_000_000
    /// Injectable ServiceManagement seam — tests never touch the real BTM.
    var loginItems: LoginItems = LoginItemsFactory.make()
    /// Legacy CLI-installed plist at ~/Library/LaunchAgents — when present it
    /// owns the label; registering on top silently loses to it (verified on
    /// macOS 26.5: register() reports enabled while launchd keeps the legacy
    /// definition, and unregister() then fails).
    var legacyPlistPresent: @Sendable () -> Bool = {
        FileManager.default.fileExists(
            atPath: DaemonLauncher.userHome() + "/Library/LaunchAgents/dev.llmpilot.daemon.plist")
    }
    /// Translocated or on a read-only (DMG) volume: registering would pin a
    /// doomed path, so the app must ask to be moved to Applications instead.
    var bundleLocationBlocked: @Sendable () -> Bool = {
        let path = Bundle.main.bundlePath
        if path.contains("/AppTranslocation/") { return true }
        if let v = try? URL(fileURLWithPath: path)
            .resourceValues(forKeys: [.volumeIsReadOnlyKey]),
            v.volumeIsReadOnly == true
        {
            return true
        }
        return false
    }
    /// Whether this bundle is an INSTALLED copy — `/Applications` or the
    /// per-user `~/Applications`. Gates the stale-enrollment re-enroll in
    /// `ensureRunning`: that repair rewrites the user's LaunchAgent to this
    /// bundle's path, which is only ever the right answer for a copy that
    /// lives where an installed app lives. Injectable so both branches are
    /// testable without moving the test runner.
    var bundleIsInstalled: @Sendable () -> Bool = {
        let path = Bundle.main.bundlePath
        return path.hasPrefix("/Applications/")
            || path.hasPrefix(DaemonLauncher.userHome() + "/Applications/")
    }
    /// First-launch flag store + window opener, injectable for tests. The
    /// default opener no-ops under XCTest so hosted unit tests never spawn a
    /// real cockpit window. cfprefsd keys UserDefaults by uid + bundle id and
    /// IGNORES a sandboxed $HOME (verified), so e2e runs isolate the flag via
    /// a throwaway suite named in LLMPILOT_DEFAULTS_SUITE instead.
    var defaults: UserDefaults = {
        if let suite = ProcessInfo.processInfo.environment["LLMPILOT_DEFAULTS_SUITE"],
           !suite.isEmpty, let d = UserDefaults(suiteName: suite)
        {
            return d
        }
        return .standard
    }()
    /// The URL argument is unused since the chunk 6A cutover — kept so tests
    /// injecting this seam (and the readiness check in maybeAutoOpenWindow)
    /// don't need to change — but production wiring lives in init(), which
    /// needs `self` to hand to NativeCockpitWindowController.open(fleet:).
    var openWindow: (URL) -> Void = { _ in }

    static let firstLaunchKey = "firstLaunchWindowShown"
    static let startAtLoginDefaultedKey = "startAtLoginDefaulted"

    private var ensureInFlight = false

    init(api: DaemonAPI, trialMarker: TrialMarkerStore = KeychainTrialMarker(), autostart: Bool = true) {
        self.api = api
        self.trialMarker = trialMarker
        // Chunk 6A cutover: the native window is now THE app cockpit.
        // Assigned here (not as the property's default value) because it
        // needs `self` — a property initializer runs before `self` exists.
        // Tests override this seam directly, so the XCTest guard below is
        // defense in depth, not the only thing stopping a hosted test from
        // spawning a real window.
        openWindow = { [weak self] _ in
            guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
            else { return }
            guard let self else { return }
            NativeCockpitWindowController.shared.open(fleet: self)
        }
        if autostart {
            start()
            // Parallel tasks: ensureRunning must set its in-flight flag
            // immediately (connectOnce suppresses the down-flash only while
            // it holds), and a slow first BTM registration must never delay
            // it.
            Task { await self.ensureRunning() }
            Task { await self.defaultStartAtLoginOnce() }
        }
    }

    deinit {
        loop?.cancel()
        ticker?.cancel()
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.connectOnce()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        ticker = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                self.now = Date()
            }
        }
    }

    /// One connection lifetime: initial fetch, then ride SSE until it drops.
    private func connectOnce() async {
        do {
            try await refresh()
            dlog("refresh ok — riding SSE")
            for try await s in api.events() {
                apply(s)
            }
            dlog("SSE stream ended")
        } catch {
            dlog("connect failed: \(error)")
            // While ensure-running is in flight the popover shows the
            // transient "starting…" state — a failed poll at t≈0 must not
            // clobber it with "daemon not running".
            if !ensureInFlight { status = .down }
        }
    }

    /// Diagnostics only, env-gated, never on by default; logs states and
    /// error strings — no account data.
    private nonisolated func dlog(_ msg: String) {
        guard let path = ProcessInfo.processInfo.environment["LLMPILOT_DEBUG_LOG"],
              !path.isEmpty else { return }
        let line = "\(Date()) \(msg)\n"
        if let h = FileHandle(forWritingAtPath: path) {
            defer { try? h.close() }
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
        } else {
            try? line.write(toFile: path, atomically: false, encoding: .utf8)
        }
    }

    /// Sandbox interlock: launchctl ignores $HOME, so the gui domain the
    /// stale check probes — and `kickstart -k` SIGKILLs — is always the REAL
    /// user's `dev.llmpilot.daemon`, even when the app runs inside an e2e
    /// sandbox with a fake HOME and its own fixture daemon. A sandboxed run
    /// seeing the developer's live /Applications daemon as "stale" would
    /// bounce it mid-credential-write (the #1 hazard window).
    ///
    /// XCTest engages it too: hosted unit tests call ensureRunning() through
    /// helpers that stub the API but not this seam's defaults, and the real
    /// launchctl probe then judged the developer's live daemon stale against
    /// the TEST-HOST bundle path — every `xcodebuild test` run was bouncing
    /// it (proven live 2026-08-07, pids 7587→35775). Tests that exercise the
    /// bounce paths set this to false explicitly and inject both seams.
    /// DaemonLauncher.launchdMutationRefusal is the floor beneath this seam.
    var sandboxInterlocked: Bool =
        ProcessInfo.processInfo.environment["LLMPILOT_TEST"] == "1"
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// Sparkle replaces the app bundle in place but never restarts the
    /// daemon: it is a separate launchd job, so it keeps executing the
    /// PREVIOUS build out of the bundle the updater moved aside, and the user
    /// drives new app code against a stale daemon with nothing to show for it.
    ///
    /// This deliberately does NOT key on the version the daemon reports. A
    /// daemon old enough to be stale is old enough to predate that field —
    /// which is exactly the case on the first update carrying this code — so
    /// a version comparison can never fire when it is most needed.
    ///
    /// Nor does it require a readable path. 1.2.2 asked for one and treated
    /// its absence as "no mismatch", but the updater deletes the bundle it
    /// moved aside, so by the time the new app asks, the stale daemon's
    /// executable is gone and there is no path to compare. A vanished
    /// executable IS the signal.
    func restartStaleDaemon() async {
        guard !sandboxInterlocked else { return }
        guard !restartedThisLaunch else { return }
        let probe = self.daemonExecutable
        let state = await Task.detached(operation: { probe() }).value
        guard DaemonLauncher.isStale(state, ourBundle: bundlePath) else { return }
        restartedThisLaunch = true
        let restart = self.restartAgent
        _ = await Task.detached { restart() }.value
        _ = try? await refresh()
    }

    func refresh() async throws {
        do {
            let s = try await api.state()
            apply(s)
            await reportMarkerOnce()
            autopilot = try? await api.config().autopilot
            // Detected is a cheap filesystem + config read on the daemon
            // side (no Keychain, no network) — fetch it every refresh so
            // OTHER Claude sign-ins on the Mac stay visible after the first
            // account is adopted, not just while the fleet is empty.
            // A FAILED re-detect keeps the last known answer rather than
            // blanking it, and `detectAnswered` records that a first answer
            // exists at all — the corridor's accounts step renders a real
            // "Finding your accounts…" state off that instead of flashing
            // the empty state during the gap (review 2026-08-11 P2-8: the
            // non-optional `[]` default made that state unreachable).
            if let d = try? await api.detect() {
                detected = d
                detectAnswered = true
            }
        } catch {
            // An action-triggered refresh must not downgrade a live SSE
            // connection — only the connect loop decides "down" once live.
            // And while ensure-running is starting the daemon, its probe
            // failures stay under the transient .starting state.
            if status != .live, !ensureInFlight { status = .down }
            throw error
        }
    }

    private func apply(_ s: DaemonState) {
        state = s
        status = .live
        startGate = nil
        // A live state means the daemon IS reachable, so a prior startup
        // "never became reachable" error is stale — clear only that one, so
        // real action errors (switch, login item) still surface.
        if lastError == Self.daemonUnreachableError { lastError = nil }
        now = Date()
        maybeAutoOpenWindow()
    }

    // App-voice, no plumbing shouting: the failure card already says what
    // to do (Try again); this is the persistent-case escalation detail.
    static let daemonUnreachableError =
        "The engine started but never answered. If this keeps happening, `llmpilot daemon status` in a terminal shows why."

    /// Auto-open the cockpit window exactly once EVER — but burn the one-shot
    /// only after the window is confirmed VISIBLE. macOS cooperative
    /// activation can refuse to surface it (a fullscreen Space in front), and
    /// a flag burned on an unseen window loses the first-run explainer
    /// forever (hit live 2026-07-30: the window opened behind a fullscreen
    /// terminal). A failed daemon start still cannot burn it (unchanged);
    /// a refused surface retries on the next launch. In-run repeats are
    /// stopped by `autoOpenAttempted`, not the flag.
    private var autoOpenAttempted = false
    var windowVisible: () -> Bool = { NativeCockpitWindowController.shared.isWindowVisible }
    /// Sampled more than once: the user may cmd-tab back a few seconds after
    /// launch — one early sample would miss that, never burn the flag, and
    /// reopen the window on every launch.
    var visibilitySampleDelays: [TimeInterval] = [1.5, 5, 15]
    // @MainActor-typed rather than plain: the work always runs on main (it
    // reads window state and writes defaults), and this is what lets the
    // closure cross into the delayed dispatch without tripping strict
    // Sendable checking (the Xcode-surfaced warning, 2026-08-08).
    var scheduleVisibilityCheck: (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, work in
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            work()
        }
    }

    private func maybeAutoOpenWindow() {
        guard !autoOpenAttempted else { return }
        guard !defaults.bool(forKey: Self.firstLaunchKey) else { return }
        guard let url = api.cockpitURL() else { return }
        autoOpenAttempted = true
        openWindow(url)
        sampleVisibility(0)
    }

    private func sampleVisibility(_ attempt: Int) {
        guard attempt < visibilitySampleDelays.count else { return }
        scheduleVisibilityCheck(visibilitySampleDelays[attempt]) { [weak self] in
            guard let self else { return }
            if self.windowVisible() {
                self.defaults.set(true, forKey: Self.firstLaunchKey)
                self.defaults.synchronize()
            } else {
                self.sampleVisibility(attempt + 1)
            }
        }
    }

    func switchTo(_ id: String) async {
        guard switchingID == nil else { return }
        switchingID = id
        lastError = nil
        defer { switchingID = nil }
        do {
            try await api.switchAccount(to: id)
            try? await refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Reports whether the adopt LANDED — the onboarding corridor's
    /// automatic adoption shows a failure line off this (audit 2026-08-11:
    /// its screen claims "llmpilot is adding them", and a refusal used to
    /// surface only as the board's flash banner after the corridor closed).
    @discardableResult
    func adopt(_ dir: String) async -> Bool {
        adoptingDir = dir
        lastError = nil
        defer { adoptingDir = nil }
        do {
            try await api.adopt(configDir: dir)
            try? await refresh()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// The ensure-running state machine — runs at app launch and again from
    /// the popover's "Start daemon" button (same path, by design):
    /// (1) daemon reachable → done. (2) translocated/DMG → honest move state,
    /// start nothing. (3) legacy CLI plist present → bootstrap through the
    /// proven legacy path, never SMAppService on top of it. (4) else
    /// SMAppService.agent register; requiresApproval gets its own state and
    /// is never loop-registered; any other refusal falls back to the legacy
    /// path. Then poll /v1/state ~10 s under the transient .starting status.
    func ensureRunning() async {
        guard !ensureInFlight else { return }
        ensureInFlight = true
        defer { ensureInFlight = false }
        lastError = nil
        startGate = nil
        if status != .live { status = .starting }

        if (try? await refresh()) != nil {
            await restartStaleDaemon()
            return
        }

        if bundleLocationBlocked() {
            startGate = .moveToApplications
            status = .down
            return
        }

        if legacyPlistPresent() {
            let launch = self.launch
            if let err = await Task.detached { launch() }.value {
                lastError = err
                status = .down
                return
            }
        } else {
            let items = loginItems
            let registerError = await Task.detached { () -> Error? in
                do {
                    try items.registerAgent()
                    return nil
                } catch {
                    return error
                }
            }.value
            let agentStatus = await Task.detached { items.agentStatus() }.value
            if registerError != nil {
                // No error-code guessing: consult status. Already-enabled is
                // fine (agent registered by an earlier run); approval gets
                // its own state; anything else means BTM refused this build
                // — fall back to the legacy CLI path.
                switch agentStatus {
                case .enabled:
                    break
                case .requiresApproval:
                    startGate = .requiresApproval
                    status = .down
                    return
                default:
                    let launch = self.launch
                    if let err = await Task.detached { launch() }.value {
                        lastError = err
                        status = .down
                        return
                    }
                }
            } else if agentStatus == .requiresApproval {
                // register() can also park the agent awaiting approval
                // without throwing — surface it, never loop-register.
                startGate = .requiresApproval
                status = .down
                return
            }
        }

        // launchd needs a beat to bring the socket up.
        if await probeUntilLive() { return }

        // One-shot repair: an agent that reports .enabled yet never spawns
        // is a STALE enrollment — launchd still points at a moved or
        // rebuilt bundle (hit live 2026-08-08: "spawn scheduled" forever at
        // a DerivedData path after Xcode runs). Re-enroll from THIS bundle
        // and give the socket one more window before giving up.
        // ...but ONLY from an installed bundle. Re-enrolling rewrites the
        // user's LaunchAgent to point at whatever bundle is running, so an
        // un-installed copy — above all a DerivedData build, which launchd
        // refuses to spawn because it is ad-hoc signed — would destroy a
        // working /Applications enrollment while fixing nothing. A build
        // that can't be spawned must fail loudly, not take the real one
        // down with it.
        let items = loginItems
        let staleStatus = await Task.detached { items.agentStatus() }.value
        if staleStatus == .enabled, bundleIsInstalled() {
            _ = await Task.detached {
                try? items.unregisterAgent()
                try? items.registerAgent()
            }.value
            if await probeUntilLive() { return }
        }

        status = .down
        lastError = Self.daemonUnreachableError
    }

    /// Poll /v1/state briefly while launchd brings the agent's socket up.
    private func probeUntilLive() async -> Bool {
        for _ in 0..<20 {
            if (try? await refresh()) != nil { return true }
            try? await Task.sleep(nanoseconds: startupProbeNanos)
        }
        return false
    }

    /// First run defaults the login item ON (owner, SPEC 1.2.6): the daemon
    /// auto-registers its agent, but the menu bar app never registered
    /// itself — after a reboot the icon was gone and the app looked broken.
    /// One-shot; the gear toggle owns every later change (System Settings
    /// revocations included — this never re-registers). Never from a
    /// translocated/DMG launch: registering there would pin a doomed path,
    /// so the unburned key retries once the app runs from Applications.
    func defaultStartAtLoginOnce() async {
        guard !defaults.bool(forKey: Self.startAtLoginDefaultedKey) else { return }
        guard !bundleLocationBlocked() else { return }
        let prior = lastError
        await setStartAtLogin(true)
        // A refused BACKGROUND default stays quiet — the user pressed
        // nothing, so a red popover line here reads as breakage. The retry
        // rides the next launch; the gear toggle still reports ITS failures.
        if !startAtLogin { lastError = prior }
        // Burn the one-shot only on a CONFIRMED registration — a throw or a
        // crash mid-call must retry next launch, not silently lose the
        // default forever (the exact bug this exists to fix). A user who
        // later disables it in System Settings is safe: the key burned the
        // moment it was enabled.
        if startAtLogin {
            defaults.set(true, forKey: Self.startAtLoginDefaultedKey)
        }
    }

    /// The gear toggle state. Read fresh when the popover opens — System
    /// Settings can revoke the login item behind the app's back.
    func refreshLoginItemState() {
        let items = loginItems
        Task {
            let s = await Task.detached { items.mainAppStatus() }.value
            startAtLogin = s == .enabled
        }
    }

    func setStartAtLogin(_ on: Bool) async {
        let items = loginItems
        let err = await Task.detached { () -> String? in
            do {
                try items.setMainApp(enabled: on)
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value
        if let err { lastError = "could not update the login item — \(err)" }
        startAtLogin = await Task.detached { items.mainAppStatus() }.value == .enabled
    }

    /// Report the native no-card-trial marker once the daemon is reachable, so
    /// it hides that ladder rung across the fleet. One-shot; the Keychain read
    /// runs off the main actor. A report failure is non-fatal — the marker is
    /// only a best-effort effort bar (the no-card rung is the accepted-risk
    /// bottom of the ladder), never an authoritative gate.
    private func reportMarkerOnce() async {
        guard !markerReported else { return }
        markerReported = true
        let marker = trialMarker
        let present = await Task.detached { marker.isPresent() }.value
        try? await api.reportMarker(present: present)
    }

    // MARK: - Derived

    var accounts: [AccountState] { state?.accounts ?? [] }

    /// Preserved foreign credentials awaiting a decision (adopt/discard
    /// lives in the cockpit; the menu bar surfaces that they exist).
    var stash: [StashEntry] { state?.stash ?? [] }

    /// Other logged-in Claude Code accounts on this Mac that aren't part of
    /// the fleet yet — the destructive move lives in the cockpit; the menu
    /// bar only surfaces that they exist so nothing goes invisible.
    var unadoptedDetectedCount: Int { detected.filter { !$0.registered }.count }

    var cockpitURL: URL? { api.cockpitURL() }

    /// The official app always ships the engine, so an absent/expired grant is
    /// an upsell moment: show "Turn on the autopilot" until Pro is active.
    var licensed: Bool { state?.licensed ?? false }
    var showUpsell: Bool { status == .live && !licensed }
    var proLine: String? {
        switch state?.license {
        case "trialing": return "Pro — trial"
        case "lifetime": return "Pro"
        default: return nil
        }
    }

    func displayName(for account: AccountState) -> String {
        guard privacyMode else {
            return account.email.isEmpty ? account.label : account.email
        }
        let idx = accounts.firstIndex(where: { $0.id == account.id }) ?? 0
        return Format.alias(index: idx, of: accounts.count)
    }

    func isActive(_ account: AccountState) -> Bool { account.id == state?.activeID }

    /// Stale when the freshest snapshot is over 5 minutes old (daemon polls
    /// each account at least every 300 s when healthy).
    var staleLabel: String? {
        guard status == .live else { return nil }
        let newest = accounts.compactMap { $0.snapshot?.asOf }.max()
        guard let newest, now.timeIntervalSince(newest) > 300 else { return nil }
        guard let stamp = Format.asOf(newest, now: now) else { return nil }
        return "\(stamp) — showing last known, not live"
    }

    var autopilotLine: String {
        guard let autopilot else { return "autopilot —" }
        if autopilot.disabled == true { return "autopilot off" }
        // No explicit threshold = adaptive time-to-wall (owner
        // 2026-08-13). The old `?? 90` fabricated a number the autopilot
        // no longer uses — a default install would have read a false 90
        // (review P1); only a user-set fixed threshold names a percent.
        guard let percent = autopilot.thresholdPercent else {
            return "autopilot on · switches before the wall"
        }
        return "autopilot on · switches at \(Int(percent.rounded()))%"
    }

    /// What the collapsed menu-bar icon renders: the ACTIVE account's session
    /// and worst weekly percent (nil percents when nothing is known).
    var iconGauge: (session: Int?, weekly: Int?) {
        guard let active = accounts.first(where: { isActive($0) }) ?? accounts.first,
              let buckets = active.snapshot?.buckets
        else { return (nil, nil) }
        let session = buckets.first(where: { $0.kind == "session" })?.percentInt
        let weekly = buckets.filter { $0.kind.hasPrefix("weekly") }
            .map(\.percentInt).max()
        return (session, weekly)
    }
}
