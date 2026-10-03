import XCTest
@testable import llmpilot

/// The Rhythm heatmap's cell and axis rules (HistoryCardsMore.swift). A
/// zero cell paints EMPTY — never the ramp's weakest step, which on the
/// dark ramp is a saturated blue that made an idle week look like seven
/// days of peak use — and the hour axis labels only the 00/06/12/18
/// columns, one label per column.
final class RhythmCardTests: XCTestCase {
    func testZeroCellIsEmptyOnBothRamps() {
        XCTAssertEqual(RhythmCard.cell(value: 0, maxValue: 0, dark: true), .empty)
        XCTAssertEqual(RhythmCard.cell(value: 0, maxValue: 0, dark: false), .empty)
        // An idle hour inside an otherwise busy week is still empty.
        XCTAssertEqual(RhythmCard.cell(value: 0, maxValue: 9_000, dark: true), .empty)
    }

    func testPositiveCellTakesTheRamp() {
        let peak = RhythmCard.cell(value: 500, maxValue: 500, dark: true)
        let low = RhythmCard.cell(value: 1, maxValue: 500, dark: true)
        XCTAssertEqual(peak, .filled(hex: HistoryColors.sequentialColor(1, dark: true)))
        XCTAssertEqual(low, .filled(hex: HistoryColors.sequentialColor(1.0 / 500.0, dark: true)))
        XCTAssertNotEqual(peak, low)
    }

    func testHourAxisLabelsOnlyTheFourTicks() {
        let labelled = (0..<24).compactMap { h in RhythmCard.hourLabel(h).map { (h, $0) } }
        XCTAssertEqual(labelled.map(\.0), [0, 6, 12, 18])
        XCTAssertEqual(labelled.map(\.1), ["00", "06", "12", "18"])
    }
}
