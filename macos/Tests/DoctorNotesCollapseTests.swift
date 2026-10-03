import XCTest
@testable import llmpilot

/// U4 (audit 2026-10-02): with notes only, the doctor card folds to one
/// line so the board leads. Fails against the pre-fix tree.
@MainActor
final class DoctorNotesCollapseTests: XCTestCase {
    // MARK: - U4 the doctor card leads with one line when it has notes only

    func testDoctorNotesCollapseOnlyWhenNothingIsWrong() {
        XCTAssertTrue(DoctorPanelModel.notesCollapse(clean: true, problems: 0, notChecked: 0, notes: 2))
        XCTAssertTrue(DoctorPanelModel.notesCollapse(clean: true, problems: 0, notChecked: 0, notes: 1))
        // A problem, an unchecked item, an inconsistent (not clean) verdict,
        // or no notes at all: nothing to fold.
        XCTAssertFalse(DoctorPanelModel.notesCollapse(clean: true, problems: 1, notChecked: 0, notes: 2))
        XCTAssertFalse(DoctorPanelModel.notesCollapse(clean: true, problems: 0, notChecked: 3, notes: 2))
        XCTAssertFalse(DoctorPanelModel.notesCollapse(clean: false, problems: 0, notChecked: 0, notes: 2),
                       "a 'does not add up' report never folds its findings away")
        XCTAssertFalse(DoctorPanelModel.notesCollapse(clean: true, problems: 0, notChecked: 0, notes: 0))
    }

    func testDoctorNotesCollapsibleReadsTheReport() async {
        let api = StubCockpitAPI()
        api.doctorResult = .success(try! DaemonDates.decoder().decode(DoctorReport.self, from: Data("""
        {"as_of":"2026-10-02T12:00:00Z","clean":true,"problems":0,
         "findings":[{"id":"statusline_absent","check":"statusline","severity":"info","title":"t","detail":"d",
                      "accounts":[],"remedy":{"verb":"install_statusline","label":"Install the statusline"}},
                     {"id":"fleet_empty","check":"fleet","severity":"info","title":"t","detail":"d",
                      "accounts":[],"remedy":{"verb":"register_account","label":"Add"}}],
         "checks":[{"id":"c1","title":"Check","state":"ok"}]}
        """.utf8)))
        let model = DoctorPanelModel(api: api, onAddAccount: {}, onReviewStash: {})
        _ = await model.load()
        XCTAssertEqual(model.notes, 2)
        XCTAssertTrue(model.notesCollapsible, "two notes and no problems: the card folds to its headline")
        // The statusline note's remedy is the install BUTTON, not a command to type.
        XCTAssertEqual(model.remedyAction(for: model.report!.findings[0]), .installStatusline)
    }
}
