import SwiftUI

/// Reads three weeks of Claude Code use and plans an account's daily window
/// starts from it (HistoryPlan), then applies the plan: the account's daily
/// times are replaced, and rolling turns off — a plan is fixed times.
@MainActor
final class PlanFromHistoryModel: ObservableObject {
    enum Status: Equatable {
        case loading
        case idle
        case applying
        case applied
        case failed(String)
    }

    static let historyDays = 21

    /// What the history says; stays on screen while the plan applies.
    @Published private(set) var outcome: HistoryPlan.Outcome?
    @Published private(set) var status: Status = .loading
    let accountID: String
    private let api: CockpitDaemonAPI

    init(api: CockpitDaemonAPI, accountID: String) {
        self.api = api
        self.accountID = accountID
    }

    var plan: HistoryPlan.Plan? {
        if case let .plan(p) = outcome { return p }
        return nil
    }

    func load() async {
        status = .loading
        do {
            let a = try await api.analytics(days: Self.historyDays)
            let days = Set(a.cells.filter { $0.messages > 0 && $0.day != "unknown" }.map(\.day)).count
            outcome = HistoryPlan.make(hourWeekday: a.hourWeekday, activeDays: days)
            status = .idle
        } catch {
            status = .failed("llmpilot couldn't read your Claude Code history. Try again in a moment.")
        }
    }

    /// Old times go first (while rolling they are paused, so their removal
    /// starts nothing); then the account's window plan is cleared — rolling
    /// AND a pending one-tap, which could open a window just before the first
    /// new time and push its reset — so no old start survives; then the new
    /// times. A stop partway is said plainly — the board shows what was saved.
    func apply(existing: [Schedule], windowPlan: WindowPlan?) async {
        guard let plan else { return }
        status = .applying
        do {
            for s in existing where s.accountID == accountID {
                try await api.deleteSchedule(id: s.id)
            }
            if windowPlan?.rolling == true || windowPlan?.nextAt != nil {
                _ = try await api.setWindowPlan(accountID: accountID, rolling: false, nextAt: nil)
            }
            for m in plan.starts {
                _ = try await api.createSchedule(accountID: accountID, hour: m / 60, minute: m % 60, model: nil, effort: nil)
            }
            status = .applied
        } catch {
            let why = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            status = .failed("The plan stopped partway: \(why). The board shows the times that were saved.")
        }
    }
}

struct PlanFromHistorySheet: View {
    @ObservedObject var model: PlanFromHistoryModel
    let accountName: String
    let existing: [Schedule]
    let windowPlan: WindowPlan?
    let onClose: () -> Void

    private var rolling: Bool { windowPlan?.rolling == true }

    private var ownTimes: Int { existing.filter { $0.accountID == model.accountID }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Plan your day from your history")
                .font(.system(size: 15, weight: .semibold))
            VStack(alignment: .leading, spacing: 8) {
                if model.status == .loading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Reading the last three weeks of Claude Code use…")
                    }
                } else if let outcome = model.outcome {
                    outcomeText(outcome)
                }
                if case let .failed(message) = model.status {
                    Text(message).foregroundColor(CockpitTheme.warn)
                }
            }
            .font(.system(size: 12.5))
            .foregroundColor(CockpitTheme.sec)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(model.plan == nil ? "Close" : "Cancel", action: onClose)
                    .keyboardShortcut(.cancelAction)
                if model.plan != nil {
                    Button(model.status == .applying ? "Applying…" : "Apply plan") {
                        Task { await model.apply(existing: existing, windowPlan: windowPlan) }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.status == .applying)
                    .accessibilityIdentifier("plan-apply")
                }
            }
        }
        .padding(SheetChromeMetrics.inset)
        .frame(width: 460)
        .task { await model.load() }
        .onChange(of: model.status) { status in
            if status == .applied { onClose() }
        }
    }

    @ViewBuilder private func outcomeText(_ outcome: HistoryPlan.Outcome) -> some View {
        switch outcome {
        case let .plan(p):
            Text("From the last three weeks, you usually use Claude Code from \(BoardSchedule.fmtHM(p.startHour * 60)) to \(BoardSchedule.fmtHM(p.endHour * 60)).")
            Text(Self.planSentence(p, accountName: accountName))
                .foregroundColor(CockpitTheme.text)
            if ownTimes > 0 {
                Text("This replaces \(accountName)'s \(ownTimes == 1 ? "daily time" : "\(ownTimes) daily times").")
            }
            if rolling {
                Text("Keep it rolling turns off for \(accountName).")
            } else if let at = windowPlan?.nextAt {
                Text("The next window set for \(hm(at)) is cancelled.")
            }
        case .tooLittle:
            Text("There isn't enough history yet: a plan needs at least \(HistoryPlan.minActiveDays) days of Claude Code use. Keep it rolling works from day one.")
        case .allDay:
            Text("You use Claude Code around the clock, so a fixed day doesn't fit. Keep it rolling starts a new window at every reset instead.")
        case .shortDay:
            Text("Your Claude Code day is short enough that one window covers it, so a plan wouldn't add a reset. Start the next window from the account's row when you need one.")
        }
    }

    static func planSentence(_ p: HistoryPlan.Plan, accountName: String) -> String {
        var s = "Windows start on \(accountName) at \(HistoryPlan.list(p.starts))"
        if !p.resetsInDay.isEmpty {
            s += ", so your limit resets at \(HistoryPlan.list(p.resetsInDay)) while you work"
        }
        return s + "."
    }
}

/// Owns the model for one presentation (a sheet's content is rebuilt on
/// every parent render; the plan being read must survive that).
struct PlanFromHistoryHost: View {
    @StateObject private var model: PlanFromHistoryModel
    let accountName: String
    let existing: [Schedule]
    let windowPlan: WindowPlan?
    let onClose: () -> Void

    init(api: CockpitDaemonAPI, accountID: String, accountName: String, existing: [Schedule], windowPlan: WindowPlan?, onClose: @escaping () -> Void) {
        _model = StateObject(wrappedValue: PlanFromHistoryModel(api: api, accountID: accountID))
        self.accountName = accountName
        self.existing = existing
        self.windowPlan = windowPlan
        self.onClose = onClose
    }

    var body: some View {
        PlanFromHistorySheet(model: model, accountName: accountName, existing: existing, windowPlan: windowPlan, onClose: onClose)
    }
}

/// The account a "Plan from my history" sheet is open for.
struct PlanTarget: Identifiable, Equatable {
    let id: String
    let name: String
}
