import XCTest
@testable import llmpilot

/// EditableWindow.editingSelector — the pure key-equivalent mapping that
/// lets the login window answer ⌘V/⌘C/⌘A itself. No window server, no
/// dispatched events: NSEvent.keyEvent(with:) only builds the event object.
@MainActor
final class EditableWindowTests: XCTestCase {
    private func keyEvent(_ chars: String, _ flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: chars,
            charactersIgnoringModifiers: chars,
            isARepeat: false,
            keyCode: 0)!
    }

    func testCommandVMapsToPaste() {
        let event = keyEvent("v", .command)
        XCTAssertEqual(EditableWindow.editingSelector(for: event), #selector(NSText.paste(_:)))
    }

    func testCommandCMapsToCopy() {
        let event = keyEvent("c", .command)
        XCTAssertEqual(EditableWindow.editingSelector(for: event), #selector(NSText.copy(_:)))
    }

    func testCommandAMapsToSelectAll() {
        let event = keyEvent("a", .command)
        XCTAssertEqual(EditableWindow.editingSelector(for: event), #selector(NSText.selectAll(_:)))
    }

    func testCommandShiftVDoesNotMatch() {
        let event = keyEvent("v", [.command, .shift])
        XCTAssertNil(EditableWindow.editingSelector(for: event), "extra modifiers are not the plain paste chord")
    }

    func testPlainVDoesNotMatch() {
        let event = keyEvent("v", [])
        XCTAssertNil(EditableWindow.editingSelector(for: event))
    }

    /// Caps Lock sits inside deviceIndependentFlagsMask, so an exact compare
    /// against .command stops matching the moment it is on — and the fallback
    /// is the app menu this window cannot rely on. Paste must not depend on
    /// the state of a lock key.
    func testCapsLockDoesNotDefeatPaste() {
        let event = keyEvent("v", [.command, .capsLock])
        XCTAssertEqual(EditableWindow.editingSelector(for: event), #selector(NSText.paste(_:)))
    }

    func testCapsLockStillDoesNotMakeBareVPaste() {
        let event = keyEvent("v", [.capsLock])
        XCTAssertNil(EditableWindow.editingSelector(for: event))
    }
}
