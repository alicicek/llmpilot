import AppKit
import SwiftUI
import XCTest

@testable import llmpilot

/// Mounts the REAL Add account sheet (RhythmCardHostingTests' pattern) in
/// its idle state and checks what it drew. In-process AX can't see SwiftUI
/// descendants here (AXTestSupport), so the check reads the pixels: the
/// title and intro above, the blue sign-in button with its label, and
/// NOTHING below it — a blank sheet, a missing button or a section added
/// back under the sign-in all fail. The removed folder list was filled by
/// an async folder scan, so the test also offers folders and checks the
/// sheet never asks for them. With `LLMPILOT_SHOT_DIR` set the render is
/// also written to disk.
@MainActor
final class AddAccountSheetHostingTests: XCTestCase {
    func testIdleSheetRendersJustTheSignIn() async throws {
        let api = StubCockpitAPI()
        api.detectResult = .success([
            DetectedDir(configDir: "/Users/x/.claude-work", email: "work@example.dev", registered: false),
        ])
        let model = AddAccountModel(api: api)
        let view = AddAccountSheet(model: model)
            .padding(20)
            // Fill the window so every pixel outside the content is the
            // known background.
            .frame(width: 440, height: 260, alignment: .topLeading)
            .background(Color(nsColor: NSColor(srgbRed: 0.137, green: 0.137, blue: 0.153, alpha: 1)))
            .preferredColorScheme(.dark)
        let window = AXTestSupport.host(view, size: NSSize(width: 440, height: 260))
        defer { window.orderOut(nil) }
        // Let any load the sheet starts on appear land before the capture.
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(api.detectCalls, 0, "Add account scans for folders again")
        guard let content = window.contentView else { return XCTFail("no content view") }
        content.layoutSubtreeIfNeeded()
        guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return XCTFail("no bitmap") }
        content.cacheDisplay(in: content.bounds, to: rep)
        if let dir = ProcessInfo.processInfo.environment["LLMPILOT_SHOT_DIR"],
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("add-account-idle.png"))
        }

        let px = try XCTUnwrap(Pixels(rep))
        let bg = px.rgb(1, 1)

        // The sign-in button: the only strongly blue thing on the sheet.
        let blue = px.box { r, g, b in b > 150 && b - r > 120 && g < 160 }
        let button = try XCTUnwrap(blue, "no sign-in button drawn")
        let scale = px.width / 440
        XCTAssertGreaterThan(button.maxX - button.minX, 80 * scale, "the button is too narrow to hold its label")
        XCTAssertGreaterThan(button.maxY - button.minY, 18 * scale)
        // Its label: white text inside the blue.
        let label = px.count(in: button) { r, g, b in r > 200 && g > 200 && b > 200 }
        XCTAssertGreaterThan(label, 40 * scale * scale, "the sign-in button has no label")

        // Above it: the title, then the intro (one or more lines).
        let bands = px.inkBands(rows: 0..<button.minY, differingFrom: bg)
        XCTAssertGreaterThanOrEqual(bands, 2, "the title and the intro should sit above the button")
        XCTAssertLessThanOrEqual(bands, 4, "more text above the button than the title and the intro")

        // Below it: nothing at all.
        let below = px.inkBands(rows: min(button.maxY + 2, px.height)..<px.height, differingFrom: bg)
        XCTAssertEqual(below, 0, "something is drawn under the sign-in button")
    }
}

/// The render as sRGB bytes, row 0 at the top.
private struct Pixels {
    let width: Int
    let height: Int
    private let bytes: [UInt8]

    init?(_ rep: NSBitmapImageRep) {
        guard let image = rep.cgImage, let srgb = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        width = image.width
        height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: srgb,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard drawn else { return nil }
        bytes = buffer
    }

    func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
        let i = (y * width + x) * 4
        return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
    }

    /// The bounding box of every pixel `match` accepts, or nil.
    func box(_ match: (Int, Int, Int) -> Bool) -> (minX: Int, maxX: Int, minY: Int, maxY: Int)? {
        var found: (minX: Int, maxX: Int, minY: Int, maxY: Int)?
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = rgb(x, y)
                guard match(r, g, b) else { continue }
                if let f = found {
                    found = (min(f.minX, x), max(f.maxX, x), min(f.minY, y), max(f.maxY, y))
                } else {
                    found = (x, x, y, y)
                }
            }
        }
        return found
    }

    func count(in box: (minX: Int, maxX: Int, minY: Int, maxY: Int), _ match: (Int, Int, Int) -> Bool) -> Int {
        var n = 0
        for y in box.minY...box.maxY {
            for x in box.minX...box.maxX {
                let (r, g, b) = rgb(x, y)
                if match(r, g, b) { n += 1 }
            }
        }
        return n
    }

    /// Runs of consecutive rows holding a pixel clearly unlike `bg` — one
    /// per line of text or control.
    func inkBands(rows: Range<Int>, differingFrom bg: (Int, Int, Int)) -> Int {
        var bands = 0
        var inBand = false
        for y in rows {
            var ink = false
            for x in 0..<width {
                let (r, g, b) = rgb(x, y)
                if abs(r - bg.0) + abs(g - bg.1) + abs(b - bg.2) > 60 {
                    ink = true
                    break
                }
            }
            if ink, !inBand { bands += 1 }
            inBand = ink
        }
        return bands
    }
}
