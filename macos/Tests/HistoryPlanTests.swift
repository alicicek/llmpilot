import XCTest

@testable import llmpilot

/// "Plan your day from your history": when you use Claude Code, read from
/// the analytics heatmap, becomes daily window starts; applying replaces the
/// account's daily times and turns rolling off.
@MainActor
final class HistoryPlanTests: XCTestCase {
    /// A heatmap with `tokens` in each listed hour, on every weekday.
    private func heat(_ hours: [Int], tokens: Int64 = 1000) -> [[Int64]] {
        var row = [Int64](repeating: 0, count: 24)
        for h in hours { row[h] = tokens }
        return Array(repeating: row, count: 7)
    }

    func testAWorkdayGetsResetsWhileYouWork() {
        guard case let .plan(p) = HistoryPlan.make(hourWeekday: heat(Array(9..<18)), activeDays: 15) else {
            return XCTFail("a 09–18 workday made no plan")
        }
        XCTAssertEqual(p.startHour, 9)
        XCTAssertEqual(p.endHour, 18)
        // 3 h before the day, then the board's 5 h 15 min booking gap.
        XCTAssertEqual(p.starts.map { BoardSchedule.fmtHM($0) }, ["06:00", "11:15", "16:30"])
        XCTAssertEqual(p.resetsInDay.map { BoardSchedule.fmtHM($0) }, ["11:00", "16:15"])
        // Every pair of resets clears the board's booking gap.
        let resets = p.starts.map { ($0 + BoardSchedule.windowHours * 60) % BoardSchedule.dayMin }
        for (i, a) in resets.enumerated() {
            for b in resets[(i + 1)...] {
                XCTAssertGreaterThanOrEqual(BoardSchedule.circularGap(a, b), BoardSchedule.minGapMin)
            }
        }
    }

    func testANightOwlsDayWrapsMidnight() {
        guard case let .plan(p) = HistoryPlan.make(hourWeekday: heat([20, 21, 22, 23, 0, 1, 2]), activeDays: 10) else {
            return XCTFail("an evening day made no plan")
        }
        XCTAssertEqual(p.startHour, 20)
        XCTAssertEqual(p.endHour, 3)
        XCTAssertEqual(p.starts.map { BoardSchedule.fmtHM($0) }, ["17:00", "22:15"])
        XCTAssertEqual(p.resetsInDay.map { BoardSchedule.fmtHM($0) }, ["22:00"])
    }

    func testQuietHoursBelowAFifthOfThePeakDoNotCount() {
        var h = heat(Array(9..<18))
        for w in 0..<7 { h[w][23] = 100 } // a stray late check-in
        guard case let .plan(p) = HistoryPlan.make(hourWeekday: h, activeDays: 12) else { return XCTFail() }
        XCTAssertEqual(p.endHour, 18)
    }

    func testNoPlanWithoutEnoughHistoryOrAroundTheClock() {
        XCTAssertEqual(HistoryPlan.make(hourWeekday: heat(Array(9..<18)), activeDays: 4), .tooLittle)
        XCTAssertEqual(HistoryPlan.make(hourWeekday: heat([]), activeDays: 20), .tooLittle)
        XCTAssertEqual(HistoryPlan.make(hourWeekday: heat(Array(0..<24)), activeDays: 20), .allDay)
        XCTAssertEqual(HistoryPlan.make(hourWeekday: heat([9, 10]), activeDays: 20), .shortDay,
                       "a two-hour day gets no reset from a plan: none offered")
    }

    func testListAndSentence() {
        XCTAssertEqual(HistoryPlan.list([360, 675, 990]), "06:00, 11:15 and 16:30")
        XCTAssertEqual(HistoryPlan.list([360]), "06:00")
        let p = HistoryPlan.Plan(startHour: 9, endHour: 18, starts: [360, 675], resetsInDay: [660])
        XCTAssertEqual(PlanFromHistorySheet.planSentence(p, accountName: "work"),
                       "Windows start on work at 06:00 and 11:15, so your limit resets at 11:00 while you work.")
    }

    /// The daemon's /v1/analytics shape: `days` distinct days of use, a
    /// 09–18 heatmap.
    private func analytics(days: Int) -> AnalyticsResponse {
        let cells = (0..<days).map {
            #"{"account_id":"","project":"p","model":"m","day":"2026-10-\#(String(format: "%02d", $0 + 1))","messages":3,"tokens":{"input":1,"output":1,"cache_creation":0,"cache_read":0}}"#
        }.joined(separator: ",")
        let grid = heat(Array(9..<18)).map { "[" + $0.map(String.init).joined(separator: ",") + "]" }.joined(separator: ",")
        let json = #"{"cells":[\#(cells)],"hour_weekday":[\#(grid)],"files_total":1,"files_parsed":1,"files_reused":0,"as_of":"2026-11-01T00:00:00Z"}"#
        return try! DaemonDates.decoder().decode(AnalyticsResponse.self, from: Data(json.utf8))
    }

    func testApplyReplacesOnlyThisAccountsTimesAndStopsRolling() async {
        let api = StubCockpitAPI()
        api.analyticsResult = .success(analytics(days: 10))
        api.deleteScheduleResult = .success(())
        api.createScheduleResult = .success(ScheduleRecord(id: "x", accountID: "a", hour: 0, minute: 0, model: nil, effort: nil))
        let model = PlanFromHistoryModel(api: api, accountID: "a")
        await model.load()
        XCTAssertNotNil(model.plan)
        let existing = [Schedule(id: "a-0700", accountID: "a", hour: 7, minute: 0), Schedule(id: "b-0700", accountID: "b", hour: 7, minute: 0)]
        await model.apply(existing: existing, windowPlan: WindowPlan(accountID: "a", rolling: true))
        XCTAssertEqual(model.status, .applied)
        XCTAssertEqual(api.setPlans.map(\.rolling), [false], "a plan is fixed times: rolling turns off")
        XCTAssertEqual(api.deletedScheduleIDs, ["a-0700"], "another account's times are left alone")
        XCTAssertEqual(api.createdSchedules.map { "\($0.hour):\($0.minute)" }, ["6:0", "11:15", "16:30"])
    }

    func testApplyStoppingPartwaySaysSo() async {
        let api = StubCockpitAPI()
        api.analyticsResult = .success(analytics(days: 10))
        api.deleteScheduleResult = .success(())
        api.createScheduleResult = .failure(ApiError(status: 500, code: nil, message: "launchd said no"))
        let model = PlanFromHistoryModel(api: api, accountID: "a")
        await model.load()
        await model.apply(existing: [], windowPlan: nil)
        guard case let .failed(message) = model.status else { return XCTFail("status = \(model.status)") }
        XCTAssertTrue(message.contains("stopped partway"), message)
    }

    func testTooLittleHistoryOffersNoPlan() async {
        let api = StubCockpitAPI()
        api.analyticsResult = .success(analytics(days: 3))
        let model = PlanFromHistoryModel(api: api, accountID: "a")
        await model.load()
        XCTAssertEqual(model.outcome, .tooLittle)
        XCTAssertNil(model.plan)
    }

    /// A pending one-tap could open a window just before the plan's first
    /// time and push its reset: applying a plan cancels it too.
    func testApplyCancelsAPendingOneTap() async {
        let api = StubCockpitAPI()
        api.analyticsResult = .success(analytics(days: 10))
        api.deleteScheduleResult = .success(())
        api.createScheduleResult = .success(ScheduleRecord(id: "x", accountID: "a", hour: 0, minute: 0, model: nil, effort: nil))
        let model = PlanFromHistoryModel(api: api, accountID: "a")
        await model.load()
        await model.apply(existing: [], windowPlan: WindowPlan(accountID: "a", nextAt: Date().addingTimeInterval(3600)))
        XCTAssertEqual(model.status, .applied)
        XCTAssertEqual(api.setPlans.count, 1)
        XCTAssertEqual(api.setPlans.first?.rolling, false)
        XCTAssertNil(api.setPlans.first?.nextAt, "the one-tap is cleared")

        // No plan set: nothing to clear.
        let api2 = StubCockpitAPI()
        api2.analyticsResult = .success(analytics(days: 10))
        api2.createScheduleResult = .success(ScheduleRecord(id: "x", accountID: "a", hour: 0, minute: 0, model: nil, effort: nil))
        let model2 = PlanFromHistoryModel(api: api2, accountID: "a")
        await model2.load()
        await model2.apply(existing: [], windowPlan: nil)
        XCTAssertTrue(api2.setPlans.isEmpty)
    }
}
