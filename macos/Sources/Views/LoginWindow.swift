import AppKit
import SwiftUI

/// The standalone "Add account" window — the menu bar's Add account, the
/// doctor's remedy and onboarding's "Sign in again" open it. It hosts the
/// same AddAccountSheet the cockpit shows: sign-in runs through Claude Code
/// (the daemon starts `claude auth login`, which opens the browser), so
/// there is no web page in here at all.
final class LoginWindowController: NSWindowController, NSWindowDelegate {
    static let shared = LoginWindowController()

    private var model: AddAccountModel?

    /// Opens (or brings forward) the window. `email` starts a sign-in
    /// pre-filled with that account straight away; `state` lets the
    /// "already signed in on this Mac" list leave out what the fleet has.
    func open(
        email: String? = nil, state: DaemonState? = nil,
        api: CockpitDaemonAPI & DaemonAPI = HTTPDaemonClient()
    ) {
        if let win = window, win.isVisible, let model {
            Self.apply(state, to: model)
            if let email, model.phase == .idle { model.browserSignIn(email: email) }
            present(win)
            return
        }
        window?.close()
        // EditableWindow: the paste field must answer ⌘V even though this
        // LSUIElement app's main menu may belong to the MenuBarExtra scene.
        let win = EditableWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 240),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        win.title = AddAccountCopy.title
        win.isReleasedWhenClosed = false
        win.delegate = self
        let m = AddAccountModel(api: api)
        Self.apply(state, to: m)
        m.onRequestClose = { [weak self, weak win] in
            // Close only the window THIS model belongs to — a newer one may
            // have replaced it during the done linger.
            guard let self, let win, self.window === win else { return }
            win.close()
        }
        model = m
        // A hosting CONTROLLER sizes the window to the content and follows
        // it as the paste box opens and closes.
        let hosting = NSHostingController(rootView: AddAccountSheet(model: m)
            .padding(20)
            .frame(width: 460, alignment: .topLeading))
        hosting.sizingOptions = [.preferredContentSize]
        win.contentViewController = hosting
        window = win
        win.center()
        present(win)
        if let email { m.browserSignIn(email: email) }
    }

    private static func apply(_ state: DaemonState?, to model: AddAccountModel) {
        guard let state else { return }
        model.fleetEmails = state.accounts.map(\.email).filter { !$0.isEmpty }
        model.fleetDir = state.accounts.first { !$0.pinned }?.configDir ?? ""
    }

    private func present(_ win: NSWindow) {
        // Promote BEFORE activating: activating while still ACCESSORY leaves
        // AppKit believing the app is active while the window server never
        // made it frontmost, and the cockpit's later promotion then comes up
        // behind the previous app (measured 2026-08-17, F18).
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Reciprocal half of the cockpit's own close guard: the cockpit
        // declines to demote while THIS window is up, so if the cockpit
        // closed first, this close is the app's last chance to drop back to
        // accessory. Hosted tests never flip the policy.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        let cockpit = NativeCockpitWindowController.shared.window
        if !(cockpit?.isVisible == true || cockpit?.isMiniaturized == true) {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

/// Answers ⌘V/⌘C/⌘X/⌘A/⌘Z directly instead of relying on NSApp.mainMenu,
/// which this LSUIElement app's MenuBarExtra scene can end up owning.
final class EditableWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let selector = Self.editingSelector(for: event) {
            return NSApp.sendAction(selector, to: nil, from: self)
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Pure mapping so the ⌘-only requirement is unit-testable without a
    /// window server: ⌘⇧V and friends must NOT match, only the bare chord.
    static func editingSelector(for event: NSEvent) -> Selector? {
        // Caps Lock rides in deviceIndependentFlagsMask, so an exact compare
        // against .command silently stops matching whenever it is on — and
        // the fallback is the very menu path this class exists to bypass.
        let mods = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting(.capsLock)
        guard mods == .command, let key = event.charactersIgnoringModifiers?.lowercased()
        else { return nil }
        switch key {
        case "v": return #selector(NSText.paste(_:))
        case "c": return #selector(NSText.copy(_:))
        case "x": return #selector(NSText.cut(_:))
        case "a": return #selector(NSText.selectAll(_:))
        case "z": return Selector(("undo:"))
        default: return nil
        }
    }
}
