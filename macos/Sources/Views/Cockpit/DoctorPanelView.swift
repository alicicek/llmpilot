import SwiftUI

// Native port of web/src/shell/DoctorPanel.tsx — the health sweep, rendered.
// It shows exactly what `llmpilot doctor` prints and repairs nothing itself:
// every button here is a verb the daemon's doctor engine already accepts.
//
// The one rule that outranks tidiness (DoctorPanel.tsx:9-11): a check that
// could not run is shown as NOT CHECKED, never folded into the all-clear.
// "No problems found" is only printed when every check actually ran.

/// Mirrors web/src/App.tsx's `doctorKey` (App.tsx:57-63): changes exactly
/// when something the sweep would report changes — a re-login clears a
/// quarantine, a move flips a lane from watched to switchable, a poll marks
/// an account stale — all of which ride `DaemonState` without changing a
/// count. Deliberately excludes `asOf`: that changes on every SSE push, and
/// each sweep costs one Keychain read per account, so this refetches on
/// health, not on the clock.
func doctorReloadKey(state: DaemonState) -> String {
    let accounts = state.accounts
        .map { account -> String in
            let stale = account.stale == true ? 1 : 0
            let pinned = account.pinned ? 1 : 0
            // JS `a.token_note ? 1 : 0` is falsy on both nil AND "" — mirror
            // that exactly, not just presence.
            let tokenNote = (account.tokenNote?.isEmpty == false) ? 1 : 0
            return "\(account.id):\(stale):\(pinned):\(tokenNote)"
        }
        .joined(separator: ",")
    let stash = state.stash
    return "\(accounts)|\(stash.count):\(stash.filter { $0.dead == true }.count)"
}

/// Mirrors web/src/board/severity.ts `findingSeverity`: the doctor's finding
/// severities ride the SAME shipped severity trio — an informational finding
/// is calm on purpose, a watched lane is a feature, not a fault.
func findingSeverityBand(_ severity: String) -> CockpitTheme.SeverityBand {
    switch severity {
    case "critical": return .crit
    case "warning": return .warn
    default: return .calm
    }
}

/// Drives the native Doctor panel: owns the report, the sweep-failure state,
/// per-finding busy/error state, and the reload-key gate that keeps the
/// sweep from re-running on every SSE tick. Mirrors DoctorPanel.tsx's
/// `useState` + `useEffect(load, [reloadKey])` (lines 34-61), including the
/// strict 4-branch headline (never overstate fleet health, lines 96-105) and
/// the switch verb's empty-target guard (lines 115-126).
@MainActor
final class DoctorPanelModel: ObservableObject {
    @Published private(set) var report: DoctorReport?
    /// A sweep that could not run is itself news — hiding the panel would
    /// render as "nothing to report", the false all-clear by omission
    /// (DoctorPanel.tsx:35-36).
    @Published private(set) var sweepErr: String?
    @Published private(set) var busyFindingID: String?
    @Published var actionErr: String?

    private let api: CockpitDaemonAPI & DaemonAPI
    private let onAddAccount: () -> Void
    private let onReviewStash: () -> Void
    private var lastReloadKey: String?

    init(
        api: CockpitDaemonAPI & DaemonAPI,
        onAddAccount: @escaping () -> Void,
        onReviewStash: @escaping () -> Void
    ) {
        self.api = api
        self.onAddAccount = onAddAccount
        self.onReviewStash = onReviewStash
    }

    /// Reloads unconditionally — callers gate through `reloadIfKeyChanged`.
    /// Returns false ONLY when the sweep was cancelled (view teardown or a
    /// key change mid-flight): a cancelled sweep is not a failed sweep — the
    /// last good report stays, no error is written, and the caller rolls the
    /// key back so the next `.task` fire retries instead of short-circuiting.
    /// Without this, one SSE blip during a slow sweep left the panel stuck on
    /// "could not check the fleet" quoting a raw CancellationError until the
    /// app restarted.
    @discardableResult
    func load() async -> Bool {
        do {
            let r = try await api.doctor()
            // Mirrors web/src/api.ts fetchDoctor (lines 333-338): a sweep
            // always runs a fixed list of checks, so a report with none is
            // not a health report — treat it as a sweep failure, never "all
            // 0 checks ran".
            guard !r.checks.isEmpty else {
                report = nil
                sweepErr = "the daemon answered without a single health check"
                return true
            }
            report = r
            sweepErr = nil
            return true
        } catch is CancellationError {
            return false
        } catch {
            report = nil
            sweepErr = error.localizedDescription
            return true
        }
    }

    /// The React effect's dependency-array gate (DoctorPanel.tsx:61):
    /// reload only when the derived key changes, so an SSE tick that doesn't
    /// touch fleet health never re-triggers a sweep.
    func reloadIfKeyChanged(_ key: String) async {
        guard key != lastReloadKey else { return }
        lastReloadKey = key
        if await !load() {
            // Cancelled mid-flight — un-burn the key so the next fire retries.
            lastReloadKey = nil
        }
    }

    // MARK: - remedy verbs (DoctorPanel.tsx `action`, lines 107-130)

    enum RemedyAction: Equatable {
        case addAccount
        case reviewStash
        case switchTo(target: String, findingID: String)
        case none
    }

    func remedyAction(for finding: DoctorFinding) -> RemedyAction {
        switch finding.remedy.verb {
        case "move_into_fleet", "sign_in_again", "register_account":
            return .addAccount
        case "review_stash":
            return .reviewStash
        case "switch":
            // The daemon never emits "switch" for a pinned target, so this
            // can only ever call a switch the engine accepts — guarded here
            // too: empty/nil target means no button, no API call.
            guard let target = finding.remedy.target, !target.isEmpty else { return .none }
            return .switchTo(target: target, findingID: finding.id)
        default:
            return .none
        }
    }

    func run(_ action: RemedyAction) {
        switch action {
        case .addAccount:
            onAddAccount()
        case .reviewStash:
            onReviewStash()
        case let .switchTo(target, findingID):
            guard !target.isEmpty else { return }
            busyFindingID = findingID
            actionErr = nil
            Task {
                do {
                    try await api.switchAccount(to: target)
                    await load() // a resolved finding must not linger
                } catch {
                    actionErr = error.localizedDescription
                }
                busyFindingID = nil
            }
        case .none:
            break
        }
    }

    // MARK: - derived (DoctorPanel.tsx lines 86-105)

    var notChecked: [DoctorCheck] { (report?.checks ?? []).filter { $0.state == "not_checked" } }
    var ran: [DoctorCheck] { (report?.checks ?? []).filter { $0.state != "not_checked" } }
    var notes: Int { (report?.findings.count ?? 0) - (report?.problems ?? 0) }

    /// Defence in depth (DoctorPanel.tsx:92-94): the all-clear needs BOTH
    /// the engine's verdict and no unchecked item in the list the user can
    /// see.
    var allClear: Bool {
        guard let report else { return false }
        return report.clean && notChecked.isEmpty && report.problems == 0
    }

    /// The strict 4-branch headline. Order matters — branch 4 exists to
    /// never overstate fleet health (DoctorPanel.tsx:96-105).
    var headline: String {
        guard let report else { return "" }
        if allClear {
            return "No problems found — all \(report.checks.count) checks ran."
        }
        if report.problems > 0 {
            return "\(report.problems) problem\(report.problems == 1 ? "" : "s") found"
        }
        if !notChecked.isEmpty {
            return "No problems found, but \(notChecked.count) of \(report.checks.count) checks could not run"
        }
        return "This report does not add up — llmpilot cannot confirm the fleet is healthy."
    }

    /// DoctorPanel.tsx:200-203's not-checked header — singular/plural
    /// "this"/"these" — split out so it is independently testable.
    var notCheckedHeader: String {
        "Not checked (\(notChecked.count)) — llmpilot could not look at " +
            "\(notChecked.count == 1 ? "this" : "these"):"
    }
}

// MARK: - shared inline warn/error box

/// The tinted warn card shared by the sweep-failure state, the not-checked
/// block, and the inline action-error line — one box style, three callers,
/// matching the web's repeated `border-warnbd bg-warnbg` treatment.
struct CockpitWarnBox<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CockpitTheme.warnBg)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(CockpitTheme.warnBd, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - view

struct DoctorPanelView: View {
    @ObservedObject var model: DoctorPanelModel
    let reloadKey: String

    @State private var checkedOpen = false

    var body: some View {
        // NOT a bare Group: on first appearance sweepErr and report are both
        // nil, and a lifecycle modifier on a content-free subtree (EmptyView)
        // is not guaranteed to fire — which would mean load() never runs and
        // the panel stays invisible forever. The zero-height clear anchor
        // keeps the subtree real so `.task` always attaches (its firing is
        // pinned by DoctorPanelHostingTests).
        VStack(spacing: 0) {
            Color.clear.frame(height: 0)
            if let sweepErr = model.sweepErr {
                sweepFailureBox(sweepErr)
            } else if model.report != nil {
                panel
            }
        }
        .task(id: reloadKey) {
            await model.reloadIfKeyChanged(reloadKey)
        }
    }

    private func sweepFailureBox(_ message: String) -> some View {
        CockpitWarnBox {
            VStack(alignment: .leading, spacing: 2) {
                Text("llmpilot could not check the fleet")
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundColor(CockpitTheme.warn)
                (Text("\(message) — nothing below is a clean bill of health. Run ")
                    + Text("llmpilot doctor").font(.system(size: 11, weight: .semibold, design: .monospaced))
                    + Text(" in a terminal to see what llmpilot found and what fixes it."))
                    .font(.system(size: 11))
                    .foregroundColor(CockpitTheme.warn)
            }
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.headline)
                    .font(CockpitTheme.numeric(12.5, weight: .bold))
                Spacer()
                Button(checkedOpen ? "Hide what was checked" : "What was checked") {
                    checkedOpen.toggle()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(CockpitTheme.sec)
                .accessibilityIdentifier("doctor-what-was-checked")
            }

            if model.notes > 0 {
                Text("\(model.notes) note\(model.notes == 1 ? "" : "s") below.")
                    .font(CockpitTheme.numeric(11))
                    .foregroundColor(CockpitTheme.ter)
            }

            if let report = model.report, !report.findings.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(report.findings.enumerated()), id: \.offset) { idx, finding in
                        findingRow(finding)
                        if idx != report.findings.count - 1 {
                            Divider().overlay(CockpitTheme.hairSoft)
                        }
                    }
                }
            }

            if !model.notChecked.isEmpty {
                notCheckedBox
            }

            if checkedOpen {
                Text("Checked: \(model.ran.map(\.title).joined(separator: " · "))")
                    .font(.system(size: 10.5))
                    .foregroundColor(CockpitTheme.ter)
            }

            if let err = model.actionErr {
                CockpitWarnBox {
                    Text(err).font(.system(size: 11)).foregroundColor(CockpitTheme.warn)
                }
            }
        }
        .padding(16)
        .background(CockpitTheme.panel)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(CockpitTheme.hairSoft, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func findingRow(_ finding: DoctorFinding) -> some View {
        let action = model.remedyAction(for: finding)
        let band = findingSeverityBand(finding.severity)
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(severityWord(band))
                        .font(.system(size: 9.5, weight: .bold))
                        .textCase(.uppercase)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(severityBorderColor(band), lineWidth: 1))
                        .foregroundColor(severityTextColor(band))
                    Text(finding.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                }
                Text(finding.detail)
                    .font(.system(size: 11))
                    .foregroundColor(CockpitTheme.sec)
                if action == .none {
                    remedyFallback(finding.remedy)
                }
            }
            Spacer(minLength: 0)
            if action != .none {
                let label = model.busyFindingID == finding.id ? "Working…" : finding.remedy.label
                Button(action: { model.run(action) }) {
                    Text(label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        // actionFill, not accTx (owner 2026-08-12): one blue for every
                        // primary action, and white-on-accTx fails contrast in dark mode.
                        .background(CockpitTheme.actionFill)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .opacity(model.busyFindingID != nil ? 0.5 : 1)
                .disabled(model.busyFindingID != nil)
                .accessibilityIdentifier("doctor-remedy-\(finding.id)")
                .accessibilityLabel(label)
            }
        }
        .padding(.vertical, 8)
    }

    private func remedyFallback(_ remedy: DoctorRemedy) -> some View {
        Group {
            if let command = remedy.command {
                Text(remedy.label + " · ") + Text(command).font(.system(size: 10.5, weight: .semibold, design: .monospaced))
            } else {
                Text(remedy.label)
            }
        }
        .font(.system(size: 10.5))
        .foregroundColor(CockpitTheme.ter)
    }

    private var notCheckedBox: some View {
        CockpitWarnBox {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.notCheckedHeader)
                    .font(CockpitTheme.numeric(11, weight: .semibold))
                    .foregroundColor(CockpitTheme.warn)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.notChecked) { check in
                        Text("\(check.title) — \(check.why ?? "")")
                            .font(.system(size: 10.5))
                            .foregroundColor(CockpitTheme.warn)
                    }
                }
            }
        }
    }

    private func severityWord(_ band: CockpitTheme.SeverityBand) -> String {
        switch band {
        case .crit: return "Critical"
        case .warn: return "Warning"
        case .calm: return "Note"
        }
    }

    private func severityBorderColor(_ band: CockpitTheme.SeverityBand) -> Color {
        switch band {
        case .crit: return CockpitTheme.crit
        case .warn: return CockpitTheme.warnBd
        case .calm: return CockpitTheme.hairSoft
        }
    }

    private func severityTextColor(_ band: CockpitTheme.SeverityBand) -> Color {
        switch band {
        case .crit: return CockpitTheme.crit
        case .warn: return CockpitTheme.warn
        case .calm: return CockpitTheme.sec
        }
    }
}

// MARK: - preview

/// Preview-only stub — deliberately minimal (only `doctor()` is meaningful).
/// The full scriptable stub used by tests lives in Tests/StubCockpitAPI.swift
/// and cannot be reached from Sources (no @testable import across targets).
private final class PreviewDoctorAPI: CockpitDaemonAPI & DaemonAPI, @unchecked Sendable {
    var reportResult: DoctorReport?

    func baseURL() -> URL? { nil }
    func state() async throws -> DaemonState { throw DaemonError.down }
    func switchAccount(to id: String) async throws {}
    func detect() async throws -> [DetectedDir] { [] }
    func adopt(configDir: String) async throws {}
    func config() async throws -> DaemonConfig { DaemonConfig(autopilot: nil) }
    func reportMarker(present: Bool) async throws {}
    func startLogin() async throws -> LoginStart { throw DaemonError.down }
    func completeLogin(code: String, state: String) async throws {}
    func events() -> AsyncThrowingStream<DaemonState, Error> { .init { $0.finish(throwing: DaemonError.down) } }

    func schedules() async throws -> [ScheduleRecord] { [] }
    func createSchedule(accountID: String, hour: Int, minute: Int, model: String?, effort: String?) async throws -> ScheduleRecord {
        throw DaemonError.down
    }
    func updateSchedule(id: String, hour: Int, minute: Int) async throws -> ScheduleRecord { throw DaemonError.down }
    func deleteSchedule(id: String) async throws {}
    func history(accountID: String, kind: String, scope: String?) async throws -> [HistorySample] { [] }
    func doctor() async throws -> DoctorReport {
        guard let reportResult else { throw DaemonError.down }
        return reportResult
    }
    func analytics(days: Int) async throws -> AnalyticsResponse { throw DaemonError.down }
    func statuslinePreview(width: Int, tier: String, config: String?) async throws -> StatuslinePreviewResponse {
        throw DaemonError.down
    }
    func statuslineConfig() async throws -> StatuslineConfigResponse { throw DaemonError.down }
    func putStatuslineConfig(_ cfg: StatuslineConfig) async throws -> StatuslineConfigResponse { throw DaemonError.down }
    func statuslineSegments() async throws -> StatuslineSegmentsResponse { throw DaemonError.down }
    func license(reveal: Bool) async throws -> LicenseInfo { throw DaemonError.down }
    func licenseQuote() async throws -> LicenseQuote { throw DaemonError.down }
    func licenseCheckout(rung: String, echo: QuoteEcho, remindDaysBefore: Int?) async throws -> CheckoutHandoff {
        throw DaemonError.down
    }
    func licenseCancel() async throws -> LicenseCancelResult { throw DaemonError.down }
    func licenseRecover(email: String) async throws {}
    func licenseClaim(token: String) async throws -> LicenseClaimResult { throw DaemonError.down }
    func stashAdopt(fingerprint: String, label: String?) async throws -> CockpitAccount { throw DaemonError.down }
    func stashDiscard(fingerprint: String) async throws {}
    func adoptMove(configDir: String, label: String?) async throws -> AdoptMoveResult { throw DaemonError.down }
    func cockpitConfig() async throws -> CockpitConfig { throw DaemonError.down }
    func putConfig(_ cfg: CockpitConfig) async throws -> CockpitConfig { throw DaemonError.down }
    func startBrowserLogin() async throws -> BrowserLoginStart { throw DaemonError.down }
    func browserLoginStatus(attempt: String) async throws -> BrowserLoginStatus { throw DaemonError.down }
}

/// DoctorFinding has a custom `init(from:)` (CockpitModels.swift:107-116), so
/// no memberwise initializer is synthesized — build previews through the
/// same JSON decode path production uses instead.
private func previewFindingJSON(
    id: String, severity: String, title: String, detail: String, verb: String, target: String? = nil
) -> String {
    let targetFragment = target.map { ",\"target\":\"\($0)\"" } ?? ""
    return """
    {"id":"\(id)","check":"\(id)","severity":"\(severity)","title":"\(title)","detail":"\(detail)",
     "accounts":[],"remedy":{"verb":"\(verb)","label":"Fix it"\(targetFragment)}}
    """
}

private func previewCheckJSON(id: String, title: String, state: String, why: String? = nil) -> String {
    var s = "{\"id\":\"\(id)\",\"title\":\"\(title)\",\"state\":\"\(state)\""
    if let why { s += ",\"why\":\"\(why)\"" }
    s += "}"
    return s
}

private func previewReport(clean: Bool, problems: Int, findings: [String], checks: [String]) -> DoctorReport {
    let json = """
    {"as_of":"2026-08-07T12:00:00Z","clean":\(clean),"problems":\(problems),
     "findings":[\(findings.joined(separator: ","))],"checks":[\(checks.joined(separator: ","))]}
    """
    return try! DaemonDates.decoder().decode(DoctorReport.self, from: json.data(using: .utf8)!)
}

@MainActor
private func makeDoctorPreview(_ report: DoctorReport) -> DoctorPanelView {
    let api = PreviewDoctorAPI()
    api.reportResult = report
    let model = DoctorPanelModel(api: api, onAddAccount: {}, onReviewStash: {})
    return DoctorPanelView(model: model, reloadKey: "preview")
}

#Preview("All clear") {
    makeDoctorPreview(previewReport(
        clean: true, problems: 0, findings: [],
        checks: [previewCheckJSON(id: "c1", title: "Fleet reachable", state: "ok")]))
        .frame(width: 720).padding()
}

#Preview("Problems found") {
    makeDoctorPreview(previewReport(
        clean: false, problems: 1,
        findings: [previewFindingJSON(
            id: "f1", severity: "critical", title: "Account quarantined",
            detail: "mira's token was rejected.", verb: "sign_in_again")],
        checks: [previewCheckJSON(id: "c1", title: "Token validity", state: "finding")]))
        .frame(width: 720).padding()
}

#Preview("Not all checked") {
    makeDoctorPreview(previewReport(
        clean: true, problems: 0, findings: [],
        checks: [
            previewCheckJSON(id: "c1", title: "Fleet reachable", state: "ok"),
            previewCheckJSON(id: "c2", title: "Statusline install", state: "not_checked", why: "no terminal profile found"),
        ]))
        .frame(width: 720).padding()
}

#Preview("Does not add up") {
    // Contradiction on purpose: clean=false, problems=0, nothing unchecked —
    // branch 4 exists exactly for this daemon-side inconsistency.
    makeDoctorPreview(previewReport(
        clean: false, problems: 0, findings: [],
        checks: [previewCheckJSON(id: "c1", title: "Fleet reachable", state: "ok")]))
        .frame(width: 720).padding()
}
