import SwiftUI

/// One account this menu can book a fresh window on — mirrors the fields
/// Toolbar.tsx's dropdown items and App.tsx's `bookFreshWindow` both read
/// off `State.accounts`.
struct FreshWindowAccount: Identifiable, Equatable {
    let id: String
    let label: String
    let email: String

    /// Toolbar.tsx dropdown item text: `a.label || a.email`.
    var displayName: String { label.isEmpty ? email : label }
}

/// Pure math the view delegates to — testable without instantiating
/// SwiftUI. Mirrors web/src/App.tsx `bookFreshWindow`: derive the trigger
/// (hour, minute) to POST from `BoardSchedule.nextBookableReset`, or the
/// verbatim "fully booked" flash text when no slot clears every existing
/// reset's gap.
enum FreshWindowResolver {
    enum Outcome: Equatable {
        case create(hour: Int, minute: Int)
        case fullyBooked(message: String)
    }

    /// `label` mirrors App.tsx's `acct?.label ?? accountId` — the flash uses
    /// the account's raw `label` (even if empty), NOT the `label || email`
    /// fallback the menu's own item text uses. The `?? accountId` branch
    /// (account not found in state) can't occur here: the caller always
    /// selects from the same accounts list it derived `label` from.
    static func resolve(
        label: String,
        nowMinutes: Int,
        existingResets: [Int],
        activeEndMinutes: Int?
    ) -> Outcome {
        guard let slot = BoardSchedule.nextBookableReset(
            nowMinutes: nowMinutes,
            existingResets: existingResets,
            activeEndMinutes: activeEndMinutes
        ) else {
            return .fullyBooked(message: "\(label) is fully booked — resets must sit ≥ 5 h 15 min apart.")
        }
        let resetMin = slot.hour * 60 + slot.minute
        let trigger = (resetMin - BoardSchedule.windowHours * 60 + BoardSchedule.dayMin) % BoardSchedule.dayMin
        return .create(hour: trigger / 60, minute: trigger % 60)
    }
}

/// Toolbar "＋ Fresh window" dropdown — mirrors web/src/shell/Toolbar.tsx's
/// DropdownMenu (label "BOOK ON", one item per account, disabled with no
/// accounts) fused with web/src/App.tsx's `bookFreshWindow` (the
/// nextBookableReset booking math and its local "fully booked" flash).
/// Standalone: the integrator supplies `laneState` (this account's existing
/// resets + mid-window active end, both in minutes-of-day) and the two
/// outcome closures.
struct FreshWindowMenu: View {
    let accounts: [FreshWindowAccount]
    let nowMinutes: Int
    /// This account's existing resets (minutes-of-day) and, only when its
    /// session is currently active, the session's end (minutes-of-day) —
    /// mirrors App.tsx's `bookFreshWindow` session lookup (bucket kind
    /// "session"|"five_hour", `resets_at`, gated on `session?.active`).
    let laneState: (String) -> (existingResets: [Int], activeEndMinutes: Int?)
    let onCreate: (_ accountID: String, _ hour: Int, _ minute: Int) -> Void
    let onFullyBooked: (_ message: String) -> Void

    var body: some View {
        Menu {
            Text("BOOK ON")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(CockpitTheme.ter)
            ForEach(accounts) { account in
                Button(account.displayName) { select(account) }
            }
        } label: {
            Text("＋ Fresh window")
        }
        .disabled(accounts.isEmpty)
        .accessibilityIdentifier("fresh-window-menu")
        // Toolbar.tsx:58 `data-tour="fresh-window"` — the tour's "book on
        // your own clock" step spotlights this button.
        .tourAnchor("fresh-window")
    }

    private func select(_ account: FreshWindowAccount) {
        let lane = laneState(account.id)
        switch FreshWindowResolver.resolve(
            label: account.label,
            nowMinutes: nowMinutes,
            existingResets: lane.existingResets,
            activeEndMinutes: lane.activeEndMinutes
        ) {
        case let .create(hour, minute):
            onCreate(account.id, hour, minute)
        case let .fullyBooked(message):
            onFullyBooked(message)
        }
    }
}
