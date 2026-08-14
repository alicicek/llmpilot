import XCTest
@testable import llmpilot

/// Pure-geometry pins for BoardPieces.swift's one hand-rolled `Shape`
/// (`BoardRoundedCorners` — SwiftUI's `UnevenRoundedRectangle` needs macOS
/// 15, this project's floor is macOS 13). No UI hosting: `Shape.path(in:)`
/// is a pure function of a `CGRect` and returns a `Path`, whose
/// `boundingRect` this file checks directly — cheap, deterministic, and
/// exercises the exact geometry `BoardChargeBlock`'s squared-corner
/// (chained-block) rendering depends on.
final class BoardPiecesTests: XCTestCase {
    private let rect = CGRect(x: 0, y: 0, width: 100, height: 30)

    func test_allCornersRounded_boundingRectMatchesInputRect() {
        let shape = BoardRoundedCorners(topLeft: 7, topRight: 7, bottomRight: 7, bottomLeft: 7)
        let bounds = shape.path(in: rect).boundingRect
        assertRectsEqual(bounds, rect, accuracy: 0.01)
    }

    func test_zeroRadius_isAPlainRectangle() {
        let shape = BoardRoundedCorners(topLeft: 0, topRight: 0, bottomRight: 0, bottomLeft: 0)
        let bounds = shape.path(in: rect).boundingRect
        assertRectsEqual(bounds, rect, accuracy: 0.01)
    }

    /// `ChargeBlock.tsx`'s `squareLeft`/`squareRight` — a chained pair's
    /// touching edge zeroes only ITS OWN two corners on that side; the
    /// other side keeps its 7pt radius. The bounding rect is unaffected
    /// either way (rounding never grows past the rect), but the corner
    /// mix must not crash or degenerate for any left/right combination.
    func test_squaredLeftOrRight_stillProducesAClosedPath() {
        for (tl, tr, br, bl) in [(0.0, 7.0, 7.0, 0.0), (7.0, 0.0, 0.0, 7.0)] {
            let shape = BoardRoundedCorners(topLeft: tl, topRight: tr, bottomRight: br, bottomLeft: bl)
            let path = shape.path(in: rect)
            XCTAssertFalse(path.isEmpty)
            assertRectsEqual(path.boundingRect, rect, accuracy: 0.01)
        }
    }

    func test_inset_shrinksBoundingRectSymmetrically() {
        let shape = BoardRoundedCorners(topLeft: 7, topRight: 7, bottomRight: 7, bottomLeft: 7)
        let inset = shape.inset(by: 2.5)
        let bounds = inset.path(in: rect).boundingRect
        assertRectsEqual(bounds, rect.insetBy(dx: 2.5, dy: 2.5), accuracy: 0.01)
    }

    func test_inset_neverProducesNegativeCornerRadius() {
        // A radius smaller than the inset amount must clamp to 0, not go
        // negative (which would otherwise corrupt the arc math).
        var shape = BoardRoundedCorners(topLeft: 1, topRight: 1, bottomRight: 1, bottomLeft: 1)
        shape.insetAmount = 5
        let bounds = shape.path(in: rect).boundingRect
        assertRectsEqual(bounds, rect.insetBy(dx: 5, dy: 5), accuracy: 0.01)
    }
}

private extension XCTestCase {
    // NOT named XCTAssertEqual: a same-named overload shadows the global
    // CGFloat XCTAssertEqual inside its own body and breaks resolution.
    func assertRectsEqual(_ a: CGRect, _ b: CGRect, accuracy: CGFloat, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.minX, b.minX, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.minY, b.minY, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.width, b.width, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.height, b.height, accuracy: accuracy, file: file, line: line)
    }
}
