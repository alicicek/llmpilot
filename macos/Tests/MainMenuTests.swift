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
        XCTAssertEqual(WindowMode.corridor.minSize, NSSize(width: 740, height: 520))

        let bigVisible = NSRect(x: 0, y: 0, width: 4000, height: 3000)
        XCTAssertEqual(WindowMode.cockpit.targetContentSize(in: bigVisible), NSSize(width: 1180, height: 820))
        XCTAssertEqual(WindowMode.corridor.targetContentSize(in: bigVisible), NSSize(width: 860, height: 560))

        // Corridor's target never grows with the screen — the whole point
        // of a fixed size — where the cockpit's does (0.9× visible, clamped).
        let smallVisible = NSRect(x: 0, y: 0, width: 1000, height: 800)
        XCTAssertEqual(WindowMode.corridor.targetContentSize(in: smallVisible), NSSize(width: 860, height: 560))
        XCTAssertEqual(WindowMode.cockpit.targetContentSize(in: smallVisible), NSSize(width: 900, height: 720))
    }

    func testFlowModeTogglesResizabilityAndPinsTheCorridorToItsFixedSize() {
        let controller = openLocalController()
        defer { controller.window?.orderOut(nil) }
        let win = try! XCTUnwrap(controller.window)

        XCTAssertTrue(win.styleMask.contains(.resizable), "cockpit must open resizable")
        XCTAssertEqual(win.minSize, NSSize(width: 1000, height: 700))

        controller.setFlowMode(true) // -> corridor
        XCTAssertFalse(win.styleMask.contains(.resizable), "corridor must not be user-resizable")
        // Corridor's target ignores the visible frame entirely — always the
        // fixed 860×560 (WindowMode.targetContentSize's `.corridor` case).
        let corridorTarget = NSSize(width: 860, height: 560)
        XCTAssertEqual(win.minSize, corridorTarget, "min pinned to the fixed target so AppKit cannot shrink it")
        XCTAssertEqual(win.maxSize, corridorTarget, "max pinned to the fixed target so AppKit cannot grow it")
        // `win.frame` is the whole window including the title bar — compare
        // the CONTENT size, which is what `setContentSize` actually set.
        XCTAssertEqual(win.contentRect(forFrameRect: win.frame).size, corridorTarget)

        controller.setFlowMode(false) // back -> cockpit
        XCTAssertTrue(win.styleMask.contains(.resizable), "swapping back to the cockpit must restore resizing")
        XCTAssertEqual(win.minSize, NSSize(width: 1000, height: 700))
        XCTAssertGreaterThan(win.maxSize.width, 100_000, "cockpit's ceiling must be restored to unbounded")
    }
}
