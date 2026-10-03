import Foundation

/// Lane copy both surfaces share — the menu bar popover and the cockpit
/// lanes describe the same account, so they must say the same thing.
/// U8 (audit 2026-10-02): the popover called a watched lane "Pinned to its
/// own config dir" while the cockpit said "Watched — signs in from its own
/// folder", and its zero-account state sent people to the terminal
/// ("Log in with `claude` first") directly above an Add account button.
enum FleetCopy {
    /// A watched (pinned) lane: a feature, never user error — the engine
    /// reads its limits in place and never swaps it into the shared slot.
    /// Surface-neutral on purpose: the popover's Add account opens the
    /// sign-in window, the cockpit's opens the sheet with the move — so the
    /// sentence names the outcome, not a button (review 2026-10-03).
    static let watchedLane =
        "Watched — signs in from its own folder, usage only. Move it into the fleet to make it switchable."

    /// The popover with nothing registered and nothing detected: the one
    /// path forward is the button beneath this line.
    static let noAccountsHint =
        "Add account below signs you in and starts watching that account's limits."
}
