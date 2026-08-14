import XCTest

// The cancellation contract (delta-review P1): a cancelled sweep must keep
// the last good state, write no error, and un-burn the reload key so the
// next .task fire retries. One SSE blip mid-sweep must never wedge the
// panel on "could not check the fleet".
@MainActor
final class DoctorPanelCancellationTests: XCTestCase {
    private enum DoctorFixtures {
        // Through the same JSON decode path production uses (custom inits).
        static var cleanReport: DoctorReport {
            let json = """
            {"as_of":"2026-08-07T12:00:00Z","clean":true,"problems":0,
             "findings":[],"checks":[{"id":"c1","title":"Check","state":"ok"}]}
            """
            return try! DaemonDates.decoder().decode(DoctorReport.self, from: Data(json.utf8))
        }
    }

    func testCancelledSweepKeepsStateAndRetriesOnNextFire() async {
        let api = StubCockpitAPI()
        let model = DoctorPanelModel(api: api, onAddAccount: {}, onReviewStash: {})

        api.doctorResult = .failure(CancellationError())
        await model.reloadIfKeyChanged("k1")
        XCTAssertNil(model.sweepErr, "a cancelled sweep is not a failed sweep")
        XCTAssertNil(model.report)
        XCTAssertEqual(api.doctorCalls, 1)

        // Same key again: the cancelled attempt must NOT have burned it.
        api.doctorResult = .success(DoctorFixtures.cleanReport)
        await model.reloadIfKeyChanged("k1")
        XCTAssertEqual(api.doctorCalls, 2, "the un-burned key must retry")
        XCTAssertNotNil(model.report)
        XCTAssertNil(model.sweepErr)
    }

    func testCancellationMidRefreshKeepsLastGoodReport() async {
        let api = StubCockpitAPI()
        let model = DoctorPanelModel(api: api, onAddAccount: {}, onReviewStash: {})
        api.doctorResult = .success(DoctorFixtures.cleanReport)
        await model.reloadIfKeyChanged("k1")
        XCTAssertNotNil(model.report)

        api.doctorResult = .failure(CancellationError())
        await model.reloadIfKeyChanged("k2")
        XCTAssertNotNil(model.report, "a cancelled refresh must keep the last good report")
        XCTAssertNil(model.sweepErr)
    }
}
@testable import llmpilot

@MainActor
final class DoctorPanelModelTests: XCTestCase {
    // MARK: - fixture builders

    /// DoctorReport has a custom `init(from:)` (CockpitModels.swift:143-151)
    /// — build fixtures through the same JSON decode path production uses.
    private func report(clean: Bool, problems: Int, findings: [String] = [], checks: [String]) -> DoctorReport {
        let json = """
        {"as_of":"2026-08-07T12:00:00Z","clean":\(clean),"problems":\(problems),
         "findings":[\(findings.joined(separator: ","))],"checks":[\(checks.joined(separator: ","))]}
        """
        return try! DaemonDates.decoder().decode(DoctorReport.self, from: json.data(using: .utf8)!)
    }

    private func check(id: String = "c1", title: String = "Check", state: String, why: String? = nil) -> String {
        var s = "{\"id\":\"\(id)\",\"title\":\"\(title)\",\"state\":\"\(state)\""
        if let why { s += ",\"why\":\"\(why)\"" }
        s += "}"
        return s
    }

    private func finding(
        id: String = "f1", severity: String = "warning", title: String = "Finding", detail: String = "detail",
        verb: String = "none", target: String? = nil
    ) -> String {
        let targetFragment = target.map { ",\"target\":\"\($0)\"" } ?? ""
        return """
        {"id":"\(id)","check":"\(id)","severity":"\(severity)","title":"\(title)","detail":"\(detail)",\
        "accounts":[],"remedy":{"verb":"\(verb)","label":"Fix"\(targetFragment)}}
        """
    }

    private func makeModel(_ api: StubCockpitAPI) -> DoctorPanelModel {
        DoctorPanelModel(api: api, onAddAccount: {}, onReviewStash: {})
    }

    // MARK: - headline: strict 4-branch (DoctorPanel.tsx:96-105)

    func testHeadlineBranches() async {
        struct Case { let name: String; let report: DoctorReport; let expected: String }
        let cases: [Case] = [
            Case(
                name: "all clear, one check",
                report: report(clean: true, problems: 0, checks: [check(state: "ok")]),
                expected: "No problems found — all 1 checks ran."),
            Case(
                name: "all clear, plural checks",
                report: report(clean: true, problems: 0, checks: [check(id: "c1", state: "ok"), check(id: "c2", state: "ok")]),
                expected: "No problems found — all 2 checks ran."),
            Case(
                name: "one problem, singular",
                report: report(
                    clean: false, problems: 1, findings: [finding()],
                    checks: [check(state: "finding")]),
                expected: "1 problem found"),
            Case(
                name: "multiple problems, plural",
                report: report(
                    clean: false, problems: 2, findings: [finding(id: "f1"), finding(id: "f2")],
                    checks: [check(state: "finding")]),
                expected: "2 problems found"),
            Case(
                name: "not-checked branch wins over a false clean flag",
                report: report(
                    clean: false, problems: 0,
                    checks: [check(id: "c1", state: "ok"), check(id: "c2", state: "not_checked", why: "no profile")]),
                expected: "No problems found, but 1 of 2 checks could not run"),
            Case(
                name: "does not add up: clean=false, problems=0, nothing unchecked",
                report: report(clean: false, problems: 0, checks: [check(state: "ok")]),
                expected: "This report does not add up — llmpilot cannot confirm the fleet is healthy."),
            Case(
                name: "does not add up: clean=true but a real problem is unresolved by the flag",
                // clean=true yet notChecked is non-empty AND problems==0 still
                // routes to branch 3 (not-checked), never branch 1 — allClear
                // requires BOTH clean AND zero not-checked.
                report: report(
                    clean: true, problems: 0,
                    checks: [check(id: "c1", state: "ok"), check(id: "c2", state: "not_checked", why: "x")]),
                expected: "No problems found, but 1 of 2 checks could not run"),
        ]
        for c in cases {
            let api = StubCockpitAPI()
            api.doctorResult = .success(c.report)
            let model = makeModel(api)
            await model.load()
            XCTAssertEqual(model.headline, c.expected, c.name)
        }
    }

    // MARK: - notes line

    func testNotesIsFindingsMinusProblems() async {
        let api = StubCockpitAPI()
        api.doctorResult = .success(report(
            clean: false, problems: 1,
            findings: [finding(id: "f1", severity: "critical", verb: "none"), finding(id: "f2", severity: "info", verb: "none")],
            checks: [check(state: "finding")]))
        let model = makeModel(api)
        await model.load()
        XCTAssertEqual(model.notes, 1) // 2 findings - 1 problem
    }

    // MARK: - not-checked singular/plural header

    func testNotCheckedHeaderSingular() async {
        let api = StubCockpitAPI()
        api.doctorResult = .success(report(
            clean: true, problems: 0,
            checks: [check(id: "c1", state: "ok"), check(id: "c2", state: "not_checked", why: "no profile")]))
        let model = makeModel(api)
        await model.load()
        XCTAssertEqual(model.notCheckedHeader, "Not checked (1) — llmpilot could not look at this:")
    }

    func testNotCheckedHeaderPlural() async {
        let api = StubCockpitAPI()
        api.doctorResult = .success(report(
            clean: true, problems: 0,
            checks: [
                check(id: "c1", state: "not_checked", why: "a"),
                check(id: "c2", state: "not_checked", why: "b"),
            ]))
        let model = makeModel(api)
        await model.load()
        XCTAssertEqual(model.notCheckedHeader, "Not checked (2) — llmpilot could not look at these:")
    }

    // MARK: - sweep failure (fetch error and zero-checks report)

    func testFetchErrorSurfacesAsSweepFailure() async {
        let api = StubCockpitAPI()
        api.doctorResult = .failure(DaemonError.http(500, "doctor: HTTP 500"))
        let model = makeModel(api)
        await model.load()
        XCTAssertNil(model.report)
        XCTAssertEqual(model.sweepErr, "doctor: HTTP 500")
    }

    func testEmptyChecksReportIsTreatedAsSweepFailure() async {
        // Mirrors web/src/api.ts fetchDoctor (lines 336-338): a sweep always
        // runs a fixed list of checks, so zero checks is not a health report.
        let api = StubCockpitAPI()
        api.doctorResult = .success(report(clean: true, problems: 0, checks: []))
        let model = makeModel(api)
        await model.load()
        XCTAssertNil(model.report)
        XCTAssertEqual(model.sweepErr, "the daemon answered without a single health check")
    }

    // MARK: - switch verb: empty-target guard

    func testSwitchVerbWithEmptyTargetIsNotActionable() async {
        let api = StubCockpitAPI()
        let findingJSON = finding(id: "f1", verb: "switch", target: "")
        api.doctorResult = .success(report(
            clean: false, problems: 1, findings: [findingJSON], checks: [check(state: "finding")]))
        let model = makeModel(api)
        await model.load()
        let f = model.report!.findings[0]
        XCTAssertEqual(model.remedyAction(for: f), .none)
        model.run(model.remedyAction(for: f))
        XCTAssertEqual(api.switchedTo, [], "an empty/nil target must never reach switchAccount")
    }

    func testSwitchVerbWithNoTargetAtAllIsNotActionable() async {
        let api = StubCockpitAPI()
        let findingJSON = finding(id: "f1", verb: "switch", target: nil)
        api.doctorResult = .success(report(
            clean: false, problems: 1, findings: [findingJSON], checks: [check(state: "finding")]))
        let model = makeModel(api)
        await model.load()
        let f = model.report!.findings[0]
        XCTAssertEqual(model.remedyAction(for: f), .none)
    }

    func testSwitchVerbWithRealTargetCallsSwitchAndReloads() async {
        let api = StubCockpitAPI()
        let initial = report(
            clean: false, problems: 1,
            findings: [finding(id: "f1", verb: "switch", target: "acct-b")],
            checks: [check(state: "finding")])
        let afterSwitch = report(clean: true, problems: 0, checks: [check(state: "ok")])
        api.doctorResult = .success(initial)
        api.switchResult = .success(())
        let model = makeModel(api)
        await model.load()
        let f = model.report!.findings[0]
        let action = model.remedyAction(for: f)
        XCTAssertEqual(action, .switchTo(target: "acct-b", findingID: "f1"))
        api.doctorResult = .success(afterSwitch) // what the reload should observe
        model.run(action)
        // Poll briefly for the detached Task to finish (busy flips back to nil).
        for _ in 0..<50 where model.busyFindingID != nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(api.switchedTo, ["acct-b"])
        XCTAssertEqual(model.headline, "No problems found — all 1 checks ran.")
    }

    // MARK: - reload-key change detection

    private func state(
        accountID: String = "a", stale: Bool? = nil, pinned: Bool = false, tokenNote: String? = nil,
        stashDeadCount: Int = 0, stashTotal: Int = 0, asOf: Date = Date()
    ) -> DaemonState {
        let account = AccountState(
            id: accountID, label: "a", email: "a@example.dev", pinned: pinned,
            snapshot: nil, tokenNote: tokenNote, stale: stale)
        var stash: [StashEntry] = []
        for i in 0..<stashTotal {
            stash.append(StashEntry(fingerprint: "fp\(i)", label: nil, stashedAt: asOf, dead: i < stashDeadCount))
        }
        return DaemonState(accounts: [account], activeID: accountID, schedules: [], stash: stash, asOf: asOf)
    }

    func testReloadKeyIgnoresAsOfChange() async {
        let api = StubCockpitAPI()
        api.doctorResult = .success(report(clean: true, problems: 0, checks: [check(state: "ok")]))
        let model = makeModel(api)
        let s1 = state(asOf: Date(timeIntervalSince1970: 0))
        let s2 = state(asOf: Date(timeIntervalSince1970: 1_000)) // only as_of moved
        XCTAssertEqual(doctorReloadKey(state: s1), doctorReloadKey(state: s2))
        await model.reloadIfKeyChanged(doctorReloadKey(state: s1))
        XCTAssertEqual(api.doctorCalls, 1)
        await model.reloadIfKeyChanged(doctorReloadKey(state: s2))
        XCTAssertEqual(api.doctorCalls, 1, "an as_of-only change must not re-trigger the sweep")
    }

    func testReloadKeyChangesOnStale() async {
        let s1 = state(stale: false)
        let s2 = state(stale: true)
        XCTAssertNotEqual(doctorReloadKey(state: s1), doctorReloadKey(state: s2))
        await assertReload(from: s1, to: s2)
    }

    func testReloadKeyChangesOnPinned() async {
        let s1 = state(pinned: false)
        let s2 = state(pinned: true)
        XCTAssertNotEqual(doctorReloadKey(state: s1), doctorReloadKey(state: s2))
        await assertReload(from: s1, to: s2)
    }

    func testReloadKeyChangesOnTokenNote() async {
        let s1 = state(tokenNote: nil)
        let s2 = state(tokenNote: "needs re-auth")
        XCTAssertNotEqual(doctorReloadKey(state: s1), doctorReloadKey(state: s2))
        await assertReload(from: s1, to: s2)
    }

    func testReloadKeyTreatsEmptyTokenNoteAsFalsyLikeJS() {
        // JS `a.token_note ? 1 : 0` is falsy for BOTH nil and "" — an empty
        // string must not flip the key, matching App.tsx's own truthiness.
        let s1 = state(tokenNote: nil)
        let s2 = state(tokenNote: "")
        XCTAssertEqual(doctorReloadKey(state: s1), doctorReloadKey(state: s2))
    }

    func testReloadKeyChangesOnStashDeadCount() async {
        let s1 = state(stashDeadCount: 0, stashTotal: 1)
        let s2 = state(stashDeadCount: 1, stashTotal: 1)
        XCTAssertNotEqual(doctorReloadKey(state: s1), doctorReloadKey(state: s2))
        await assertReload(from: s1, to: s2)
    }

    func testReloadKeyChangesOnStashLength() async {
        let s1 = state(stashTotal: 0)
        let s2 = state(stashTotal: 1)
        XCTAssertNotEqual(doctorReloadKey(state: s1), doctorReloadKey(state: s2))
        await assertReload(from: s1, to: s2)
    }

    private func assertReload(from s1: DaemonState, to s2: DaemonState) async {
        let api = StubCockpitAPI()
        api.doctorResult = .success(report(clean: true, problems: 0, checks: [check(state: "ok")]))
        let model = makeModel(api)
        await model.reloadIfKeyChanged(doctorReloadKey(state: s1))
        XCTAssertEqual(api.doctorCalls, 1)
        await model.reloadIfKeyChanged(doctorReloadKey(state: s2))
        XCTAssertEqual(api.doctorCalls, 2)
    }
}
