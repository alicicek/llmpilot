import AppKit
import SwiftUI
import XCTest

@testable import llmpilot

/// Pins the P1 lifecycle risk from the Phase-1 review: DoctorPanelView's
/// `.task(id:)` is the ONLY thing that ever calls the doctor sweep, and on
/// first appearance the panel renders no visible content (report and
/// sweepErr both nil). If the task doesn't fire on a content-free subtree,
/// the panel is permanently invisible — so this mounts the real view in a
/// real (offscreen) window and asserts the stub actually got the call.
@MainActor
final class DoctorPanelHostingTests: XCTestCase {
    func testTaskFiresOnFirstAppearanceWithNoContent() async throws {
        let api = StubCockpitAPI()
        // Leave doctorResult failing: the assert is that load() RAN (the
        // sweep was requested), not that it succeeded.
        let model = DoctorPanelModel(api: api, onAddAccount: {}, onReviewStash: {})
        let view = DoctorPanelView(model: model, reloadKey: "k1")

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: view)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        // .task fires asynchronously after the hosting view appears — poll
        // briefly rather than sleeping a fixed eternity.
        for _ in 0..<50 {
            if api.doctorCalls > 0 { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertGreaterThan(
            api.doctorCalls, 0,
            "DoctorPanelView's .task never fired on first appearance — the doctor panel would never load")
    }
}
