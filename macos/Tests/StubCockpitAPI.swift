import Foundation
@testable import llmpilot

/// Scriptable `CockpitDaemonAPI & DaemonAPI` stub — the full cockpit API
/// surface, in one place, for every view-model test that needs it (closes a
/// deferred phase-0 review finding: the fleet-only `StubAPI` in StubAPI.swift
/// left the whole cockpit surface — doctor, stash, licensing, schedules,
/// statusline, browser login — untested at the API-consumer layer).
///
/// Every call is independently scriptable via a `Result` property (default:
/// `.failure(DaemonError.down)` for throwing calls, empty/default values for
/// non-throwing ones) and every call is recorded so a test can assert what
/// was actually sent, not just what came back.
final class StubCockpitAPI: CockpitDaemonAPI & DaemonAPI, @unchecked Sendable {
    // MARK: - DaemonAPI

    var baseURLResult: URL? = URL(string: "http://127.0.0.1:59999")
    var stateResult: Result<DaemonState, Error> = .failure(DaemonError.down)
    var switchResult: Result<Void, Error> = .failure(DaemonError.down)
    var detectResult: Result<[DetectedDir], Error> = .success([])
    var adoptResult: Result<Void, Error> = .failure(DaemonError.down)
    var configResult: Result<DaemonConfig, Error> = .success(DaemonConfig(autopilot: nil))
    var reportMarkerResult: Result<Void, Error> = .success(())
    var startLoginResult: Result<LoginStart, Error> = .failure(DaemonError.down)
    var completeLoginResult: Result<Void, Error> = .failure(DaemonError.down)
    var eventsResult: Result<DaemonState, Error> = .failure(DaemonError.down)

    private(set) var switchedTo: [String] = []
    private(set) var adopted: [String] = []
    private(set) var markerReports: [Bool] = []
    private(set) var startedLogins = 0
    private(set) var completedLogins: [(code: String, state: String)] = []

    func baseURL() -> URL? { baseURLResult }
    func state() async throws -> DaemonState { try stateResult.get() }

    func switchAccount(to id: String) async throws {
        switchedTo.append(id)
        try switchResult.get()
    }

    func detect() async throws -> [DetectedDir] { try detectResult.get() }

    func adopt(configDir: String) async throws {
        adopted.append(configDir)
        try adoptResult.get()
    }

    func config() async throws -> DaemonConfig { try configResult.get() }

    func reportMarker(present: Bool) async throws {
        markerReports.append(present)
        try reportMarkerResult.get()
    }

    func startLogin() async throws -> LoginStart {
        startedLogins += 1
        return try startLoginResult.get()
    }

    func completeLogin(code: String, state: String) async throws {
        completedLogins.append((code, state))
        try completeLoginResult.get()
    }

    func events() -> AsyncThrowingStream<DaemonState, Error> {
        AsyncThrowingStream { continuation in
            switch eventsResult {
            case let .success(s): continuation.yield(s)
            case let .failure(e): continuation.finish(throwing: e)
            }
        }
    }

    // MARK: - CockpitDaemonAPI: schedules

    var schedulesResult: Result<[ScheduleRecord], Error> = .success([])
    var createScheduleResult: Result<ScheduleRecord, Error> = .failure(DaemonError.down)
    var updateScheduleResult: Result<ScheduleRecord, Error> = .failure(DaemonError.down)
    var deleteScheduleResult: Result<Void, Error> = .failure(DaemonError.down)

    private(set) var createdSchedules: [(accountID: String, hour: Int, minute: Int, model: String?, effort: String?)] = []
    private(set) var updatedSchedules: [(id: String, hour: Int, minute: Int)] = []
    private(set) var deletedScheduleIDs: [String] = []

    func schedules() async throws -> [ScheduleRecord] { try schedulesResult.get() }

    func createSchedule(
        accountID: String, hour: Int, minute: Int, model: String?, effort: String?
    ) async throws -> ScheduleRecord {
        createdSchedules.append((accountID, hour, minute, model, effort))
        return try createScheduleResult.get()
    }

    func updateSchedule(id: String, hour: Int, minute: Int) async throws -> ScheduleRecord {
        updatedSchedules.append((id, hour, minute))
        return try updateScheduleResult.get()
    }

    func deleteSchedule(id: String) async throws {
        deletedScheduleIDs.append(id)
        try deleteScheduleResult.get()
    }

    // MARK: - history / doctor / analytics

    var historyResult: Result<[HistorySample], Error> = .success([])
    var doctorResult: Result<DoctorReport, Error> = .failure(DaemonError.down)
    var analyticsResult: Result<AnalyticsResponse, Error> = .failure(DaemonError.down)

    private(set) var historyRequests: [(accountID: String, kind: String, scope: String?)] = []
    private(set) var doctorCalls = 0
    private(set) var analyticsRequests: [Int] = []

    func history(accountID: String, kind: String, scope: String?) async throws -> [HistorySample] {
        historyRequests.append((accountID, kind, scope))
        return try historyResult.get()
    }

    func doctor() async throws -> DoctorReport {
        doctorCalls += 1
        return try doctorResult.get()
    }

    func analytics(days: Int) async throws -> AnalyticsResponse {
        analyticsRequests.append(days)
        return try analyticsResult.get()
    }

    // MARK: - statusline

    var statuslinePreviewResult: Result<StatuslinePreviewResponse, Error> = .failure(DaemonError.down)
    var statuslineConfigResult: Result<StatuslineConfigResponse, Error> = .failure(DaemonError.down)
    var putStatuslineConfigResult: Result<StatuslineConfigResponse, Error> = .failure(DaemonError.down)
    var statuslineSegmentsResult: Result<StatuslineSegmentsResponse, Error> = .failure(DaemonError.down)

    private(set) var statuslinePreviewRequests: [(width: Int, tier: String, config: String?)] = []
    private(set) var putStatuslineConfigs: [StatuslineConfig] = []

    func statuslinePreview(width: Int, tier: String, config: String?) async throws -> StatuslinePreviewResponse {
        statuslinePreviewRequests.append((width, tier, config))
        return try statuslinePreviewResult.get()
    }

    func statuslineConfig() async throws -> StatuslineConfigResponse { try statuslineConfigResult.get() }

    func putStatuslineConfig(_ cfg: StatuslineConfig) async throws -> StatuslineConfigResponse {
        putStatuslineConfigs.append(cfg)
        return try putStatuslineConfigResult.get()
    }

    func statuslineSegments() async throws -> StatuslineSegmentsResponse { try statuslineSegmentsResult.get() }

    // MARK: - licensing

    var licenseResult: Result<LicenseInfo, Error> = .failure(DaemonError.down)
    var licenseQuoteResult: Result<LicenseQuote, Error> = .failure(DaemonError.down)

    private(set) var licenseRevealRequests: [Bool] = []
    /// PostCheckoutReload re-reads the license across the
    /// activation-poll window — a queued sequence lets a test flip the
    /// answer mid-window (each read shifts one entry; empty falls back to
    /// `licenseResult`).
    var licenseResultQueue: [Result<LicenseInfo, Error>] = []

    func license(reveal: Bool) async throws -> LicenseInfo {
        licenseRevealRequests.append(reveal)
        if !licenseResultQueue.isEmpty {
            return try licenseResultQueue.removeFirst().get()
        }
        return try licenseResult.get()
    }

    func licenseQuote() async throws -> LicenseQuote { try licenseQuoteResult.get() }

    // MARK: - licensing mutations (Phase 4 chunk A)

    var licenseCheckoutResult: Result<CheckoutHandoff, Error> = .failure(DaemonError.down)
    var licenseCancelResult: Result<LicenseCancelResult, Error> = .failure(DaemonError.down)
    var licenseRecoverResult: Result<Void, Error> = .failure(DaemonError.down)
    var licenseClaimResult: Result<LicenseClaimResult, Error> = .failure(DaemonError.down)

    private(set) var licenseCheckoutRequests: [(rung: String, echo: QuoteEcho, remindDaysBefore: Int?)] = []
    private(set) var licenseCancelCalls = 0
    private(set) var licenseRecoverRequests: [String] = []
    private(set) var licenseClaimRequests: [String] = []

    func licenseCheckout(rung: String, echo: QuoteEcho, remindDaysBefore: Int?) async throws -> CheckoutHandoff {
        licenseCheckoutRequests.append((rung, echo, remindDaysBefore))
        return try licenseCheckoutResult.get()
    }

    func licenseCancel() async throws -> LicenseCancelResult {
        licenseCancelCalls += 1
        return try licenseCancelResult.get()
    }

    func licenseRecover(email: String) async throws {
        licenseRecoverRequests.append(email)
        try licenseRecoverResult.get()
    }

    func licenseClaim(token: String) async throws -> LicenseClaimResult {
        licenseClaimRequests.append(token)
        return try licenseClaimResult.get()
    }

    // MARK: - stash / move / config

    var stashAdoptResult: Result<CockpitAccount, Error> = .failure(DaemonError.down)
    var stashDiscardResult: Result<Void, Error> = .failure(DaemonError.down)
    var adoptMoveResult: Result<AdoptMoveResult, Error> = .failure(DaemonError.down)
    var cockpitConfigResult: Result<CockpitConfig, Error> = .failure(DaemonError.down)
    var putConfigResult: Result<CockpitConfig, Error> = .failure(DaemonError.down)

    private(set) var stashAdoptRequests: [(fingerprint: String, label: String?)] = []
    private(set) var stashDiscardRequests: [String] = []
    private(set) var adoptMoveRequests: [(configDir: String, label: String?)] = []
    private(set) var putConfigRequests: [CockpitConfig] = []

    func stashAdopt(fingerprint: String, label: String?) async throws -> CockpitAccount {
        stashAdoptRequests.append((fingerprint, label))
        return try stashAdoptResult.get()
    }

    func stashDiscard(fingerprint: String) async throws {
        stashDiscardRequests.append(fingerprint)
        try stashDiscardResult.get()
    }

    func adoptMove(configDir: String, label: String?) async throws -> AdoptMoveResult {
        adoptMoveRequests.append((configDir, label))
        return try adoptMoveResult.get()
    }

    private(set) var cockpitConfigCalls = 0
    func cockpitConfig() async throws -> CockpitConfig {
        cockpitConfigCalls += 1
        return try cockpitConfigResult.get()
    }

    func putConfig(_ cfg: CockpitConfig) async throws -> CockpitConfig {
        putConfigRequests.append(cfg)
        return try putConfigResult.get()
    }

    // MARK: - zero-paste browser sign-in

    var startBrowserLoginResult: Result<BrowserLoginStart, Error> = .failure(DaemonError.down)
    var browserLoginStatusResult: Result<BrowserLoginStatus, Error> = .failure(DaemonError.down)

    private(set) var startedBrowserLogins = 0
    private(set) var browserLoginStatusRequests: [String] = []

    func startBrowserLogin() async throws -> BrowserLoginStart {
        startedBrowserLogins += 1
        return try startBrowserLoginResult.get()
    }

    func browserLoginStatus(attempt: String) async throws -> BrowserLoginStatus {
        browserLoginStatusRequests.append(attempt)
        return try browserLoginStatusResult.get()
    }
}

// MARK: - win-back ladder test support

/// A fresh, INTACT `WinbackModel` over one fixed throwaway suite. The
/// domain is wiped before every construction, so no armed/spent state ever
/// crosses tests — and at most one stale plist ever exists on the host,
/// overwritten on the next run. Tests that pin PERSISTENCE (a fresh model
/// over the SAME defaults) construct their `WinbackModel`s directly instead.
@MainActor
func freshWinback() -> WinbackModel {
    let suite = "llmpilot.tests.winback"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return WinbackModel(defaults: defaults)
}
