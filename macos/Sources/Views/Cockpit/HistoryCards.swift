import Charts
import SwiftUI

// Native ports of web/src/history/BurnRate.tsx, ModelMix.tsx, Projects.tsx —
// the three cards built on Swift Charts (line + two bar charts). Rhythm
// (heatmap grid), Value, DelightFooter, and the table twin live in
// HistoryCardsMore.swift.

// MARK: - BurnRate (BurnRate.tsx)

struct BurnRateCard: View {
    let state: DaemonState
    let analytics: AnalyticsResponse?
    let samples: [HistorySample]?
    let loading: Bool
    let error: String?
    /// Charts.tsx's `todayStr` (dateOnly(state.as_of)) — threaded in by the
    /// orchestrator rather than recomputed here, one source of truth for
    /// "today" per the file-header rule (never device Date.now).
    let todayStr: String

    private var bucket: Bucket? { BurnRateDerivation.activeBucket(state) }
    private var activeAccount: AccountState? { state.accounts.first { $0.id == state.activeID } }

    private var cellsToday: [AnalyticsCell] {
        (analytics?.cells ?? []).filter { $0.accountID == state.activeID && $0.day == todayStr }
    }

    private var activityHours: Int {
        guard let analytics else { return 1 }
        return BurnMath.hoursWithActivityToday(analytics.hourWeekday, todayStr)
    }

    private var rate: Double { BurnMath.hourlyRate(cellsToday, activityHours) }
    private var rateStr: String { BurnRateDerivation.rateStr(rate) }

    var body: some View {
        if let error {
            HistoryCard(title: "Burn rate", wide: true, loading: loading) {
                HistoryQuietState(message: error)
            }
        } else if let bucket, let resetsAt = bucket.resetsAt, let samples, !samples.isEmpty {
            chart(bucket: bucket, resetsAt: resetsAt, samples: samples)
        } else {
            HistoryCard(title: "Burn rate", wide: true, loading: loading) {
                HistoryQuietState(message: "No active window — burn appears when one starts.")
            }
        }
    }

    private func chart(bucket: Bucket, resetsAt: Date, samples: [HistorySample]) -> some View {
        let resetMs = resetsAt.timeIntervalSince1970 * 1000
        let projectedMs = BurnMath.projectWallMs(samples)
        // See HistorySectionView.swift's file header: this app's wire dates
        // are always UTC, so bridging back through boardTimeISOString and
        // reading isoOffsetMinutes reproduces the web's own offset read.
        let resetISO = boardTimeISOString(from: resetsAt)
        let resetStr = HistoryFormat.hhmm(resetISO)
        let offset = HistoryFormat.isoOffsetMinutes(resetISO)
        let verdict = BurnRateDerivation.verdict(projectedMs: projectedMs, resetMs: resetMs, resetStr: resetStr, offsetMinutes: offset)
        let last = samples[samples.count - 1]
        let projectedDate = projectedMs.map { Date(timeIntervalSince1970: $0 / 1000) }
        let label = activeAccount?.label ?? state.activeID ?? ""

        return HistoryCard(
            title: "Burn rate",
            subCaption: "\(label) — current 5h window",
            wide: true,
            loading: loading
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Chart {
                    ForEach(samples.indices, id: \.self) { i in
                        let s = samples[i]
                        AreaMark(
                            x: .value("Time", s.at),
                            y: .value("Percent", min(100, s.percent)),
                            series: .value("Series", "actual-area")
                        )
                        .foregroundStyle(CockpitTheme.accent.opacity(0.1))
                        LineMark(
                            x: .value("Time", s.at),
                            y: .value("Percent", min(100, s.percent)),
                            series: .value("Series", "actual")
                        )
                        .foregroundStyle(CockpitTheme.accent)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    }
                    if let projectedDate {
                        LineMark(
                            x: .value("Time", last.at),
                            y: .value("Percent", min(100, last.percent)),
                            series: .value("Series", "projection")
                        )
                        .foregroundStyle(CockpitTheme.accent.opacity(0.65))
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, dash: [1, 4]))
                        LineMark(
                            x: .value("Time", projectedDate),
                            y: .value("Percent", 100),
                            series: .value("Series", "projection")
                        )
                        .foregroundStyle(CockpitTheme.accent.opacity(0.65))
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, dash: [1, 4]))
                    }
                    RuleMark(x: .value("Reset", resetsAt))
                        .foregroundStyle(CockpitTheme.hairSoft)
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .annotation(position: .bottom, alignment: .center, spacing: 2) {
                            Text("resets \(resetStr)")
                                .font(.system(size: 9.5))
                                .foregroundColor(CockpitTheme.ter)
                        }
                }
                .chartYScale(domain: 0...100)
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 150)
                .accessibilityLabel(
                    "Burn rate — \(activeAccount?.label ?? "active account")'s current window, \(verdict.text), \(rateStr) API-equivalent per hour"
                )

                Text(verdict.text)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(toneColor(verdict.tone))
                Text("\(rateStr) API-equivalent")
                    .font(.system(size: 10.5))
                    .foregroundColor(CockpitTheme.ter)
            }
        }
    }

    private func toneColor(_ tone: BurnRateDerivation.Tone) -> Color {
        switch tone {
        case .ter: return CockpitTheme.ter
        case .warn: return CockpitTheme.warn
        case .ok: return CockpitTheme.ok
        }
    }
}

// MARK: - ModelMix (ModelMix.tsx)

struct ModelMixCard: View {
    let cells: [AnalyticsCell]
    let dark: Bool

    private var segments: [HistoryAggregate.Segment] {
        HistoryAggregate.buildSegments(HistoryAggregate.groupByFamily(cells))
    }
    private var withShares: [ModelMixDerivation.SegmentShare] { ModelMixDerivation.withShares(segments) }
    private var total: Int64 { segments.reduce(Int64(0)) { $0 + $1.tokens } }

    var body: some View {
        if total == 0 {
            HistoryCard(title: "Model mix") {
                HistoryQuietState(message: "No usage recorded in this range.")
            }
        } else {
            let ariaSummary = withShares.map { "\($0.segment.family) \(Int($0.share.rounded()))%" }.joined(separator: ", ")
            HistoryCard(title: "Model mix", subCaption: "share of input + output tokens by model, Fable first") {
                VStack(alignment: .leading, spacing: 10) {
                    Chart(withShares) { item in
                        BarMark(
                            x: .value("Tokens", item.segment.tokens),
                            y: .value("Row", "mix")
                        )
                        .foregroundStyle(historyColor(HistoryColors.colorForFamily(item.segment.family, dark: dark)))
                        .annotation(position: .overlay) {
                            if item.share >= 8 {
                                Text("\(Int(item.share.rounded()))%")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(historyColor(HistoryColors.textOnFamilyFill(item.segment.family, dark: dark)))
                            }
                        }
                    }
                    .chartLegend(.hidden)
                    .chartXAxis(.hidden)
                    .chartYAxis(.hidden)
                    .frame(height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .accessibilityLabel("Model mix by token share: \(ariaSummary)")

                    HistoryLegendRow(entries: withShares.map {
                        HistoryLegendEntry(
                            label: $0.segment.family,
                            color: historyColor(HistoryColors.colorForFamily($0.segment.family, dark: dark)),
                            share: $0.share
                        )
                    })
                }
            }
        }
    }
}

// MARK: - Projects (Projects.tsx)

struct ProjectsCard: View {
    let cells: [AnalyticsCell]

    private var top: HistoryAggregate.TopProjects { HistoryAggregate.topProjects(cells) }
    private var rows: [ProjectsDerivation.Row] { ProjectsDerivation.rows(top) }
    private var maxTokens: Int64 { rows.map(\.tokens).max() ?? 0 }
    private var totalTokens: Int64 { rows.reduce(Int64(0)) { $0 + $1.tokens } }

    var body: some View {
        if rows.isEmpty {
            HistoryCard(title: "Projects") {
                HistoryQuietState(message: "No usage recorded in this range.")
            }
        } else {
            let ariaSummary = rows.map { "\($0.project) \(HistoryFormat.formatTokens(Double($0.tokens)))" }.joined(separator: ", ")
            HistoryCard(title: "Projects", subCaption: "top 5 by tokens, this range") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(rows) { row in
                        projectRow(row)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Top projects by tokens: \(ariaSummary)")
            }
        }
    }

    private func projectRow(_ row: ProjectsDerivation.Row) -> some View {
        let widthPct = maxTokens > 0 ? Double(row.tokens) / Double(maxTokens) : 0
        let share = totalTokens > 0 ? (Double(row.tokens) / Double(totalTokens)) * 100 : 0
        return HStack(spacing: 8) {
            Text(row.project)
                .font(.system(size: 11))
                .foregroundColor(CockpitTheme.sec)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 104, alignment: .leading)
                .help(row.project)

            Chart {
                BarMark(x: .value("Tokens", max(row.tokens, 0)))
                    .foregroundStyle(CockpitTheme.accent)
            }
            .chartXScale(domain: 0...max(maxTokens, 1))
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 16)
            .help("\(row.project) · \(HistoryFormat.formatTokens(Double(row.tokens))) tok · \(HistoryFormat.formatUSD(row.value))")
            // A near-zero bar still needs a visible sliver — Projects.tsx
            // clamps to a 1.5% minimum width; Swift Charts has no per-mark
            // minimum-width primitive, so a hairline overlay stands in when
            // the real proportion would round away to nothing.
            .overlay(alignment: .leading) {
                // Projects.tsx:59 clamps EVERY bar to ≥1.5% width — a
                // 0.3%-share project must stay visible, not just a 0% one.
                if widthPct < 0.015 {
                    Rectangle().fill(CockpitTheme.accent).frame(width: 2)
                }
            }

            Text("\(Int(share.rounded()))%")
                .font(CockpitTheme.numeric(10.5))
                .foregroundColor(CockpitTheme.ter)
                .frame(width: 34, alignment: .trailing)
        }
    }
}

// MARK: - previews

private func stubTokens(outMTok: Double) -> AnalyticsTokens {
    let output = Int64((outMTok * 1_000_000).rounded())
    return AnalyticsTokens(
        input: Int64((Double(output) * 0.35).rounded()),
        output: output,
        cacheCreation: Int64((Double(output) * 2.1).rounded()),
        cacheRead: Int64((Double(output) * 14).rounded())
    )
}

private func stubCells() -> [AnalyticsCell] {
    [
        AnalyticsCell(accountID: "alex", project: "llmpilot", model: "claude-fable-5", day: "2026-08-07", messages: 40, tokens: stubTokens(outMTok: 2.4)),
        AnalyticsCell(accountID: "alex", project: "llmpilot", model: "claude-sonnet-5", day: "2026-08-07", messages: 20, tokens: stubTokens(outMTok: 1.1)),
        AnalyticsCell(accountID: "kai", project: "atlas", model: "claude-opus-4-8", day: "2026-08-07", messages: 12, tokens: stubTokens(outMTok: 0.8)),
        AnalyticsCell(accountID: "kai", project: "fleet-research", model: "claude-haiku-4-5", day: "2026-08-07", messages: 6, tokens: stubTokens(outMTok: 0.3)),
        AnalyticsCell(accountID: "", project: "scratch", model: "claude-sonnet-5", day: "2026-08-07", messages: 3, tokens: stubTokens(outMTok: 0.1)),
    ]
}

#Preview("ModelMix — data") {
    ModelMixCard(cells: stubCells(), dark: false)
        .frame(width: 420).padding()
}

#Preview("ModelMix — quiet") {
    ModelMixCard(cells: [], dark: false)
        .frame(width: 420).padding()
}

#Preview("Projects — data") {
    ProjectsCard(cells: stubCells())
        .frame(width: 420).padding()
}

#Preview("Projects — quiet") {
    ProjectsCard(cells: [])
        .frame(width: 420).padding()
}

#Preview("BurnRate — no active window") {
    let state = DaemonState(accounts: [], activeID: nil, schedules: [], asOf: Date())
    BurnRateCard(state: state, analytics: nil, samples: nil, loading: false, error: nil, todayStr: "2026-08-07")
        .frame(width: 640).padding()
}

#Preview("BurnRate — unavailable") {
    let state = DaemonState(accounts: [], activeID: nil, schedules: [], asOf: Date())
    BurnRateCard(state: state, analytics: nil, samples: nil, loading: false, error: "History unavailable — daemon too old or still indexing.", todayStr: "2026-08-07")
        .frame(width: 640).padding()
}
