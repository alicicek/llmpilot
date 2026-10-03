import SwiftUI

// Native ports of web/src/history/Rhythm.tsx, Value.tsx, Delight.tsx, and
// TableView.tsx — the heatmap (a Grid of rects, per the brief), the value
// card (a plain progress bar, not a Charts mark — same "not every card needs
// Charts" allowance as the heatmap), the delight footer, and the
// WCAG-fallback table twin for ModelMix + Projects.

// MARK: - Rhythm (Rhythm.tsx)

struct RhythmCard: View {
    /// 7 rows (Sunday=0) × 24 local hours of total tokens — analytics'
    /// `hour_weekday` verbatim.
    let hourWeekday: [[Int64]]
    let dark: Bool

    private static let hourTicks: Set<Int> = [0, 6, 12, 18]
    private static let weekdayLabelsMonFirst = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    private var maxValue: Int64 { max(1, hourWeekday.flatMap { $0 }.max() ?? 0) }

    /// Rhythm.tsx `dataRowFor`: display rows are Mon-first, the API's rows
    /// are Sun-first (row 0 = Sunday).
    private func dataRow(forDisplayRow displayRow: Int) -> Int { (displayRow + 1) % 7 }

    /// What one cell paints. A zero cell is EMPTY — it never takes the
    /// ramp's weakest step, because on the dark ramp that step is a full
    /// blue and an idle week read as seven days of peak activity.
    enum Cell: Equatable {
        case empty
        case filled(hex: String)
    }

    static func cell(value: Int64, maxValue: Int64, dark: Bool) -> Cell {
        guard value > 0 else { return .empty }
        let t = Double(value) / Double(max(1, maxValue))
        return .filled(hex: HistoryColors.sequentialColor(t, dark: dark))
    }

    /// The hour-axis label for column `hour`, nil where the axis is blank.
    /// Each label sits in its OWN column of the grid, so 00/06/12/18 land
    /// over the cells they describe instead of collapsing into one run.
    static func hourLabel(_ hour: Int) -> String? {
        hourTicks.contains(hour) ? String(format: "%02d", hour) : nil
    }

    /// The day-label column's fixed width. The 24 cell columns are
    /// flexible, so without a floor the Grid shares the width 25 ways and
    /// "Mon" collapses to "…" (seen in the first re-capture).
    static let dayLabelWidth: CGFloat = 26

    var body: some View {
        HistoryCard(title: "Rhythm", subCaption: "your rhythm — quiet cells are good times for fresh windows") {
            // One Grid for labels and cells together: column 0 is the day
            // label, columns 1…24 are the hours — so the day labels sit
            // beside their rows and the hour ticks over their columns by
            // construction, whatever width the card gets.
            Grid(alignment: .leading, horizontalSpacing: 2, verticalSpacing: 2) {
                GridRow {
                    Color.clear.frame(width: Self.dayLabelWidth, height: 12)
                    ForEach(0..<24, id: \.self) { h in
                        Text(Self.hourLabel(h) ?? "")
                            .font(.system(size: 9))
                            .foregroundColor(CockpitTheme.ter)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(height: 12)
                    }
                }
                ForEach(0..<7, id: \.self) { displayRow in
                    weekdayRow(displayRow)
                }
            }
            .accessibilityLabel("Token activity by hour of day and day of week, a 24 by 7 heatmap")
        }
    }

    private func weekdayRow(_ displayRow: Int) -> some View {
        let row = hourWeekday.indices.contains(dataRow(forDisplayRow: displayRow)) ? hourWeekday[dataRow(forDisplayRow: displayRow)] : []
        return GridRow {
            Text(Self.weekdayLabelsMonFirst[displayRow])
                .font(.system(size: 9))
                .foregroundColor(CockpitTheme.ter)
                .lineLimit(1)
                .frame(width: Self.dayLabelWidth, height: 14, alignment: .leading)
            ForEach(0..<24, id: \.self) { hour in
                let v = row.indices.contains(hour) ? row[hour] : 0
                RoundedRectangle(cornerRadius: 2)
                    .fill(cellColor(Self.cell(value: v, maxValue: maxValue, dark: dark)))
                    .frame(maxWidth: .infinity)
                    .frame(height: 14)
                    .help("\(Self.weekdayLabelsMonFirst[displayRow]) \(String(format: "%02d", hour)):00 — \(HistoryFormat.formatTokens(Double(v))) tokens")
            }
        }
    }

    private func cellColor(_ cell: Cell) -> Color {
        switch cell {
        case .empty: return CockpitTheme.hatchBg
        case let .filled(hex): return historyColor(hex)
        }
    }
}

// MARK: - Value (Value.tsx)

struct ValueCard: View {
    let cells: [AnalyticsCell]
    let range: HistoryRangeKey
    /// account id -> monthly plan cost, from the daemon's
    /// `plan_cost_monthly` config (loaded via `cockpitConfig()`); empty
    /// when unset or the fetch failed, degrading to the $0 presentation.
    let planCostMonthly: [String: Double]
    /// Real account ids only — "" (shared) already excluded by the caller,
    /// mirroring Value.tsx's `selectedAccountIds` contract.
    let selectedAccountIds: [String]

    private var valueSummary: HistoryAggregate.ValueSummary { HistoryAggregate.valueSummary(cells) }
    private var planCost: Double {
        ValueDerivation.planCost(selectedAccountIds: selectedAccountIds, perAccount: planCostMonthly, rangeDays: range.days)
    }
    private var summary: ValueDerivation.Summary { ValueDerivation.summary(total: valueSummary.total, planCost: planCost) }

    var body: some View {
        HistoryCard(title: "Value extracted", subCaption: "API-equivalent value vs plan cost, this range") {
            VStack(alignment: .leading, spacing: 6) {
                Text(HistoryFormat.formatUSD(summary.total))
                    .font(CockpitTheme.numeric(28, weight: .semibold))
                    .foregroundColor(CockpitTheme.text)

                if !valueSummary.unpricedIds.isEmpty {
                    Text("excl. \(valueSummary.unpricedIds.count) unpriced models")
                        .font(.system(size: 10))
                        .foregroundColor(CockpitTheme.ter)
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4).fill(CockpitTheme.rail)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(CockpitTheme.accent)
                            .frame(width: geo.size.width * min(1, summary.pulledPct / 100))
                        Rectangle()
                            .fill(CockpitTheme.text)
                            .frame(width: 2, height: 16)
                            .offset(x: geo.size.width * min(1, summary.planPct / 100) - 1, y: -3)
                    }
                }
                .frame(height: 10)
                .padding(.top, 4)
                .accessibilityHidden(true)

                Text(summary.caption)
                    .font(.system(size: 11))
                    .foregroundColor(CockpitTheme.sec)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Value extracted: \(summary.caption)")
    }
}

// MARK: - DelightFooter (Delight.tsx)

struct HistoryDelightFooter: View {
    let cells: [AnalyticsCell]
    let range: HistoryRangeKey

    private var factorStr: String? {
        HistoryDelight.hobbitFactorString(HistoryDerivation.totalTokensSum(cells))
    }

    var body: some View {
        if let factorStr {
            Text("≈ \(factorStr)× The Hobbit \(range.scopeWord)")
                .font(.system(size: 10.5))
                .foregroundColor(CockpitTheme.ter)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
        }
    }
}

// MARK: - TableView (TableView.tsx) — the WCAG-clean twin of ModelMix + Projects

struct HistoryTableView: View {
    let cells: [AnalyticsCell]

    @State private var expanded = false

    private var segments: [HistoryAggregate.Segment] {
        HistoryAggregate.buildSegments(HistoryAggregate.groupByFamily(cells))
    }
    private var totalTok: Int64 { segments.reduce(Int64(0)) { $0 + $1.tokens } }
    private var top: HistoryAggregate.TopProjects { HistoryAggregate.topProjects(cells) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: { expanded.toggle() }) {
                Text("as table")
                    .font(.system(size: 10.5))
                    .foregroundColor(CockpitTheme.ter)
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 16) {
                    modelMixTable
                    projectsTable
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    private var modelMixTable: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Model mix")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(CockpitTheme.sec)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                GridRow {
                    Text("Model").tableHeader()
                    Text("Tokens").tableHeader(trailing: true)
                    Text("Share").tableHeader(trailing: true)
                    Text("Value").tableHeader(trailing: true)
                }
                Divider().overlay(CockpitTheme.hairSoft)
                ForEach(segments, id: \.family) { s in
                    GridRow {
                        Group {
                            if s.unpricedIds.isEmpty {
                                Text(s.family)
                            } else {
                                Text(s.family) + Text(" (\(s.unpricedIds.sorted().joined(separator: ", ")))").foregroundColor(CockpitTheme.ter)
                            }
                        }
                        .font(.system(size: 11))
                        .gridColumnAlignment(.leading)
                        Text(HistoryFormat.formatTokens(Double(s.tokens))).tableCell()
                        Text(totalTok > 0 ? "\(Int((Double(s.tokens) / Double(totalTok) * 100).rounded()))%" : "0%").tableCell()
                        Text(HistoryFormat.formatUSD(s.value)).tableCell()
                    }
                }
            }
        }
    }

    private var projectsTable: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Projects")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(CockpitTheme.sec)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                GridRow {
                    Text("Project").tableHeader()
                    Text("Tokens").tableHeader(trailing: true)
                    Text("Value").tableHeader(trailing: true)
                }
                Divider().overlay(CockpitTheme.hairSoft)
                ForEach(top.rows, id: \.project) { r in
                    GridRow {
                        Text(r.project).font(.system(size: 11)).gridColumnAlignment(.leading)
                        Text(HistoryFormat.formatTokens(Double(r.tokens))).tableCell()
                        Text(HistoryFormat.formatUSD(r.value)).tableCell()
                    }
                }
                if top.otherCount > 0 {
                    GridRow {
                        Text("other (\(top.otherCount))").font(.system(size: 11)).gridColumnAlignment(.leading)
                        Text(HistoryFormat.formatTokens(Double(top.otherTokens))).tableCell()
                        Text("—").tableCell()
                    }
                }
            }
        }
    }
}

private extension Text {
    func tableHeader(trailing: Bool = false) -> some View {
        self.font(.system(size: 10, weight: .medium))
            .foregroundColor(CockpitTheme.ter)
            .frame(maxWidth: .infinity, alignment: trailing ? .trailing : .leading)
            .gridColumnAlignment(trailing ? .trailing : .leading)
    }

    func tableCell() -> some View {
        self.font(CockpitTheme.numeric(11))
            .foregroundColor(CockpitTheme.text)
            .gridColumnAlignment(.trailing)
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
    ]
}

private func stubHourWeekday() -> [[Int64]] {
    (0..<7).map { wd in
        (0..<24).map { h in
            let workday = (wd >= 1 && wd <= 5) ? 1.0 : 0.35
            let peak = exp(-pow(Double(h - 15), 2) / 18) + 0.55 * exp(-pow(Double(h - 22), 2) / 8)
            return Int64((2_400_000 * workday * peak).rounded())
        }
    }
}

#Preview("Rhythm — data") {
    RhythmCard(hourWeekday: stubHourWeekday(), dark: false)
        .frame(width: 520).padding()
}

#Preview("Rhythm — dark") {
    RhythmCard(hourWeekday: stubHourWeekday(), dark: true)
        .frame(width: 520).padding()
        .preferredColorScheme(.dark)
}

#Preview("Value — with plan cost") {
    ValueCard(cells: stubCells(), range: .sevenDay, planCostMonthly: ["alex": 200, "kai": 200], selectedAccountIds: ["alex", "kai"])
        .frame(width: 360).padding()
}

#Preview("Value — no plan cost on file") {
    ValueCard(cells: stubCells(), range: .sevenDay, planCostMonthly: [:], selectedAccountIds: ["alex", "kai"])
        .frame(width: 360).padding()
}

#Preview("Delight footer") {
    HistoryDelightFooter(cells: stubCells(), range: .sevenDay)
}

#Preview("Table twin") {
    HistoryTableView(cells: stubCells())
        .frame(width: 520)
}
