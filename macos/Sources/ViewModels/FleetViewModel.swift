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
    @Published private(set) var adoptingDir: String?
    @Published var lastError: String?
    @Published var now = Date()

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
    var openWindow: (URL) -> Void = { url in
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
        else { return }
        CockpitWindowController.shared.open(url: url)
    }

    static let firstLaunchKey = "firstLaunchWindowShown"

    private var ensureInFlight = false

    init(api: DaemonAPI, trialMarker: TrialMarkerStore = KeychainTrialMarker(), autostart: Bool = true) {
        self.api = api
        self.trialMarker = trialMarker
        if autostart {
            start()
            Task { await self.ensureRunning() }
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
            detected = (try? await api.detect()) ?? []
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

    static let daemonUnreachableError =
        "the daemon never became reachable — run `llmpilot daemon status` in a terminal"

    /// Auto-open the cockpit window exactly once EVER. The flag is set only
    /// here — at a successful state fetch — never on a failed start, so a
    /// daemon that fails to come up cannot burn the one auto-open. Flushed
    /// synchronously so an immediate app kill can't lose it.
    private func maybeAutoOpenWindow() {
        guard !defaults.bool(forKey: Self.firstLaunchKey) else { return }
        guard let url = api.cockpitURL() else { return }
        defaults.set(true, forKey: Self.firstLaunchKey)
        defaults.synchronize()
        openWindow(url)
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

    func adopt(_ dir: String) async {
        adoptingDir = dir
        lastError = nil
        defer { adoptingDir = nil }
        do {
            try await api.adopt(configDir: dir)
            try? await refresh()
        } catch {
            lastError = error.localizedDescription
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
        for _ in 0..<20 {
            if (try? await refresh()) != nil { return }
            try? await Task.sleep(nanoseconds: startupProbeNanos)
        }
        status = .down
        lastError = Self.daemonUnreachableError
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
        let threshold = Int((autopilot.thresholdPercent ?? 90).rounded())
        return "autopilot on · switches at \(threshold)%"
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
