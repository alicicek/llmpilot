import Foundation
import SwiftUI

@MainActor
final class FleetViewModel: ObservableObject {
    enum Status: Equatable {
        case connecting
        case live
        case down
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
    var startupProbeNanos: UInt64 = 500_000_000

    init(api: DaemonAPI, trialMarker: TrialMarkerStore = KeychainTrialMarker(), autostart: Bool = true) {
        self.api = api
        self.trialMarker = trialMarker
        if autostart { start() }
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
            status = .down
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

    func refresh() async throws {
        do {
            let s = try await api.state()
            apply(s)
            await reportMarkerOnce()
            autopilot = try? await api.config().autopilot
            if s.accounts.isEmpty {
                detected = (try? await api.detect()) ?? []
            }
        } catch {
            // An action-triggered refresh must not downgrade a live SSE
            // connection — only the connect loop decides "down" once live.
            if status != .live { status = .down }
            throw error
        }
    }

    private func apply(_ s: DaemonState) {
        state = s
        status = .live
        now = Date()
        if !s.accounts.isEmpty { detected = [] }
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

    func startDaemon() async {
        lastError = nil
        let launch = self.launch
        let launchError = await Task.detached { launch() }.value
        if let launchError {
            lastError = launchError
            return
        }
        // launchd needs a beat to bring the socket up.
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: startupProbeNanos)
            if (try? await refresh()) != nil { return }
        }
        lastError = "daemon installed but never became reachable — run `llmpilot daemon status` in a terminal"
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
        return "autopilot on · rotates at \(threshold)%"
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
