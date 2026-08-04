import Foundation
@testable import llmpilot

/// Scriptable DaemonAPI stub — the unit-test stand-in for the daemon.
final class StubAPI: DaemonAPI, @unchecked Sendable {
    var stateResult: Result<DaemonState, Error> = .failure(DaemonError.down)
    var switchResult: Result<Void, Error> = .success(())
    var detectResult: [DetectedDir] = []
    var configResult = DaemonConfig(autopilot: nil)
    var base: URL? = URL(string: "http://127.0.0.1:59999")
    var startLoginResult: Result<LoginStart, Error> =
        .success(LoginStart(authorizeURL: "https://claude.com/cai/oauth/authorize?state=st-1", state: "st-1"))
    var completeLoginResult: Result<Void, Error> = .success(())

    private(set) var switchedTo: [String] = []
    private(set) var adopted: [String] = []
    private(set) var markerReports: [Bool] = []
    private(set) var startedLogins = 0
    private(set) var completedLogins: [(code: String, state: String)] = []
    /// Applied to stateResult after a successful switch, so refresh() sees it.
    var stateAfterSwitch: DaemonState?

    func baseURL() -> URL? { base }

    func state() async throws -> DaemonState { try stateResult.get() }

    func switchAccount(to id: String) async throws {
        try switchResult.get()
        switchedTo.append(id)
        if let after = stateAfterSwitch { stateResult = .success(after) }
    }

    func detect() async throws -> [DetectedDir] { detectResult }

    func adopt(configDir: String) async throws { adopted.append(configDir) }

    func config() async throws -> DaemonConfig { configResult }

    func reportMarker(present: Bool) async throws { markerReports.append(present) }

    func startLogin() async throws -> LoginStart {
        startedLogins += 1
        return try startLoginResult.get()
    }

    func completeLogin(code: String, state: String) async throws {
        completedLogins.append((code, state))
        try completeLoginResult.get()
    }

    func events() -> AsyncThrowingStream<DaemonState, Error> {
        AsyncThrowingStream { $0.finish(throwing: DaemonError.down) }
    }
}

/// Scriptable ServiceManagement seam — tests never touch the real BTM
/// database (a real register() would enroll a login item on the dev Mac).
final class FakeLoginItems: LoginItems, @unchecked Sendable {
    struct Refused: Error {}
    var agentStatusValue: LoginItemStatus = .notRegistered
    var registerShouldThrow = false
    /// Runs on a successful register — e.g. flip the stub API to reachable.
    var onRegister: (@Sendable () -> Void)?
    var mainStatus: LoginItemStatus = .notRegistered
    var setMainShouldThrow = false
    private(set) var registerCalls = 0
    private(set) var mainSets: [Bool] = []
    private(set) var openedSettings = 0

    func agentStatus() -> LoginItemStatus { agentStatusValue }

    func registerAgent() throws {
        registerCalls += 1
        if registerShouldThrow { throw Refused() }
        onRegister?()
    }

    func mainAppStatus() -> LoginItemStatus { mainStatus }

    func setMainApp(enabled: Bool) throws {
        mainSets.append(enabled)
        if setMainShouldThrow { throw Refused() }
        mainStatus = enabled ? .enabled : .notRegistered
    }

    func openLoginItemsSettings() { openedSettings += 1 }
}

/// In-memory trial marker — tests never touch the real Keychain.
final class StubTrialMarker: TrialMarkerStore, @unchecked Sendable {
    var present: Bool
    private(set) var marked = false
    init(present: Bool = false) { self.present = present }
    func isPresent() -> Bool { present }
    @discardableResult func mark() -> Bool { marked = true; present = true; return true }
}

enum Fixtures {
    static func bucket(kind: String, scope: String? = nil, percent: Double,
                       resetsAt: Date? = nil, active: Bool? = nil) -> Bucket {
        Bucket(kind: kind, scope: scope, percent: percent,
               resetsAt: resetsAt, severity: nil, active: active)
    }

    static func account(id: String, label: String, email: String,
                        pinned: Bool = false, buckets: [Bucket]? = nil,
                        asOf: Date = Date()) -> AccountState {
        AccountState(id: id, label: label, email: email, pinned: pinned,
                     snapshot: buckets.map { UsageSnapshot(asOf: asOf, buckets: $0) },
                     tokenNote: nil)
    }

    static func twoAccounts(now: Date = Date()) -> DaemonState {
        DaemonState(
            accounts: [
                account(id: "acct-a", label: "a", email: "a@example.dev",
                        buckets: [
                            bucket(kind: "session", percent: 23,
                                   resetsAt: now.addingTimeInterval(3600), active: true),
                            bucket(kind: "weekly_all", percent: 41),
                            bucket(kind: "weekly_scoped", scope: "Fable", percent: 67),
                        ], asOf: now),
                account(id: "acct-b", label: "b", email: "b@example.dev",
                        buckets: [
                            bucket(kind: "session", percent: 92,
                                   resetsAt: now.addingTimeInterval(600)),
                            bucket(kind: "weekly_all", percent: 12),
                        ], asOf: now),
            ],
            activeID: "acct-a",
            schedules: [],
            asOf: now)
    }
}
