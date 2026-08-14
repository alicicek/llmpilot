import AppKit
import SwiftUI
import XCTest

@testable import llmpilot

/// Chunk 5A — mounts the REAL `TourOverlayView` over a fake `.tourAnchor(_:)`
/// target (DoctorPanelHostingTests' precedent: a real, offscreen window,
/// forced layout, an observable effect asserted rather than an AX-tree walk
/// — AXTestSupport's own header documents why in-process AX identifier
/// queries don't surface in this XCTest host). The observable effect here is
/// the PreferenceKey pipeline itself: does a `.tourAnchor("runway")`-tagged
/// view, laid out under the SAME ancestor `TourOverlayView` mounts from,
/// actually reach `TourModel.availableTargets` and resolve `current`?
@MainActor
final class TourOverlayHostingTests: XCTestCase {
    /// One fake tour target plus the overlay, wired exactly as
    /// NativeCockpitWindow.swift's `content(_:)` wires the real board: a
    /// common ancestor reads `TourAnchorPreferenceKey` via
    /// `.overlayPreferenceValue` and hands the resolved dictionary to a
    /// `GeometryReader`-wrapped `TourOverlayView`.
    private struct Host: View {
        @ObservedObject var model: TourModel
        let onDone: () -> Void
        /// Empty hides the fake anchor entirely — the zero-target case.
        var showAnchor = true

        var body: some View {
            Group {
                if showAnchor {
                    Rectangle().fill(Color.clear).frame(width: 40, height: 20).tourAnchor("runway")
                } else {
                    Color.clear
                }
            }
            .frame(width: 700, height: 500)
            .overlayPreferenceValue(TourAnchorPreferenceKey.self) { anchors in
                GeometryReader { geo in
                    TourOverlayView(model: model, anchors: anchors, geometry: geo, onDone: onDone)
                }
            }
        }
    }

    func testFakeAnchorReachesTheModelAndResolvesTheCurrentStep() async throws {
        let model = TourModel()
        var doneCalls = 0
        let window = AXTestSupport.host(
            Host(model: model, onDone: { doneCalls += 1 }), size: NSSize(width: 700, height: 500))
        defer { window.orderOut(nil) }

        for _ in 0..<50 {
            if model.availableTargets.contains("runway") { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(
            model.availableTargets.contains("runway"),
            "the fake .tourAnchor(\"runway\") view never reached TourModel.availableTargets — the PreferenceKey pipeline is broken")
        XCTAssertEqual(model.current?.target, "runway")
        XCTAssertEqual(model.current?.title, "This is your real usage")
        XCTAssertEqual(doneCalls, 0, "a live target must not end the guide")
    }

    func testNoAnchorsOnScreenEndsTheGuideRatherThanShowingItEmpty() async throws {
        let model = TourModel()
        var doneCalls = 0
        let window = AXTestSupport.host(
            Host(model: model, onDone: { doneCalls += 1 }, showAnchor: false),
            size: NSSize(width: 700, height: 500))
        defer { window.orderOut(nil) }

        for _ in 0..<50 {
            if doneCalls > 0 { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertGreaterThan(
            doneCalls, 0,
            "with no tour targets on screen the overlay must call onDone rather than sit there empty")
    }

    /// Two views tag the same id ("switch" rides EVERY switchable lane,
    /// like LaneHeader.tsx:73) — the resolved rect must be the FIRST in
    /// layout order (topmost), matching `document.querySelector` (delta
    /// re-review P2-1 pinned).
    private final class RectBox { var resolved: CGRect? }

    private struct DuplicateAnchorProbe: View {
        let box: RectBox

        var body: some View {
            VStack(spacing: 0) {
                Rectangle().fill(Color.clear).frame(width: 40, height: 20).tourAnchor("switch")
                Rectangle().fill(Color.clear).frame(width: 40, height: 20).tourAnchor("switch")
            }
            .frame(width: 300, height: 300, alignment: .top)
            .overlayPreferenceValue(TourAnchorPreferenceKey.self) { anchors in
                GeometryReader { geo -> Color in
                    if let anchor = anchors["switch"] {
                        let rect = geo[anchor]
                        DispatchQueue.main.async { box.resolved = rect }
                    }
                    return Color.clear
                }
            }
        }
    }

    func testDuplicateAnchorIdsResolveToTheFirstInLayoutOrder() async throws {
        let box = RectBox()
        let window = AXTestSupport.host(
            DuplicateAnchorProbe(box: box), size: NSSize(width: 300, height: 300))
        defer { window.orderOut(nil) }

        for _ in 0..<50 {
            if box.resolved != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let rect = try XCTUnwrap(box.resolved, "the duplicate-id anchor never resolved")
        // The two rects sit at y=0 and y=20 inside the probe; first-in-
        // layout-order is the top one.
        XCTAssertEqual(rect.minY, 0, accuracy: 1.0,
                        "duplicate .tourAnchor ids must resolve to the FIRST (topmost) writer, like querySelector")
    }
}
