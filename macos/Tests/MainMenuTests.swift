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
}
