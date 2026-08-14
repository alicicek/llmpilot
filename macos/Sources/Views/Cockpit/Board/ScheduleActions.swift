import Foundation

/// Owns schedule create/move/delete against `CockpitDaemonAPI` and routes a
/// failure the way web/src/App.tsx's `report` does: a tier boundary (402
/// pro_required/pro_unavailable, riding `ApiError.code` — see CockpitAPI.swift's
/// plumbing note) publishes a calm offer, never a warn flash; anything else
/// publishes the daemon's own copy as a flash. Standalone — the integrator's
/// BoardView/BoardInspector/FreshWindowMenu callbacks call into this one
/// place so "was that an offer or a failure" is decided exactly once.
@MainActor
final class ScheduleActions: ObservableObject {
    /// The calm role-status card's content — mirrors App.tsx's `proPrompt`
    /// state, which stores only the `ApiError.code` (`pro_required` |
    /// `pro_unavailable`); `message` here is the 402 envelope's `error`
    /// field verbatim (ProOfferCard renders it as-is, no separate hardcoded
    /// copy tree to keep in sync with the daemon's).
    struct Offer: Equatable {
        let message: String
        let code: String
        /// "Try it free for 4 days" — ONLY pro_required (an unlicensed
        /// build can buy); pro_unavailable is a source build with no
        /// autopilot compiled in, nothing to sell it.
        var showCTA: Bool { code == "pro_required" }
    }

    private let api: CockpitDaemonAPI

    @Published private(set) var offer: Offer?
    @Published private(set) var flash: String?

    init(api: CockpitDaemonAPI) {
        self.api = api
    }

    @discardableResult
    func create(accountID: String, hour: Int, minute: Int) async -> ScheduleRecord? {
        do {
            return try await api.createSchedule(accountID: accountID, hour: hour, minute: minute, model: nil, effort: nil)
        } catch {
            route(error)
            return nil
        }
    }

    @discardableResult
    func move(id: String, hour: Int, minute: Int) async -> ScheduleRecord? {
        do {
            return try await api.updateSchedule(id: id, hour: hour, minute: minute)
        } catch {
            route(error)
            return nil
        }
    }

    func delete(id: String) async {
        do {
            try await api.deleteSchedule(id: id)
        } catch {
            route(error)
        }
    }

    /// A local-only failure (e.g. FreshWindowMenu's "fully booked" — never
    /// reaches the daemon, same as App.tsx's `bookFreshWindow` calling
    /// `setFlash` directly instead of going through `report`).
    func flashLocal(_ message: String) {
        flash = message
    }

    func dismissOffer() { offer = nil }
    func dismissFlash() { flash = nil }

    private func route(_ error: Error) {
        // A cancelled request (.task teardown) has no user-facing message —
        // surfacing it would print "CancellationError()" into the flash.
        if error is CancellationError { return }
        if let apiErr = error as? ApiError,
           let code = apiErr.code,
           code == "pro_required" || code == "pro_unavailable" {
            offer = Offer(message: apiErr.message, code: code)
            return
        }
        flash = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
