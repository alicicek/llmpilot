import AppKit
import SwiftUI
import XCTest

@testable import llmpilot

/// Mounts the REAL Rhythm card (DoctorPanelHostingTests' pattern) for the
/// two data shapes the audit judged — an idle week and a busy one — so a
/// layout regression that only shows at render time (labels collapsing,
/// a cell row not laying out) fails here. With `LLMPILOT_SHOT_DIR` set the
/// render is also written to disk, which is how the fix-1.3.6 receipt's
/// heatmap shot was produced without driving the whole cockpit.
@MainActor
final class RhythmCardHostingTests: XCTestCase {
    private func host(_ data: [[Int64]], name: String) {
        let view = RhythmCard(hourWeekday: data, dark: true)
            .padding(16)
            .frame(width: 460)
            .background(Color(nsColor: NSColor(srgbRed: 0.137, green: 0.137, blue: 0.153, alpha: 1)))
            .preferredColorScheme(.dark)
        let size = NSSize(width: 460, height: 220)
        let window = AXTestSupport.host(view, size: size)
        defer { window.orderOut(nil) }
        guard let content = window.contentView else { return XCTFail("no content view") }
        content.layoutSubtreeIfNeeded()
        guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return XCTFail("no bitmap") }
        content.cacheDisplay(in: content.bounds, to: rep)
        XCTAssertGreaterThan(rep.pixelsWide, 0)
        if let dir = ProcessInfo.processInfo.environment["LLMPILOT_SHOT_DIR"],
           let png = rep.representation(using: .png, properties: [:]) {
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
            try? png.write(to: url)
        }
    }

    func testIdleWeekRenders() {
        host(Array(repeating: Array(repeating: 0, count: 24), count: 7), name: "rhythm-empty")
    }

    func testBusyWeekRenders() {
        var data = Array(repeating: Array(repeating: Int64(0), count: 24), count: 7)
        for d in 0..<7 { for h in 9..<18 { data[d][h] = Int64((h - 8) * 1000 * (d % 3 + 1)) } }
        host(data, name: "rhythm-busy")
    }
}
