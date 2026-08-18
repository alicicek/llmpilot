import AppKit
import XCTest

@testable import llmpilot

/// Phase 6 cutover pins (review 2026-08-08 P1-2/P2-11): the native cockpit
/// is now THE cockpit, and its Settings sheet hosts the license-recovery
/// paste targets. Sheets are their own (SwiftUI-owned) windows, so their ⌘V
/// rides the app's main Edit menu — and the MenuBarExtra scene CAN replace
/// NSApp.mainMenu after the delegate installs it (measured: the plain
/// menu-content pin failed mid-suite while passing in isolation). The
/// recovery is `AppMainMenu.install()` re-asserted on cockpit open; these
/// tests pin that path in the hosted app process.
///
/// Hygiene (delta re-review P2): a LOCAL controller with a stub API — never
/// the production singleton with a live HTTP client — and the real-domain
/// frame-autosave key is snapshotted/restored exactly like the e2e scripts
/// do, because setFrameAutosaveName writes through cfprefsd to the real
/// dev.llmpilot.menubar domain even from a test host.
@MainActor
final class MainMenuTests: XCTestCase {
    private static let frameKey = "NSWindow Frame llmpilot-cockpit"
    private var preFrame: String?

    override func setUp() {
        super.setUp()
        preFrame = UserDefaults.standard.string(forKey: Self.frameKey)
    }

    override func tearDown() {
        if let preFrame {
            UserDefaults.standard.set(preFrame, forKey: Self.frameKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.frameKey)
        }
        super.tearDown()
    }

    private func openLocalController() -> NativeCockpitWindowController {
        let controller = NativeCockpitWindowController()
        controller.open(fleet: FleetViewModel(api: StubAPI(), autostart: false), api: StubCockpitAPI())
        return controller
    }

    func testCockpitOpenReassertsTheEditPasteMenuSheetsDependOn() throws {
        let controller = openLocalController()
        defer { controller.window?.orderOut(nil) }

        XCTAssertTrue(AppMainMenu.installed, "open() must re-assert the Edit menu")
        let main = try XCTUnwrap(NSApp.mainMenu)
        let edit = try XCTUnwrap(main.items.compactMap(\.submenu).first { $0.title == "Edit" })
        let paste = edit.items.first { $0.keyEquivalent == "v" && $0.keyEquivalentModifierMask == [.command] }
        XCTAssertNotNil(paste, "⌘V missing from the Edit menu — license recovery-code paste would be dead in sheets")
        XCTAssertEqual(paste?.action, #selector(NSText.paste(_:)))
    }

    func testCockpitWindowIsEditableAndCarriesTheCutoverIdentity() {
        let controller = openLocalController()
        defer { controller.window?.orderOut(nil) }

        XCTAssertTrue(
            controller.window is EditableWindow,
            "the cockpit hosts paste targets — it must answer editing key equivalents itself (the deleted web-cockpit window's own rule)")
        XCTAssertEqual(controller.window?.title, "llmpilot")
        XCTAssertEqual(controller.window?.frameAutosaveName, "llmpilot-cockpit")
    }

    // MARK: - F16: corridor fixed-size, cockpit stays resizable
    // Decided in the 2026-08-16 audit: the cockpit stays resizable
    // (min 1000×700, default 1180×820), the corridor is locked.

    func testWindowModePureSizesMatchTheF16Decision() {
        XCTAssertEqual(WindowMode.cockpit.minSize, NSSize(width: 1000, height: 700))
        XCTAssertEqual(
            WindowMode.corridor.minSize, WindowMode.corridorContentSize,
            "the corridor has no range — its floor IS its designed size, or the SwiftUI root stretches the window past it")

        let bigVisible = NSRect(x: 0, y: 0, width: 4000, height: 3000)
        XCTAssertEqual(WindowMode.cockpit.targetContentSize(in: bigVisible), NSSize(width: 1180, height: 820))
        XCTAssertEqual(WindowMode.corridor.targetContentSize(in: bigVisible), NSSize(width: 616, height: 540),
            "the corridor window is DERIVED from its one column (560) plus two 28pt margins — owner 2026-08-18")

        // Corridor's target never grows with the screen — the whole point
        // of a fixed size — where the cockpit's does (0.9× visible, clamped).
        let smallVisible = NSRect(x: 0, y: 0, width: 1000, height: 800)
        XCTAssertEqual(WindowMode.corridor.targetContentSize(in: smallVisible), NSSize(width: 616, height: 540))
        XCTAssertEqual(WindowMode.cockpit.targetContentSize(in: smallVisible), NSSize(width: 900, height: 720))
    }

    /// The invariant the corridor broke: a mode whose FLOOR is bigger than
    /// the size it opens at cannot open at that size. `minSize` becomes the
    /// hosted SwiftUI root's `.frame(minWidth:)`, and a root that demands
    /// more than the window gets stretches the window — past every
    /// `contentMinSize`/`contentMaxSize` pin AppKit has. The corridor sat at
    /// 740x520 after its target shrank to 616x540 and came up 744pt wide.
    func testNoModeAsksForAFloorBiggerThanTheSizeItOpensAt() {
        let visible = NSRect(x: 0, y: 0, width: 4000, height: 3000)
        for mode in [WindowMode.cockpit, WindowMode.corridor] {
            let target = mode.targetContentSize(in: visible)
            XCTAssertLessThanOrEqual(
                mode.minSize.width, target.width, "\(mode) floor is wider than the size it opens at")
            XCTAssertLessThanOrEqual(
                mode.minSize.height, target.height, "\(mode) floor is taller than the size it opens at")
        }
    }

    /// The corridor's side margins are DERIVED from the same constants as
    /// its width, so "the room left and right equals the room on top"
    /// (owner 2026-08-18) holds by construction rather than by luck.
    func testCorridorSideMarginsEqualItsTopInset() {
        let stage = FlowLayout.stageMaxWidth
        let inset = FlowLayout.minHorizontalInset
        XCTAssertEqual(WindowMode.corridorContentSize.width, stage + inset * 2)
        XCTAssertEqual(inset, FlowLayout.topInset, "the top inset and the side inset are the same room")
    }

    func testFlowModeTogglesResizabilityAndPinsTheCorridorToItsFixedSize() {
        let controller = openLocalController()
        defer { controller.window?.orderOut(nil) }
        let win = try! XCTUnwrap(controller.window)

        XCTAssertTrue(win.styleMask.contains(.resizable), "cockpit must open resizable")
        assertFloor(win, content: NSSize(width: 1000, height: 700))

        controller.setFlowMode(true) // -> corridor
        XCTAssertFalse(win.styleMask.contains(.resizable), "corridor must not be user-resizable")
        // Corridor's target ignores the visible frame entirely — always
        // `corridorContentSize` (616×540, the column plus its two margins).
        let corridorTarget = NSSize(width: 616, height: 540)
        assertFloor(win, content: corridorTarget, ceiling: corridorTarget)
        // `win.frame` is the whole window including the title bar — compare
        // the CONTENT size, which is what `setContentSize` actually set.
        XCTAssertEqual(win.contentRect(forFrameRect: win.frame).size, corridorTarget)

        controller.setFlowMode(false) // back -> cockpit
        XCTAssertTrue(win.styleMask.contains(.resizable), "swapping back to the cockpit must restore resizing")
        assertFloor(win, content: NSSize(width: 1000, height: 700))
        XCTAssertGreaterThan(win.maxSize.width, 100_000, "cockpit's ceiling must be restored to unbounded")
    }

    // MARK: - N1 (audit 2026-08-17): the 1000x700 minimum is ENFORCED

    /// Both of AppKit's spellings must agree, and both must mean the CONTENT
    /// size this file's constants are written in. 1.3.1 wrote a content size
    /// into the FRAME property and enforced neither — a real edge drag took
    /// the cockpit to 226x231 with the content clipping, not reflowing.
    private func assertFloor(
        _ win: NSWindow, content: NSSize, ceiling: NSSize? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(win.contentMinSize, content, "content floor", file: file, line: line)
        XCTAssertEqual(
            win.minSize, win.frameRect(forContentRect: NSRect(origin: .zero, size: content)).size,
            "frame floor must be the content floor plus this window's own chrome", file: file, line: line)
        guard let ceiling else { return }
        XCTAssertEqual(win.contentMaxSize, ceiling, "content ceiling", file: file, line: line)
        XCTAssertEqual(
            win.maxSize, win.frameRect(forContentRect: NSRect(origin: .zero, size: ceiling)).size,
            "frame ceiling", file: file, line: line)
    }

    /// The delegate hook AppKit consults for every user drag. Pure, so the
    /// floor is pinned without a display; the REAL drag is
    /// `scripts/e2e-real-resize.sh`.
    func testWindowWillResizeRefusesToGoBelowTheCockpitFloor() {
        let floor = NSSize(width: 1000, height: 732) // 1000x700 content + a 32pt bar
        // The exact sizes the audit's drag reached: 876 -> 426 -> 226 wide
        // (title bar untouched), then 231 tall.
        for proposed in [NSSize(width: 876, height: 852), NSSize(width: 426, height: 852), NSSize(width: 226, height: 852)] {
            let got = NativeCockpitWindowController.clampedFrameSize(proposed, floor: floor, ceiling: nil)
            XCTAssertEqual(
                got, NSSize(width: 1000, height: 852),
                "a drag to \(proposed) must stop at the 1000pt floor, not clip the content")
        }
        XCTAssertEqual(
            NativeCockpitWindowController.clampedFrameSize(
                NSSize(width: 226, height: 231), floor: floor, ceiling: nil),
            floor, "a drag that undershoots on BOTH axes stops at both floors")
        // Each axis clamps on its own — dragging the bottom edge must not
        // also snap the width the user chose, and vice versa.
        XCTAssertEqual(
            NativeCockpitWindowController.clampedFrameSize(
                NSSize(width: 1400, height: 300), floor: floor, ceiling: nil),
            NSSize(width: 1400, height: 732))
        XCTAssertEqual(
            NativeCockpitWindowController.clampedFrameSize(
                NSSize(width: 1400, height: 900), floor: floor, ceiling: nil),
            NSSize(width: 1400, height: 900), "above the floor the user's own size is untouched")
    }

    func testWindowWillResizePinsTheCorridorToItsExactSize() {
        // Any size works here: the property under test is that a mode whose
        // floor and ceiling are EQUAL pins every proposal to that size.
        let fixed = NSSize(width: 860, height: 592)
        for proposed in [NSSize(width: 400, height: 400), NSSize(width: 2000, height: 1500)] {
            XCTAssertEqual(
                NativeCockpitWindowController.clampedFrameSize(proposed, floor: fixed, ceiling: fixed),
                fixed, "the corridor is one size — floor and ceiling are the same number")
        }
    }
}
