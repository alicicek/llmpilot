import SwiftUI
import Sparkle

@main
struct LLMPilotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model: FleetViewModel
    private let updater: SPUStandardUpdaterController
    /// Real UNUserNotificationCenter delivery for a connected app (chunk 5B)
    /// — the daemon's osascript banner is now the headless-CLI fallback,
    /// used only when this client (or no app at all) isn't listening.
    private let noticeClient: NoticeClient

    init() {
        // Hosted unit tests must not kick off Sparkle's update machinery.
        let testing = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        updater = SPUStandardUpdaterController(
            startingUpdater: !testing, updaterDelegate: nil, userDriverDelegate: nil)
        let model = FleetViewModel(api: HTTPDaemonClient(), autostart: !testing)
        _model = StateObject(wrappedValue: model)
        // Same autostart gate as FleetViewModel: hosted unit tests must
        // never open a real SSE connection to whatever daemon happens to be
        // reachable. Under the e2e sandbox (LLMPILOT_TEST=1, not XCTest)
        // the loop RUNS but parks at NoticeNotifier.canDeliver() — the
        // interlocked app deliberately never opens the /v1/notices leg, so
        // sandbox notices reach the daemon's slog stub where the e2e can
        // observe them (NoticeNotifier.swift). Shared notifier: the UI's
        // permission-prompt triggers (onboarding end, the Settings toggle)
        // must act on the same authorization state this client polls.
        noticeClient = NoticeClient(notifier: NoticeNotifier.shared)
        if !testing {
            noticeClient.start()
        }
        // The recovery deep link needs the fleet to open the cockpit on a
        // successful claim (RecoveryLink.swift); hosted tests never wire it.
        if !testing {
            RecoveryLinkHandler.shared.fleet = model
        }
        // e2e seam: redundant by default since the chunk 6A cutover (the
        // native window is now what FleetViewModel's own first-launch
        // auto-open opens), but still useful for e2e determinism — it opens
        // the window immediately rather than waiting on the daemon's first
        // /v1/state round trip, and does it without navigating the menu bar
        // popover over AX. Opt-in by env, never default.
        if !testing, ProcessInfo.processInfo.environment["LLMPILOT_NATIVE_COCKPIT"] == "1" {
            DispatchQueue.main.async {
                NativeCockpitWindowController.shared.open(fleet: model)
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: model, checkForUpdates: { [updater] in
                updater.checkForUpdates(nil)
            })
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// LSUIElement apps have no default main menu; the cockpit window still
/// needs ⌘W and the Edit shortcuts (typing in the cockpit and sign-in fields).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppMainMenu.install()
    }

    /// llmpilot://recover?token=… from the /recover page's "Open llmpilot"
    /// button. Everything about the URL is untrusted; RecoveryLink refuses
    /// anything that isn't exactly the recovery shape.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            RecoveryLinkHandler.shared.handle(url)
        }
    }
}

/// The app's main menu, installable idempotently. The MenuBarExtra scene's
/// own setup can REPLACE NSApp.mainMenu after the delegate installs it —
/// measured, not theoretical: MainMenuTests' Edit-menu pin failed mid-suite
/// while passing in isolation, exactly the ordering hazard the (deleted)
/// web-cockpit window's comment warned about. Every surface that needs the
/// Edit chords therefore re-asserts on its own open
/// (NativeCockpitWindowController.open; EditableWindow covers the top-level
/// windows regardless, but SwiftUI SHEETS are their own windows and ride
/// only this menu — review 2026-08-08 Phase 6 P1-2).
enum AppMainMenu {
    /// True when the current main menu already carries the Edit → ⌘V item.
    static var installed: Bool {
        guard let main = NSApp.mainMenu else { return false }
        return main.items.compactMap(\.submenu).contains { menu in
            menu.title == "Edit" && menu.items.contains { item in
                item.keyEquivalent == "v" && item.keyEquivalentModifierMask == [.command]
            }
        }
    }

    static func install() {
        if installed { return }
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit llmpilot",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All",
                     action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close",
                           action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize",
                           action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
    }
}
