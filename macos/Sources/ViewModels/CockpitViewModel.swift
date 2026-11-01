import Foundation

/// A thin data holder over CockpitDaemonAPI's non-fleet surfaces — history
/// charts, the doctor sweep, analytics, licensing reads/quote, and the
/// statusline editor. FleetViewModel keeps owning the SSE state loop and its
/// own polling; this model runs no loop of its own — each surface is loaded
/// on demand by its `load…()` call, later phases wire those to views.
@MainActor
final class CockpitViewModel: ObservableObject {
    @Published private(set) var history: [HistorySample]?
    @Published private(set) var historyError: String?

    @Published private(set) var doctor: DoctorReport?
    @Published private(set) var doctorError: String?

    @Published private(set) var analytics: AnalyticsResponse?
    /// The range, in days, `analytics` covers — History dims it only while
    /// it shows another range than the one asked for.
    @Published private(set) var analyticsDays: Int?
    @Published private(set) var analyticsError: String?
    /// Every range loaded so far: History shows a range it has seen at once
    /// and refreshes it behind, instead of waiting on the daemon again.
    private var analyticsByDays: [Int: AnalyticsResponse] = [:]
    private var analyticsRestored = false
    /// The same, kept on disk so a relaunch shows History at once too; nil
    /// keeps nothing (tests, previews).
    private let analyticsCache: AnalyticsDiskCache?

    @Published private(set) var license: LicenseInfo?
    @Published private(set) var licenseError: String?

    @Published private(set) var quote: LicenseQuote?
    @Published private(set) var quoteError: String?

    @Published private(set) var statuslineConfig: StatuslineConfigResponse?
    @Published private(set) var statuslineConfigError: String?

    @Published private(set) var statuslineSegments: StatuslineSegmentsResponse?
    @Published private(set) var statuslineSegmentsError: String?

    @Published private(set) var config: CockpitConfig?
    @Published private(set) var configError: String?

    private let api: CockpitDaemonAPI

    init(api: CockpitDaemonAPI, analyticsCache: AnalyticsDiskCache? = nil) {
        self.api = api
        self.analyticsCache = analyticsCache
    }

    /// A cancelled load surfaces NOTHING: SwiftUI's `.task(id:)` cancels the
    /// old task on every key change, and CancellationError has no user-facing
    /// message ("The operation couldn't be completed…"), so writing it into a
    /// published error would replace a designed quiet state with noise. The
    /// API layer maps URLError(.cancelled) → CancellationError for exactly
    /// this check.
    private func surfacedMessage(_ error: Error) -> String? {
        if error is CancellationError { return nil }
        return error.localizedDescription
    }

    func loadHistory(accountID: String, kind: String, scope: String? = nil) async {
        do {
            history = try await api.history(accountID: accountID, kind: kind, scope: scope)
            historyError = nil
        } catch {
            if let msg = surfacedMessage(error) { historyError = msg }
        }
    }

    func loadDoctor() async {
        do {
            doctor = try await api.doctor()
            doctorError = nil
        } catch {
            if let msg = surfacedMessage(error) { doctorError = msg }
        }
    }

    func loadAnalytics(days: Int = 30) async {
        if !analyticsRestored {
            analyticsRestored = true
            analyticsByDays = analyticsCache?.load() ?? [:]
        }
        // What this range showed last time, at once; the fetch replaces it.
        if let kept = analyticsByDays[days] {
            analytics = kept
            analyticsDays = days
        }
        do {
            let fresh = try await api.analytics(days: days)
            analyticsByDays[days] = fresh
            analytics = fresh
            analyticsDays = days
            analyticsError = nil
            analyticsCache?.save(analyticsByDays)
        } catch {
            if let msg = surfacedMessage(error) { analyticsError = msg }
        }
    }

    func loadLicense(reveal: Bool = false) async {
        do {
            license = try await api.license(reveal: reveal)
            licenseError = nil
        } catch {
            if let msg = surfacedMessage(error) { licenseError = msg }
        }
    }

    func loadQuote() async {
        do {
            quote = try await api.licenseQuote()
            quoteError = nil
        } catch {
            if let msg = surfacedMessage(error) { quoteError = msg }
        }
    }

    func loadStatuslineConfig() async {
        do {
            statuslineConfig = try await api.statuslineConfig()
            statuslineConfigError = nil
        } catch {
            if let msg = surfacedMessage(error) { statuslineConfigError = msg }
        }
    }

    func loadConfig() async {
        do {
            config = try await api.cockpitConfig()
            configError = nil
        } catch {
            if let msg = surfacedMessage(error) { configError = msg }
        }
    }

    func loadStatuslineSegments() async {
        do {
            statuslineSegments = try await api.statuslineSegments()
            statuslineSegmentsError = nil
        } catch {
            if let msg = surfacedMessage(error) { statuslineSegmentsError = msg }
        }
    }
}
