import XCTest

@testable import llmpilot

/// The account row's pace line, rolling switch and one-tap: what the daemon
/// sends decodes, and each state reads the way the row says it.
@MainActor
final class WindowPlanTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private func at(_ h: Int, _ m: Int) -> Date {
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour, c.minute) = (2026, 11, 1, h, m)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        return cal.date(from: c)!
    }

    func testPaceLine() {
        let before = BucketForecast(kind: "five_hour", perHour: 60, wallAt: at(17, 40), beforeReset: true)
        XCTAssertEqual(
            PaceLine.line(before, resetsAt: at(18, 30), now: at(15, 0), timeZone: utc),
            .init(text: "At this pace you hit 100% around 17:40, 50 min before it resets.", warn: true))
        let after = BucketForecast(kind: "five_hour", perHour: 10, wallAt: at(19, 0), beforeReset: false)
        XCTAssertEqual(PaceLine.line(after, resetsAt: at(18, 30), now: at(15, 0), timeZone: utc),
                       .init(text: "At this pace it resets before you hit 100%.", warn: false))
        let slow = BucketForecast(kind: "five_hour", perHour: 0.2, wallAt: nil, beforeReset: false)
        XCTAssertEqual(PaceLine.line(slow, resetsAt: at(18, 30), timeZone: utc)?.warn, false)
        XCTAssertNil(PaceLine.line(nil, resetsAt: at(18, 30)), "no forecast yet: no line")
        XCTAssertNil(PaceLine.line(before, resetsAt: at(18, 30), now: at(17, 45), timeZone: utc),
                     "a wall already behind us is stale: no line until the next poll")
        XCTAssertEqual(PaceLine.roughDuration(80 * 60), "1 h 20 min")
        XCTAssertEqual(PaceLine.roughDuration(2 * 3600), "2 h")
    }

    func testOneTapOffersTheResetUntilSetAndNeverWhileRolling() {
        let now = at(15, 18)
        XCTAssertEqual(PlanRow.oneTap(plan: nil, sessionReset: at(18, 30), now: now), .offer(at: at(18, 30)))
        XCTAssertEqual(PlanRow.oneTap(plan: WindowPlan(accountID: "a", nextAt: at(18, 30)), sessionReset: at(18, 30), now: now),
                       .set(at: at(18, 30)))
        XCTAssertNil(PlanRow.oneTap(plan: WindowPlan(accountID: "a", rolling: true), sessionReset: at(18, 30), now: now),
                     "rolling already starts every reset")
        XCTAssertNil(PlanRow.oneTap(plan: nil, sessionReset: nil, now: now), "no open window: nothing to start at a reset")
        XCTAssertNil(PlanRow.oneTap(plan: nil, sessionReset: at(14, 0), now: now), "a reset already past")
        XCTAssertEqual(PlanRow.oneTap(plan: WindowPlan(accountID: "a", nextAt: at(12, 0)), sessionReset: nil, now: now),
                       .set(at: at(12, 0)), "a set one-tap stays cancellable however long it waits")
    }

    func testRollingCaption() {
        XCTAssertEqual(PlanRow.rollingCaption(sessionReset: at(18, 30), now: at(15, 0), pausedDailyTimes: true, timeZone: utc),
                       "Next window starts 18:30 · daily times paused")
        XCTAssertEqual(PlanRow.rollingCaption(sessionReset: nil, now: at(15, 0), pausedDailyTimes: false, timeZone: utc),
                       "Starting a window now")
        XCTAssertEqual(PlanRow.rollingCaption(sessionReset: nil, now: at(15, 0), pausedDailyTimes: false, signedIn: false, timeZone: utc),
                       "Starts a window once Claude Code is signed in to this account")
        XCTAssertEqual(PlanRow.rollingCaption(sessionReset: at(18, 30), now: at(15, 0), pausedDailyTimes: false, signedIn: false, timeZone: utc),
                       "Next window starts 18:30 if Claude Code is signed in to this account then")
    }

    func testRollingChainRunsBackToBackToMidnight() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        XCTAssertEqual(RollingChain.starts(reset: at(18, 30), now: at(15, 0), calendar: cal), [18 * 60 + 30, 23 * 60 + 30])
        XCTAssertEqual(RollingChain.starts(reset: nil, now: at(10, 0), calendar: cal), [600, 900, 1200])
        XCTAssertEqual(RollingChain.starts(reset: at(14, 0), now: at(15, 0), calendar: cal), [900, 1200],
                       "a reset already past: the daemon is starting one now")
        XCTAssertEqual(RollingChain.starts(reset: at(23, 0).addingTimeInterval(7200), now: at(23, 0), calendar: cal), [],
                       "a reset after midnight: the open window covers the rest of today")
    }

    func testStateDecodesForecastsAndWindowPlans() throws {
        let json = """
        {"accounts":[{"id":"a","label":"a","email":"a@example.dev","pinned":false,
          "forecasts":[{"kind":"five_hour","per_hour":60,"wall_at":"2026-11-01T17:40:00Z","before_reset":true}]}],
         "schedules":[],"window_plans":[{"account_id":"a","rolling":true},{"account_id":"b","next_at":"2026-11-01T18:30:00Z"}],
         "as_of":"2026-11-01T15:18:00Z"}
        """
        let s = try DaemonDates.decoder().decode(DaemonState.self, from: Data(json.utf8))
        let f = try XCTUnwrap(s.accounts.first?.sessionForecast)
        XCTAssertEqual(f.perHour, 60)
        XCTAssertTrue(f.beforeReset)
        XCTAssertEqual(f.wallAt, at(17, 40))
        XCTAssertEqual(s.windowPlans, [WindowPlan(accountID: "a", rolling: true), WindowPlan(accountID: "b", nextAt: at(18, 30))])

        // An older daemon sends neither: still decodes.
        let old = #"{"accounts":[{"id":"a","label":"a","email":"","pinned":false}],"schedules":[],"as_of":"2026-11-01T15:18:00Z"}"#
        let s2 = try DaemonDates.decoder().decode(DaemonState.self, from: Data(old.utf8))
        XCTAssertNil(s2.accounts.first?.sessionForecast)
        XCTAssertEqual(s2.windowPlans, [])
    }

    func testBoardActionsSetThePlanAndRouteAProRefusal() async {
        let api = StubCockpitAPI()
        let actions = ScheduleActions(api: api)
        await actions.setPlan(accountID: "a", rolling: true, nextAt: nil)
        await actions.setPlan(accountID: "a", rolling: false, nextAt: at(18, 30))
        XCTAssertEqual(api.setPlans.count, 2)
        XCTAssertEqual(api.setPlans[0].rolling, true)
        XCTAssertEqual(api.setPlans[1].nextAt, at(18, 30))
        XCTAssertNil(actions.flash)

        api.windowPlanError = ApiError(status: 402, code: "pro_required", message: "Rolling windows need the autopilot.")
        await actions.setPlan(accountID: "a", rolling: true, nextAt: nil)
        XCTAssertEqual(actions.offer?.code, "pro_required", "a Pro refusal is an offer, never a warn flash")
    }

    /// Verified accounts on some plans (Ultra) have no 5-hour limit: their
    /// usage lists none, where an account with one lists it even idle.
    func testNoFiveHourLimitIsReadFromTheAccountsOwnUsage() throws {
        func acct(_ kinds: [String]) throws -> AccountState {
            let buckets = kinds.map { #"{"kind":"\#($0)","percent":10}"# }.joined(separator: ",")
            let json = #"{"id":"a","label":"a","email":"a@example.dev","pinned":false,"snapshot":{"as_of":"2026-11-01T00:00:00Z","buckets":[\#(buckets)]}}"#
            return try DaemonDates.decoder().decode(AccountState.self, from: Data(json.utf8))
        }
        XCTAssertTrue(try acct(["weekly_all", "weekly_scoped"]).noFiveHourLimit)
        XCTAssertFalse(try acct(["session", "weekly_all"]).noFiveHourLimit, "an idle 5-hour limit is still a limit")
        XCTAssertFalse(try acct(["five_hour", "seven_day"]).noFiveHourLimit)
        XCTAssertFalse(try acct([]).noFiveHourLimit, "no usage yet is unknown, not 'no limit'")
    }

    func testWeeklyPaceLine() {
        let weekly = BucketForecast(kind: "weekly_all", perHour: 0.75, wallAt: at(14, 0).addingTimeInterval(2 * 86400), beforeReset: true)
        let reset = at(19, 0).addingTimeInterval(3 * 86400)
        XCTAssertEqual(PaceLine.line(weekly, resetsAt: reset, now: at(10, 0), timeZone: utc),
                       .init(text: "At this week's pace you hit 100% around Tue 14:00, 1 day 5 h before it resets.", warn: true))
        let calm = BucketForecast(kind: "weekly_all", perHour: 0.2, wallAt: reset.addingTimeInterval(86400), beforeReset: false)
        XCTAssertEqual(PaceLine.line(calm, resetsAt: reset, now: at(10, 0), timeZone: utc)?.text,
                       "At this week's pace it resets before you hit 100%.")
        XCTAssertEqual(PaceLine.roughDuration(48 * 3600), "2 days")
    }

    /// A lane that rolls, or has no 5-hour limit, books nothing — VoiceOver's
    /// book action says why. Every other lane books (without Pro the
    /// daemon's answer is the Pro offer).
    func testNoBookingReason() {
        XCTAssertNil(BoardView.noBookingReason(label: "work", rolling: false, noFive: false))
        XCTAssertEqual(
            BoardView.noBookingReason(label: "work", rolling: false, noFive: true),
            "work has no 5-hour limit, so there's no window to start — only the weekly limit applies.")
        XCTAssertEqual(
            BoardView.noBookingReason(label: "work", rolling: true, noFive: false),
            "work keeps its windows rolling — switch that off to set daily times.")
        // No limit wins: rolling has nothing to roll there either.
        XCTAssertEqual(
            BoardView.noBookingReason(label: "work", rolling: true, noFive: true),
            BoardView.noBookingReason(label: "work", rolling: false, noFive: true))
    }

    /// The hidden daily times are counted in the note beside "Remove them".
    func testNoFiveNoteCountsTheHiddenTimes() {
        XCTAssertEqual(BoardView.noFiveNote(dailyTimes: 0), "No 5-hour limit on this account — nothing to schedule")
        XCTAssertEqual(BoardView.noFiveNote(dailyTimes: 1), "No 5-hour limit on this account — its daily time is skipped")
        XCTAssertEqual(BoardView.noFiveNote(dailyTimes: 10), "No 5-hour limit on this account — its 10 daily times are skipped")
    }
}
