import SwiftUI

// Native port of web/src/shell/History.tsx (the collapsible section shell)
// + web/src/history/Charts.tsx (the orchestrator: filter state, fetch
// lifecycle, filteredCells derivation). The five chart cards + heatmap +
// table twin live in HistoryCards.swift/HistoryCardsMore.swift; shared card
// chrome (Card/QuietState/LegendRow) and the filter row live in
// HistoryChartKit.swift.
//
// Every date-bearing wire field here (`DaemonState.asOf`, `Bucket.resetsAt`,
// `HistorySample.at`) already decodes to a Swift `Date` (API/CockpitModels.swift,
// API/Models.swift — read-only in this chunk). HistoryFormat's ported
// functions (dateOnly/hhmm/isoOffsetMinutes) read literal digits off an ISO
// STRING, not an instant — `boardTimeISOString(from:)` (FleetLanesView.swift,
// chunk B) is the established bridge back to a string for exactly this
// reason: the daemon always marshals every timestamp this section touches in
// UTC (internal/daemon/daemon.go `AsOf: time.Now().UTC()`; the Anthropic
// usage endpoint's `resets_at` is asserted `time.UTC` in
// internal/anthropic/anthropic_test.go:72), so re-encoding the decoded
// instant through that one UTC convention reproduces an equivalent wire
// string — reused here rather than re-derived, per FleetLanesView's own
// file-header note.

// MARK: - Range

/// web/src/history/format.ts `Range`/`RANGE_DAYS`. Raw values are the exact
/// dictionary keys `HistoryFormat.rangeDays` expects.
enum HistoryRangeKey: String, CaseIterable, Identifiable, Equatable {
    case today, sevenDay = "7d", thirtyDay = "30d", oneYear = "1y"

    var id: String { rawValue }

    /// Filters.tsx `RANGE_TABS` labels.
    var tabLabel: String {
        switch self {
        case .today: return "Today"
        case .sevenDay: return "7d"
        case .thirtyDay: return "30d"
        case .oneYear: return "1y"
        }
    }

    var days: Int { HistoryFormat.rangeDays[rawValue] ?? 1 }

    /// format.ts `rangeLabel`.
    var rangeLabel: String {
        switch self {
        case .today: return "today"
        case .sevenDay: return "last 7 days"
        case .thirtyDay: return "last 30 days"
        case .oneYear: return "last 12 months"
        }
    }

    /// format.ts `rangeScopeWord` — the delight footer's scope word.
    var scopeWord: String {
        switch self {
        case .today: return "today"
        case .sevenDay: return "this week"
        case .thirtyDay: return "this month"
        case .oneYear: return "this year"
        }
    }
}

// MARK: - pure derivation (Charts.tsx / History.tsx bodies, made testable
// without a view)

enum HistoryDerivation {
    struct AccountOption: Identifiable, Equatable {
        let id: String
        let label: String
    }

    /// Charts.tsx `hasShared` memo.
    static func hasShared(_ cells: [AnalyticsCell]) -> Bool {
        cells.contains { $0.accountID == "" }
    }

    /// Charts.tsx `accountOptions` memo. `a.label || a.email` — JS `||`
    /// picks email when label is falsy (empty string), mirrored via
    /// `isEmpty` rather than `nil`-checking (label is never optional here).
    static func accountOptions(accounts: [AccountState], hasShared: Bool) -> [AccountOption] {
        var opts = accounts.map { AccountOption(id: $0.id, label: $0.label.isEmpty ? $0.email : $0.label) }
        if hasShared { opts.append(AccountOption(id: "", label: "shared")) }
        return opts
    }

    /// Charts.tsx `accountsCaption` / Filters.tsx `accountsLabel` (identical
    /// derivation, kept as one function since both callers compute the same
    /// three-way string).
    static func accountsCaption(selectedCount: Int, totalCount: Int) -> String {
        if selectedCount == 0 { return "no accounts" }
        if selectedCount == totalCount { return "all accounts" }
        return "\(selectedCount) of \(totalCount) accounts"
    }

    /// Charts.tsx line 133: `cutoff = addDays(today, -(RANGE_DAYS[range] - 1))`.
    static func cutoff(today: String, rangeDays: Int) -> String {
        HistoryFormat.addDays(today, -(rangeDays - 1))
    }

    /// Charts.tsx `filteredCells` memo (lines 134-137).
    static func filteredCells(
        _ cells: [AnalyticsCell], cutoff: String, today: String, selected: Set<String>
    ) -> [AnalyticsCell] {
        cells.filter { $0.day >= cutoff && $0.day <= today && selected.contains($0.accountID) }
    }

    /// Delight.tsx's token sum (`cells.reduce((s,c) => s + totalTokens(c.tokens), 0)`),
    /// as a Double since `HistoryDelight.hobbitFactorString` divides by a
    /// Double constant.
    static func totalTokensSum(_ cells: [AnalyticsCell]) -> Double {
        Double(cells.reduce(Int64(0)) { $0 + HistoryAggregate.totalTokens($1.tokens) })
    }
}

// MARK: - BurnRate pure derivation (BurnRate.tsx)

enum BurnRateDerivation {
    /// BurnRate.tsx `activeBucket` (lines 15-20).
    static func activeBucket(_ state: DaemonState) -> Bucket? {
        guard let acct = state.accounts.first(where: { $0.id == state.activeID }) else { return nil }
        return acct.snapshot?.buckets.first {
            ($0.kind == "session" || $0.kind == "five_hour") && $0.active == true && $0.resetsAt != nil
        }
    }

    /// BurnRate.tsx line 69: `≈ $${rate < 10 ? rate.toFixed(1) : Math.round(rate)}/h`.
    static func rateStr(_ rate: Double) -> String {
        let v = rate < 10 ? HistoryFormat.fixed(rate, 1) : String(Int64(HistoryFormat.mathRound(rate)))
        return "≈ $\(v)/h"
    }

    enum Tone: Equatable { case ter, warn, ok }

    struct Verdict: Equatable {
        let text: String
        let tone: Tone
    }

    /// BurnRate.tsx lines 111-118: the wall-vs-reset verdict line. `resetStr`/
    /// `offsetMinutes` are pre-formatted by the caller (see the file header
    /// for why — this app only ever has a UTC offset to hand).
    static func verdict(projectedMs: Double?, resetMs: Double, resetStr: String, offsetMinutes: Int) -> Verdict {
        guard let projectedMs else { return Verdict(text: "resets \(resetStr)", tone: .ter) }
        let wallBeforeReset = projectedMs < resetMs
        if wallBeforeReset {
            let wallStr = HistoryFormat.hhmmAtEpoch(projectedMs, offsetMinutes)
            return Verdict(text: "wall ≈ \(wallStr) · resets \(resetStr) ⚠ — will be tight", tone: .warn)
        }
        return Verdict(text: "resets before the wall ✓", tone: .ok)
    }
}

// MARK: - ModelMix pure derivation (ModelMix.tsx lines 49-59)

enum ModelMixDerivation {
    struct SegmentShare: Identifiable, Equatable {
        var id: String { segment.family }
        let segment: HistoryAggregate.Segment
        let share: Double // percent, 0-100
        let mid: Double // cumulative midpoint percent, 0-100
    }

    static func withShares(_ segments: [HistoryAggregate.Segment]) -> [SegmentShare] {
        let total = segments.reduce(Int64(0)) { $0 + $1.tokens }
        guard total > 0 else { return [] }
        var cum = 0.0
        var out: [SegmentShare] = []
        for seg in segments {
            let share = (Double(seg.tokens) / Double(total)) * 100
            let mid = cum + share / 2
            cum += share
            out.append(SegmentShare(segment: seg, share: share, mid: mid))
        }
        return out
    }
}

// MARK: - Projects pure derivation (Projects.tsx lines 20-29)

enum ProjectsDerivation {
    struct Row: Identifiable, Equatable {
        var id: String { project }
        let project: String
        let tokens: Int64
        let value: Double
    }

    /// Projects.tsx's `otherValue` memo + the `all` array it feeds
    /// (`otherCount > 0 ? [...rows, otherRow] : rows`).
    static func rows(_ top: HistoryAggregate.TopProjects) -> [Row] {
        var rows = top.rows.map { Row(project: $0.project, tokens: $0.tokens, value: $0.value) }
        if top.otherCount > 0 {
            let totalTokens = top.rows.reduce(Int64(0)) { $0 + $1.tokens } + top.otherTokens
            let totalValue = top.rows.reduce(0.0) { $0 + $1.value }
            let otherValue = totalTokens > 0 ? (totalValue / Double(totalTokens)) * Double(top.otherTokens) : 0
            rows.append(Row(project: "other (\(top.otherCount))", tokens: top.otherTokens, value: otherValue))
        }
        return rows
    }
}

// MARK: - Value pure derivation (Value.tsx)

enum ValueDerivation {
    /// Value.tsx `planCost` memo (live branch only — the `fixturesMode`
    /// branch has no native counterpart). `perAccount` is the daemon's
    /// `plan_cost_monthly` map, loaded via `cockpitConfig()`.
    static func planCost(selectedAccountIds: [String], perAccount: [String: Double], rangeDays: Int) -> Double {
        let prorate = Double(rangeDays) / 30.0
        let sum = selectedAccountIds.reduce(0.0) { $0 + (perAccount[$1] ?? 0) }
        return sum * prorate
    }

    struct Summary: Equatable {
        let total: Double
        let planCost: Double
        let ratio: Double?
        let barMax: Double
        let pulledPct: Double
        let planPct: Double
        let caption: String
    }

    /// Value.tsx lines 24-30.
    static func summary(total: Double, planCost: Double) -> Summary {
        let ratio: Double? = planCost > 0 ? total / planCost : nil
        let barMax = max(total, max(planCost, 1)) * 1.15
        let pulledPct = barMax > 0 ? (total / barMax) * 100 : 0
        let planPct = barMax > 0 ? (planCost / barMax) * 100 : 0
        let suffix = ratio != nil ? " · \(HistoryFormat.fixed(ratio!, 1))×" : ""
        let caption = "\(HistoryFormat.formatUSD(total)) pulled vs \(HistoryFormat.formatUSD(planCost)) plan spend\(suffix)"
        return Summary(total: total, planCost: planCost, ratio: ratio, barMax: barMax, pulledPct: pulledPct, planPct: planPct, caption: caption)
    }
}

// MARK: - orchestrator model

/// Drives the section's own filter state (range/account multi-select) and
/// the two fetches Charts.tsx owns (analytics, burn samples), through the
/// shared `CockpitViewModel` (loadAnalytics/loadHistory — consumed as-is,
/// never edited: this chunk only wraps it with the loading flags and filter
/// state Charts.tsx keeps that CockpitViewModel itself doesn't track).
///
/// Plan cost rides `CockpitDaemonAPI.cockpitConfig()` (GET /v1/config, the
/// same read Value.tsx's `fetchConfig()` makes) — loaded alongside
/// analytics; a failed fetch falls back to the $0 plan-cost presentation
/// Charts.tsx line 108 defines.
@MainActor
final class HistorySectionModel: ObservableObject {
    @Published var range: HistoryRangeKey = .sevenDay
    @Published var customSelected: Set<String>?
    @Published private(set) var isAnalyticsLoading = false
    @Published private(set) var isBurnLoading = false

    let cockpit: CockpitViewModel

    init(cockpit: CockpitViewModel) {
        self.cockpit = cockpit
    }

    func loadAnalyticsIfNeeded() async {
        isAnalyticsLoading = true
        await cockpit.loadAnalytics(days: range.days)
        // Plan cost for the Value card (Charts.tsx fetches config alongside
        // analytics); errors degrade to the $0 presentation, never block.
        await cockpit.loadConfig()
        isAnalyticsLoading = false
    }

    func loadBurnSamples(activeAccountID: String) async {
        isBurnLoading = true
        await cockpit.loadHistory(accountID: activeAccountID, kind: "session")
        isBurnLoading = false
    }

    /// Charts.tsx `toggle` (lines 122-129).
    func toggleAccount(_ id: String, options: [String]) {
        var base = customSelected ?? Set(options)
        if base.contains(id) { base.remove(id) } else { base.insert(id) }
        customSelected = base
    }

    /// Charts.tsx `selectAll` (line 130).
    func selectAllAccounts() {
        customSelected = nil
    }
}

/// `.task(id:)` key for the burn-samples fetch — BurnRate.tsx's effect
/// depends on `[range, fixturesMode, state.active_id]` (Charts.tsx line 98)
/// even though the request itself (`fetchHistory(state.active_id, "session")`,
/// line 83) never reads `range`: a range-tab change still re-fetches the
/// current session's samples alongside analytics, matching that dependency
/// array exactly.
private struct HistoryBurnTaskKey: Equatable {
    let range: HistoryRangeKey
    let accountID: String?
}

// MARK: - view

struct HistorySectionView: View {
    /// Charts.tsx:24 / BurnRate.tsx:93-98 — the ONLY failure copy either
    /// surface shows, whatever the underlying error said.
    static let unavailableCopy = "History unavailable — daemon too old or still indexing."

    @ObservedObject var model: HistorySectionModel
    let state: DaemonState

    @Environment(\.colorScheme) private var colorScheme
    @State private var open: Bool

    init(model: HistorySectionModel, state: DaemonState, defaultOpen: Bool = false) {
        self.model = model
        self.state = state
        _open = State(initialValue: defaultOpen)
    }

    private var dark: Bool { colorScheme == .dark }
    private var cockpit: CockpitViewModel { model.cockpit }

    private var hasShared: Bool { HistoryDerivation.hasShared(cockpit.analytics?.cells ?? []) }
    private var accountOptions: [HistoryDerivation.AccountOption] {
        HistoryDerivation.accountOptions(accounts: state.accounts, hasShared: hasShared)
    }
    private var selected: Set<String> { model.customSelected ?? Set(accountOptions.map(\.id)) }

    /// Charts.tsx line 132: `dateOnly(state.as_of)`. See the file header for
    /// the `boardTimeISOString` bridge.
    private var todayStr: String { HistoryFormat.dateOnly(boardTimeISOString(from: state.asOf)) }
    private var cutoff: String { HistoryDerivation.cutoff(today: todayStr, rangeDays: model.range.days) }

    private var filteredCells: [AnalyticsCell] {
        guard let analytics = cockpit.analytics else { return [] }
        return HistoryDerivation.filteredCells(analytics.cells, cutoff: cutoff, today: todayStr, selected: selected)
    }

    private var accountsCaption: String {
        HistoryDerivation.accountsCaption(selectedCount: selected.count, totalCount: accountOptions.count)
    }

    /// Loads gate on `open` (History.tsx mounts <Charts> only when the
    /// disclosure is expanded — a collapsed section must not trigger the
    /// analytics JSONL re-index); `open` rides both task ids so expanding
    /// fires the first load.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if open {
                sectionBody
            }
        }
        .task(id: open ? model.range : nil) {
            guard open else { return }
            await model.loadAnalyticsIfNeeded()
        }
        .task(id: open ? HistoryBurnTaskKey(range: model.range, accountID: state.activeID) : nil) {
            guard open, let id = state.activeID else { return }
            await model.loadBurnSamples(activeAccountID: id)
        }
    }

    // History.tsx lines 15-23.
    private var header: some View {
        Button(action: { open.toggle() }) {
            HStack(spacing: 8) {
                Text(open ? "▼" : "▶")
                    .font(.system(size: 9))
                Text("History")
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundColor(CockpitTheme.sec)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) { Divider().overlay(CockpitTheme.hair) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("History")
        .accessibilityValue(open ? "expanded" : "collapsed")
    }

    @ViewBuilder
    private var sectionBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            HistoryFiltersRow(
                range: model.range,
                onRangeChange: { model.range = $0 },
                accountOptions: accountOptions,
                selected: selected,
                onToggle: { model.toggleAccount($0, options: accountOptions.map(\.id)) },
                onSelectAll: { model.selectAllAccounts() }
            )
            Text("\(model.range.rangeLabel) · \(accountsCaption)")
                .font(.system(size: 10.5))
                .foregroundColor(CockpitTheme.ter)
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 4)

            if cockpit.analytics == nil, cockpit.analyticsError == nil {
                Text("Loading history…")
                    .font(.system(size: 11))
                    .foregroundColor(CockpitTheme.ter)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            } else if cockpit.analyticsError != nil {
                // Charts.tsx:24 — a FIXED string on every failure; the raw
                // error (HTTP body, NSURL prose) never reaches the surface.
                HistoryQuietState(message: HistorySectionView.unavailableCopy, wide: true)
                    .padding(16)
            } else {
                cardsGrid
                    .opacity(model.isAnalyticsLoading ? 0.6 : 1)
                    .animation(.easeInOut(duration: CockpitTheme.Motion.swap), value: model.isAnalyticsLoading)

                HistoryDelightFooter(cells: filteredCells, range: model.range)
                HistoryTableView(cells: filteredCells)
            }
        }
    }

    private var cardsGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                BurnRateCard(
                    state: state,
                    analytics: cockpit.analytics,
                    samples: cockpit.history,
                    loading: model.isBurnLoading,
                    error: cockpit.historyError == nil ? nil : HistorySectionView.unavailableCopy,
                    todayStr: todayStr
                )
                .gridCellColumns(2)
            }
            GridRow {
                ModelMixCard(cells: filteredCells, dark: dark)
                ProjectsCard(cells: filteredCells)
            }
            GridRow {
                RhythmCard(hourWeekday: cockpit.analytics?.hourWeekday ?? [], dark: dark)
                ValueCard(
                    cells: filteredCells,
                    range: model.range,
                    planCostMonthly: cockpit.config?.planCostMonthly ?? [:],
                    selectedAccountIds: selected.filter { $0 != "" }
                )
            }
        }
        .padding(16)
    }
}

// MARK: - previews

private final class PreviewHistoryAPI: CockpitDaemonAPI & DaemonAPI, @unchecked Sendable {
    var analyticsResult: AnalyticsResponse?
    var historyResult: [HistorySample] = []

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
    func history(accountID: String, kind: String, scope: String?) async throws -> [HistorySample] { historyResult }
    func doctor() async throws -> DoctorReport { throw DaemonError.down }
    func analytics(days: Int) async throws -> AnalyticsResponse {
        guard let analyticsResult else { throw DaemonError.down }
        return analyticsResult
    }
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

private func previewCell(_ accountID: String, _ project: String, _ model: String, _ day: String, outMTok: Double) -> AnalyticsCell {
    let output = Int64((outMTok * 1_000_000).rounded())
    return AnalyticsCell(
        accountID: accountID, project: project, model: model, day: day,
        messages: max(1, Int64((outMTok * 900).rounded())),
        tokens: AnalyticsTokens(
            input: Int64((Double(output) * 0.35).rounded()),
            output: output,
            cacheCreation: Int64((Double(output) * 2.1).rounded()),
            cacheRead: Int64((Double(output) * 14).rounded())
        )
    )
}

@MainActor
private func makeHistoryPreview() -> HistorySectionView {
    let days = ["2026-08-01", "2026-08-02", "2026-08-03", "2026-08-04", "2026-08-05", "2026-08-06", "2026-08-07"]
    let cells = days.enumerated().flatMap { i, day in
        [
            previewCell("alex", "llmpilot", "claude-fable-5", day, outMTok: 2.1 + Double(i) * 0.4),
            previewCell("alex", "llmpilot", "claude-sonnet-5", day, outMTok: 1.2 + Double(i) * 0.15),
            previewCell("kai", "atlas", "claude-opus-4-8", day, outMTok: 0.8),
            previewCell("", "scratch", "claude-sonnet-5", day, outMTok: 0.15),
        ]
    }
    let hourWeekday: [[Int64]] = (0..<7).map { wd in
        (0..<24).map { h in
            let workday = (wd >= 1 && wd <= 5) ? 1.0 : 0.35
            let peak = exp(-pow(Double(h - 15), 2) / 18) + 0.55 * exp(-pow(Double(h - 22), 2) / 8)
            return Int64((2_400_000 * workday * peak).rounded())
        }
    }
    let jsonAsOf = "2026-08-07T14:31:00Z"
    let analytics = try! DaemonDates.decoder().decode(
        AnalyticsResponse.self,
        from: """
        {"cells":[],"hour_weekday":[],"files_total":0,"files_parsed":0,"files_reused":0,"as_of":"\(jsonAsOf)"}
        """.data(using: .utf8)!
    )
    var full = analytics
    full.cells = cells
    full.hourWeekday = hourWeekday

    let api = PreviewHistoryAPI()
    api.analyticsResult = full
    api.historyResult = (0..<20).map { i in
        let minute = 5 + i * 10
        let hour = 11 + minute / 60
        let iso = "2026-08-07T\(String(format: "%02d", hour)):\(String(format: "%02d", minute % 60)):00Z"
        let percent = (23 + 55 * pow(Double(i) / 19, 1.35)).rounded()
        return HistorySample(at: DaemonDates.parseRFC3339(iso)!, percent: percent)
    }

    let state = DaemonState(
        accounts: [
            AccountState(
                id: "alex", label: "alex", email: "alex@example.com", pinned: false,
                snapshot: UsageSnapshot(
                    asOf: DaemonDates.parseRFC3339(jsonAsOf)!,
                    buckets: [
                        Bucket(kind: "session", scope: nil, percent: 62, resetsAt: DaemonDates.parseRFC3339("2026-08-07T16:30:00Z"), severity: nil, active: true),
                    ]
                ),
                tokenNote: nil, stale: nil
            ),
            AccountState(id: "kai", label: "kai", email: "kai@example.com", pinned: false, snapshot: nil, tokenNote: nil, stale: nil),
        ],
        activeID: "alex", schedules: [], asOf: DaemonDates.parseRFC3339(jsonAsOf)!
    )

    let cockpit = CockpitViewModel(api: api)
    let model = HistorySectionModel(cockpit: cockpit)
    return HistorySectionView(model: model, state: state, defaultOpen: true)
}

#Preview("History — open") {
    makeHistoryPreview()
        .frame(width: 900)
}
