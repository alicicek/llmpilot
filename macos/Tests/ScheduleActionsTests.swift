import XCTest
@testable import llmpilot

/// Covers ScheduleActions.swift's routing: a 402 pro_required/pro_unavailable
/// tier boundary publishes `offer` (never `flash`); everything else — a 409
/// conflict, `DaemonError.down` — publishes `flash` with the daemon's own
/// copy; a success publishes neither. Mirrors web/src/App.tsx's `report`.
@MainActor
final class ScheduleActionsTests: XCTestCase {
    private func record(id: String = "s1") -> ScheduleRecord {
        ScheduleRecord(id: id, accountID: "a1", hour: 9, minute: 0, model: nil, effort: nil)
    }

    func testProRequiredPublishesOfferWithCTA() async {
        let api = StubCockpitAPI()
        api.createScheduleResult = .failure(ApiError(
            status: 402, code: "pro_required",
            message: "Fresh windows run on your schedule — that is the autopilot's job."
        ))
        let actions = ScheduleActions(api: api)

        let result = await actions.create(accountID: "a1", hour: 9, minute: 0)

        XCTAssertNil(result)
        XCTAssertNil(actions.flash)
        XCTAssertEqual(actions.offer?.code, "pro_required")
        XCTAssertEqual(actions.offer?.message, "Fresh windows run on your schedule — that is the autopilot's job.")
        XCTAssertEqual(actions.offer?.showCTA, true)
    }

    func testProUnavailablePublishesOfferWithoutCTA() async {
        let api = StubCockpitAPI()
        api.createScheduleResult = .failure(ApiError(
            status: 402, code: "pro_unavailable",
            message: "This build was compiled without the autopilot. Watching, switching, the statusline, and history keep working here."
        ))
        let actions = ScheduleActions(api: api)

        _ = await actions.create(accountID: "a1", hour: 9, minute: 0)

        XCTAssertNil(actions.flash)
        XCTAssertEqual(actions.offer?.code, "pro_unavailable")
        XCTAssertEqual(actions.offer?.showCTA, false)
    }

    func testConflictPublishesFlashWithDaemonCopy() async {
        let api = StubCockpitAPI()
        api.createScheduleResult = .failure(ApiError(status: 409, code: nil, message: "already scheduled: sched-1"))
        let actions = ScheduleActions(api: api)

        _ = await actions.create(accountID: "a1", hour: 9, minute: 0)

        XCTAssertNil(actions.offer)
        XCTAssertEqual(actions.flash, "already scheduled: sched-1")
    }

    func testDaemonDownPublishesFlash() async {
        let api = StubCockpitAPI()
        api.updateScheduleResult = .failure(DaemonError.down)
        let actions = ScheduleActions(api: api)

        _ = await actions.move(id: "s1", hour: 10, minute: 0)

        XCTAssertNil(actions.offer)
        XCTAssertEqual(actions.flash, "daemon not running")
    }

    func testSuccessPublishesNoSurface() async {
        let api = StubCockpitAPI()
        api.createScheduleResult = .success(record())
        let actions = ScheduleActions(api: api)

        let result = await actions.create(accountID: "a1", hour: 9, minute: 0)

        XCTAssertEqual(result?.id, "s1")
        XCTAssertNil(actions.offer)
        XCTAssertNil(actions.flash)
    }

    func testDeleteRoutesProRequiredToOffer() async {
        let api = StubCockpitAPI()
        api.deleteScheduleResult = .failure(ApiError(
            status: 402, code: "pro_required", message: "Fresh windows run on your schedule — that is the autopilot's job."
        ))
        let actions = ScheduleActions(api: api)

        await actions.delete(id: "s1")

        XCTAssertEqual(actions.offer?.code, "pro_required")
        XCTAssertEqual(api.deletedScheduleIDs, ["s1"])
    }

    func testFlashLocalAndDismiss() {
        let actions = ScheduleActions(api: StubCockpitAPI())
        actions.flashLocal("fully booked")
        XCTAssertEqual(actions.flash, "fully booked")
        actions.dismissFlash()
        XCTAssertNil(actions.flash)
    }

    func testDismissOffer() async {
        let api = StubCockpitAPI()
        api.createScheduleResult = .failure(ApiError(status: 402, code: "pro_required", message: "m"))
        let actions = ScheduleActions(api: api)
        _ = await actions.create(accountID: "a1", hour: 9, minute: 0)
        XCTAssertNotNil(actions.offer)
        actions.dismissOffer()
        XCTAssertNil(actions.offer)
    }
}
