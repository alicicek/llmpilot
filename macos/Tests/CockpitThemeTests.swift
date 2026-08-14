import AppKit
import SwiftUI
import XCTest
@testable import llmpilot

/// Confirms CockpitTheme's tokens resolve to the exact light/dark values
/// carried over from web/src/theme.css (including the AA-contrast-tuned
/// steps called out in that file's comments). If theme.css changes, these
/// numbers must change with it.
final class CockpitThemeTests: XCTestCase {
    private struct RGBA {
        let r: CGFloat
        let g: CGFloat
        let b: CGFloat
        let a: CGFloat
    }

    /// Resolves a SwiftUI `Color` token to its sRGB components under a
    /// forced appearance. `CockpitTheme` tokens are built from
    /// `NSColor(name:dynamicProvider:)` wrapped in `Color(nsColor:)`;
    /// converting back via `NSColor(_ color: Color)` inside
    /// `performAsCurrentDrawingAppearance` re-invokes that provider under
    /// the forced appearance, which is the reliable way to observe a
    /// dynamic color's per-appearance value from a unit test.
    private func resolve(_ color: Color, appearance name: NSAppearance.Name) -> RGBA {
        let appearance = NSAppearance(named: name)!
        var result = RGBA(r: 0, g: 0, b: 0, a: 0)
        appearance.performAsCurrentDrawingAppearance {
            let ns = NSColor(color)
            let sRGB = ns.usingColorSpace(.sRGB) ?? ns
            result = RGBA(r: sRGB.redComponent, g: sRGB.greenComponent, b: sRGB.blueComponent, a: sRGB.alphaComponent)
        }
        return result
    }

    /// 0-255 channel value as an sRGB component fraction.
    private func comp(_ value: Int) -> CGFloat {
        CGFloat(value) / 255
    }

    private func assertRGBA(
        _ color: Color,
        appearance: NSAppearance.Name,
        r: Int,
        g: Int,
        b: Int,
        a: CGFloat = 1,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let resolved = resolve(color, appearance: appearance)
        XCTAssertEqual(resolved.r, comp(r), accuracy: 1.0 / 255, "red", file: file, line: line)
        XCTAssertEqual(resolved.g, comp(g), accuracy: 1.0 / 255, "green", file: file, line: line)
        XCTAssertEqual(resolved.b, comp(b), accuracy: 1.0 / 255, "blue", file: file, line: line)
        XCTAssertEqual(resolved.a, a, accuracy: 1.0 / 255, "alpha", file: file, line: line)
    }

    func testTextLightAndDark() {
        // #1d1d1f
        assertRGBA(CockpitTheme.text, appearance: .aqua, r: 0x1d, g: 0x1d, b: 0x1f)
        // #f2f2f4
        assertRGBA(CockpitTheme.text, appearance: .darkAqua, r: 0xf2, g: 0xf2, b: 0xf4)
    }

    func testTerLightAndDark() {
        // #6a6a6f
        assertRGBA(CockpitTheme.ter, appearance: .aqua, r: 0x6a, g: 0x6a, b: 0x6f)
        // #8a8a91
        assertRGBA(CockpitTheme.ter, appearance: .darkAqua, r: 0x8a, g: 0x8a, b: 0x91)
    }

    func testOkTxLight() {
        // #137731 — nearest AA-passing step for the ACTIVE badge (4.86:1).
        assertRGBA(CockpitTheme.okTx, appearance: .aqua, r: 0x13, g: 0x77, b: 0x31)
    }

    func testWarnLightAndDark() {
        // #9d5700 — nearest AA-passing amber text (5.2:1) over #c86f00.
        assertRGBA(CockpitTheme.warn, appearance: .aqua, r: 0x9d, g: 0x57, b: 0x00)
        // #ffab3d
        assertRGBA(CockpitTheme.warn, appearance: .darkAqua, r: 0xff, g: 0xab, b: 0x3d)
    }

    func testCritDeepIsIdenticalInBothAppearances() {
        // #d0342b — white-text-safe red (4.99:1); same hex in light and dark.
        assertRGBA(CockpitTheme.critDeep, appearance: .aqua, r: 0xd0, g: 0x34, b: 0x2b)
        assertRGBA(CockpitTheme.critDeep, appearance: .darkAqua, r: 0xd0, g: 0x34, b: 0x2b)
    }

    func testAccentLightAndDark() {
        // #0a7aff
        assertRGBA(CockpitTheme.accent, appearance: .aqua, r: 0x0a, g: 0x7a, b: 0xff)
        // #0a84ff
        assertRGBA(CockpitTheme.accent, appearance: .darkAqua, r: 0x0a, g: 0x84, b: 0xff)
    }

    func testHairAlphaLight() {
        // rgba(0, 0, 0, 0.11)
        let resolved = resolve(CockpitTheme.hair, appearance: .aqua)
        XCTAssertEqual(resolved.a, 0.11, accuracy: 0.001)
    }
}
