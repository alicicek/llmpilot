import XCTest
@testable import llmpilot

/// Tests for the Phase-1 chunk-C History section's OWN derivation logic —
/// the filter/grid/verdict glue HistorySectionView.swift/HistoryCards*.swift
/// add on top of the already-ported pure math in Support/HistoryMath.swift
/// (covered by HistoryVectorTests.swift's golden vectors, not re-tested
/// here). Four areas per the build brief: filteredCells (range cutoff vs a
/// fixed as_of, account filter, shared label), the buildSegments-to-bar
/// mapping's all-zero edge, burn-rate projection-chip formatting against a
/// known offset-carrying sample set, and the Value card's plan-cost
/// derivation.
final class HistoryDerivationTests: XCTestCase {
    // MARK: - fixtures

    private func tokens(outMTok: Double) -> AnalyticsTokens {
        let output = Int64((outMTok * 1_000_000).rounded())
        return AnalyticsTokens(
            input: Int64((Double(output) * 0.35).rounded()),
            output: output,
            cacheCreation: Int64((Double(output) * 2.1).rounded()),
            cacheRead: Int64((Double(output) * 14).rounded())
        )
    }

    private func cell(_ accountID: String, _ project: String, _ model: String, _ day: String, outMTok: Double) -> AnalyticsCell {
        AnalyticsCell(accountID: accountID, project: project, model: model, day: day, messages: 1, tokens: tokens(outMTok: outMTok))
    }

    // MARK: - HistoryDerivation.filteredCells (Charts.tsx lines 132-137)

    func testFilteredCellsAppliesRangeCutoffAgainstFixedToday() {
        // "today" is state.as_of's own date, never device now — this test
        // pins a today far from the actual test-run date to prove the
        // cutoff math, not wall-clock behavior.
        let today = "2026-07-10"
        let cutoff7d = HistoryDerivation.cutoff(today: today, rangeDays: 7) // addDays(today, -6)
        XCTAssertEqual(cutoff7d, "2026-07-04")

        let cells = [
            cell("a", "p", "claude-sonnet-5", "2026-07-03", outMTok: 1), // before cutoff — excluded
            cell("a", "p", "claude-sonnet-5", "2026-07-04", outMTok: 1), // on cutoff — included
            cell("a", "p", "claude-sonnet-5", "2026-07-10", outMTok: 1), // == today — included
            cell("a", "p", "claude-sonnet-5", "2026-07-11", outMTok: 1), // after today — excluded (future data never leaks in)
        ]
        let selected: Set<String> = ["a"]
        let got = HistoryDerivation.filteredCells(cells, cutoff: cutoff7d, today: today, selected: selected)
        XCTAssertEqual(Set(got.map(\.day)), ["2026-07-04", "2026-07-10"])
    }

    func testFilteredCellsAppliesAccountFilterAndSharedLabel() {
        let today = "2026-07-10"
        let cells = [
            cell("alex", "p", "claude-sonnet-5", today, outMTok: 1),
            cell("kai", "p", "claude-sonnet-5", today, outMTok: 1),
            cell("", "scratch", "claude-sonnet-5", today, outMTok: 1), // "" = shared
        ]
        // Only "alex" selected — kai and shared both excluded.
        var got = HistoryDerivation.filteredCells(cells, cutoff: today, today: today, selected: ["alex"])
        XCTAssertEqual(got.map(\.accountID), ["alex"])

        // Explicitly selecting the shared "" id includes the shared row.
        got = HistoryDerivation.filteredCells(cells, cutoff: today, today: today, selected: ["alex", ""])
        XCTAssertEqual(Set(got.map(\.accountID)), ["alex", ""])

        // Empty selection excludes everything, including shared.
        got = HistoryDerivation.filteredCells(cells, cutoff: today, today: today, selected: [])
        XCTAssertTrue(got.isEmpty)
    }

    func testAccountOptionsAppendsSharedOnlyWhenPresentInCells() {
        let accounts = [
            AccountState(id: "alex", label: "Alex", email: "alex@example.com", pinned: false, snapshot: nil, tokenNote: nil, stale: nil),
            AccountState(id: "kai", label: "", email: "kai@example.com", pinned: false, snapshot: nil, tokenNote: nil, stale: nil),
        ]
        let withoutShared = HistoryDerivation.accountOptions(accounts: accounts, hasShared: false)
        XCTAssertEqual(withoutShared.map(\.id), ["alex", "kai"])
        // `a.label || a.email` — an empty label falls back to email.
        XCTAssertEqual(withoutShared.map(\.label), ["Alex", "kai@example.com"])

        let withShared = HistoryDerivation.accountOptions(accounts: accounts, hasShared: true)
        XCTAssertEqual(withShared.map(\.id), ["alex", "kai", ""])
        XCTAssertEqual(withShared.last?.label, "shared")
    }

    func testAccountsCaptionThreeWayLabel() {
        XCTAssertEqual(HistoryDerivation.accountsCaption(selectedCount: 0, totalCount: 3), "no accounts")
        XCTAssertEqual(HistoryDerivation.accountsCaption(selectedCount: 3, totalCount: 3), "all accounts")
        XCTAssertEqual(HistoryDerivation.accountsCaption(selectedCount: 1, totalCount: 3), "1 of 3 accounts")
    }

    // MARK: - ModelMixDerivation.withShares — buildSegments-to-bar mapping

    func testModelMixWithSharesAllZeroYieldsNoBarSegments() {
        // No cells at all: groupByFamily -> [], buildSegments -> [] — the
        // card's own `total == 0` check (mirrored by the empty withShares
        // result here) is what routes it to QuietState instead of a bar.
        let segments = HistoryAggregate.buildSegments(HistoryAggregate.groupByFamily([]))
        XCTAssertTrue(segments.isEmpty)
        XCTAssertTrue(ModelMixDerivation.withShares(segments).isEmpty)
    }

    func testModelMixWithSharesComputesShareAndCumulativeMidpoint() {
        let cells = [
            cell("a", "p", "claude-fable-5", "2026-07-10", outMTok: 3), // Fable: 3M out + 1.05M in io-tokens
            cell("a", "p", "claude-sonnet-5", "2026-07-10", outMTok: 1), // Sonnet: 1M out + 0.35M in io-tokens
        ]
        let segments = HistoryAggregate.buildSegments(HistoryAggregate.groupByFamily(cells))
        let withShares = ModelMixDerivation.withShares(segments)
        XCTAssertEqual(withShares.count, 2)
        let totalShare = withShares.reduce(0) { $0 + $1.share }
        XCTAssertEqual(totalShare, 100, accuracy: 1e-9)
        // First segment's midpoint sits at half its own share; the second's
        // midpoint starts where the first's cumulative share ends.
        XCTAssertEqual(withShares[0].mid, withShares[0].share / 2, accuracy: 1e-9)
        XCTAssertEqual(withShares[1].mid, withShares[0].share + withShares[1].share / 2, accuracy: 1e-9)
    }

    // MARK: - BurnRateDerivation — projection-chip formatting

    private func iso(_ s: String) -> Date { DaemonDates.parseRFC3339(s)! }

    func testVerdictNoProjectionShowsResetOnly() {
        let v = BurnRateDerivation.verdict(projectedMs: nil, resetMs: 1000, resetStr: "16:30", offsetMinutes: 0)
        XCTAssertEqual(v.text, "resets 16:30")
        XCTAssertEqual(v.tone, .ter)
    }

    func testVerdictWallBeforeResetIsTightWarning() {
        // Known offset-carrying fixture: reset at 16:30Z, projected wall at
        // 16:05Z (before the reset) — mirrors BurnRate.tsx's "will be tight"
        // branch (lines 115-117).
        let resetAt = iso("2026-07-10T16:30:00Z")
        let projectedAt = iso("2026-07-10T16:05:00Z")
        let resetMs = resetAt.timeIntervalSince1970 * 1000
        let projectedMs = projectedAt.timeIntervalSince1970 * 1000
        let resetStr = HistoryFormat.hhmm(boardTimeISOString(from: resetAt))
        let offset = HistoryFormat.isoOffsetMinutes(boardTimeISOString(from: resetAt))
        XCTAssertEqual(offset, 0) // this app's wire dates are always UTC — see file header note

        let v = BurnRateDerivation.verdict(projectedMs: projectedMs, resetMs: resetMs, resetStr: resetStr, offsetMinutes: offset)
        XCTAssertEqual(v.text, "wall ≈ 16:05 · resets 16:30 ⚠ — will be tight")
        XCTAssertEqual(v.tone, .warn)
    }

    func testVerdictResetBeforeWallIsSafe() {
        let resetAt = iso("2026-07-10T16:30:00Z")
        let projectedAt = iso("2026-07-10T18:00:00Z") // wall comes AFTER the reset
        let resetStr = HistoryFormat.hhmm(boardTimeISOString(from: resetAt))
        let v = BurnRateDerivation.verdict(
            projectedMs: projectedAt.timeIntervalSince1970 * 1000,
            resetMs: resetAt.timeIntervalSince1970 * 1000,
            resetStr: resetStr, offsetMinutes: 0
        )
        XCTAssertEqual(v.text, "resets before the wall ✓")
        XCTAssertEqual(v.tone, .ok)
    }

    func testRateStrSwitchesPrecisionAtTenDollars() {
        XCTAssertEqual(BurnRateDerivation.rateStr(4.26), "≈ $4.3/h") // < 10 -> one decimal
        XCTAssertEqual(BurnRateDerivation.rateStr(12.6), "≈ $13/h") // >= 10 -> rounded integer
        XCTAssertEqual(BurnRateDerivation.rateStr(0), "≈ $0.0/h")
    }

    func testActiveBucketRequiresSessionOrFiveHourActiveWithResetsAt() {
        let resetsAt = iso("2026-07-10T16:30:00Z")
        let account = AccountState(
            id: "alex", label: "alex", email: "alex@example.com", pinned: false,
            snapshot: UsageSnapshot(asOf: iso("2026-07-10T14:00:00Z"), buckets: [
                Bucket(kind: "weekly_all", scope: nil, percent: 40, resetsAt: resetsAt, severity: nil, active: true), // wrong kind
                Bucket(kind: "session", scope: nil, percent: 62, resetsAt: nil, severity: nil, active: true), // no resetsAt
                Bucket(kind: "session", scope: nil, percent: 62, resetsAt: resetsAt, severity: nil, active: false), // not active
                Bucket(kind: "session", scope: nil, percent: 71, resetsAt: resetsAt, severity: nil, active: true), // matches
            ]),
            tokenNote: nil, stale: nil
        )
        let state = DaemonState(accounts: [account], activeID: "alex", schedules: [], asOf: iso("2026-07-10T14:00:00Z"))
        let got = BurnRateDerivation.activeBucket(state)
        XCTAssertEqual(got?.percent, 71)
    }

    // MARK: - ValueDerivation — plan-cost comparison (Value.tsx)

    func testPlanCostProratesByRangeAndSumsSelectedAccountsOnly() {
        let perAccount = ["alex": 200.0, "kai": 100.0, "mira": 999.0]
        // 7-day range: prorate = 7/30. Only alex+kai selected — mira excluded.
        let got = ValueDerivation.planCost(selectedAccountIds: ["alex", "kai"], perAccount: perAccount, rangeDays: 7)
        XCTAssertEqual(got, 300.0 * (7.0 / 30.0), accuracy: 1e-9)
    }

    func testPlanCostFallsBackToZeroWhenAccountMissingFromTheDictionary() {
        // The "$0, honestly, when unreachable" fallback: an id with no
        // entry in `perAccount` contributes 0, never a guessed number.
        let got = ValueDerivation.planCost(selectedAccountIds: ["ghost"], perAccount: [:], rangeDays: 30)
        XCTAssertEqual(got, 0)
    }

    func testValueSummaryRatioAndCaptionAgainstAKnownPlanCost() {
        let summary = ValueDerivation.summary(total: 300, planCost: 100)
        XCTAssertEqual(summary.ratio ?? -1, 3.0, accuracy: 1e-9)
        XCTAssertTrue(summary.caption.hasSuffix("· 3.0×"), summary.caption)
        XCTAssertTrue(summary.caption.hasPrefix("≈ $300 pulled vs ≈ $100 plan spend"), summary.caption)
    }

    func testValueSummaryRatioIsNilWhenPlanCostIsZero() {
        // Value.tsx line 24: `ratio = planCost > 0 ? total / planCost : null`
        // — no plan cost on file (config unset, or the cockpitConfig fetch
        // failed) must never divide by zero or fabricate a multiplier.
        let summary = ValueDerivation.summary(total: 42, planCost: 0)
        XCTAssertNil(summary.ratio)
        XCTAssertFalse(summary.caption.contains("×"))
        // Both values are under the $100 threshold, so formatUSD keeps two
        // decimals (format.ts `n.toFixed(n >= 100 ? 0 : 2)`).
        XCTAssertEqual(summary.caption, "≈ $42.00 pulled vs ≈ $0.00 plan spend")
    }

    func testValueSummaryBarMaxCoversBothBarsWithHeadroom() {
        // Value.tsx line 25: `barMax = Math.max(total, planCost, 1) * 1.15`.
        let summary = ValueDerivation.summary(total: 50, planCost: 80)
        XCTAssertEqual(summary.barMax, 80 * 1.15, accuracy: 1e-9)
        XCTAssertEqual(summary.pulledPct, (50 / summary.barMax) * 100, accuracy: 1e-9)
        XCTAssertEqual(summary.planPct, 100 / 1.15, accuracy: 1e-9)
    }
}
