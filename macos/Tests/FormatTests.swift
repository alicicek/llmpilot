import XCTest
@testable import llmpilot

final class FormatTests: XCTestCase {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/London")!
        return c
    }

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    func testClockIs24Hour() {
        XCTAssertEqual(Format.clock(date(2026, 7, 11, 16, 5), calendar: cal), "16:05")
        XCTAssertEqual(Format.clock(date(2026, 7, 11, 0, 0), calendar: cal), "00:00")
    }

    func testResetsSameDayVsOtherDay() {
        let now = date(2026, 7, 11, 14, 0)
        XCTAssertEqual(Format.resets(date(2026, 7, 11, 16, 5), now: now, calendar: cal),
                       "resets 16:05")
        // 2026-07-12 is a Sunday.
        XCTAssertEqual(Format.resets(date(2026, 7, 12, 20, 0), now: now, calendar: cal),
                       "resets Sun 20:00")
    }

    func testAsOfIsQuietUnderAMinute() {
        let now = Date()
        XCTAssertNil(Format.asOf(now.addingTimeInterval(-30), now: now))
        XCTAssertEqual(Format.asOf(now.addingTimeInterval(-240), now: now), "as of 4 min ago")
        XCTAssertEqual(Format.asOf(now.addingTimeInterval(-7200), now: now), "as of 2 h ago")
    }

    func testAlias() {
        XCTAssertEqual(Format.alias(index: 1, of: 4), "acct 2/4")
    }
}
