import CoreGraphics
import Foundation

// Native port of web/src/shell/Tour.tsx's pure logic (App.tsx:92-113's
// TOUR_STEPS + Tour.tsx's live-filtering/advance/end state machine), split
// from the view so the renumbering/last-step rules are testable without
// mounting SwiftUI. See TourOverlayView.swift (Views/Cockpit) for the
// spotlight overlay this drives.
//
// The guide points at the user's OWN cockpit. Each step names one thing on
// screen and what it means for them — a step whose target is absent (no
// second account to switch to) is dropped, and the remaining steps
// renumber (Tour.tsx:58's `live` filter, exactly mirrored below).
//
// DEVIATION from Tour.tsx per audit F15 (2026-08-16, owner decision: the
// tour loses its daemon step): the web's fourth step
// (target "daemon", spotlighting the always-on "Daemon active" pill) is
// dropped along with that pill (ConnectivityViews.swift/NativeToolbar.swift)
// — three steps now, not four. Its one useful sentence ("a menu bar manager
// like Ice or Bartender may hide the icon") survives, folded into the new
// last step's body below rather than lost outright.

/// Tour.tsx's `TourStep` interface — `target` is the anchor id a
/// `.tourAnchor(_:)`-tagged view carries (TourOverlayView.swift).
struct TourStep: Equatable, Identifiable {
    var id: String { target }
    let target: String
    let title: String
    let body: String
}

/// App.tsx:92-113 `TOUR_STEPS`, minus the dropped "daemon" step (F15) —
/// three targets now (runway/switch/fresh-window), same order and copy for
/// the two it keeps unchanged. The fresh-window step's body picks up the
/// one sentence worth saving from the dropped step (see the DEVIATION note
/// above): this is now the tour's own last step, and the least intrusive
/// existing surface to keep that sentence reachable without adding a new
/// screen.
enum TourStepCatalog {
    static let all: [TourStep] = [
        TourStep(
            target: "runway",
            title: "This is your real usage",
            body: "Live limits for the account you are on — session and weekly, straight from Claude. When a bar fills, that account is done until it resets."),
        TourStep(
            target: "switch",
            title: "Move to an account with room",
            body: "One click switches you. Your place is kept and there is no re-login — the autopilot does this for you before you hit a wall."),
        TourStep(
            target: "fresh-window",
            title: "Open a window on your own clock",
            body: "Book a fresh 5-hour window ahead of time and it opens unattended, so your limits reset when you actually work. llmpilot keeps watching from the menu bar even when this window is closed — a menu bar manager like Ice or Bartender may hide the icon."),
    ]
}

/// Tour.tsx's per-step state machine (lines 42-117): which steps are
/// actually on screen right now (`live`), which one is showing (`index`),
/// and whether the walk is over. A fresh instance is created each time the
/// guide opens (NativeCockpitWindow.swift), mirroring the web's `{tourOpen
/// && canGuide && <Tour .../>}` remount — so `index` always starts at 0 for
/// a new walk.
///
/// DEVIATION from Tour.tsx: the web re-derives `live` by querying the real
/// DOM (`rectOf`) on every render, gated by a `ready` flag that exists only
/// because React inserts host nodes at commit, one tick after the function
/// component returns (Tour.tsx:47-55's own comment). SwiftUI's preference
/// system has no such gap — `.tourAnchor(_:)`-tagged views already exist in
/// the tree the moment this overlay mounts (it lays over an already-visible
/// board), and anchor preferences resolve as part of the same layout pass
/// that produces this view's body — so there is no analogous "ready" race
/// to guard, and `availableTargets` can be trusted from the first read.
final class TourModel: ObservableObject {
    let steps: [TourStep]
    /// The anchor ids currently present in the view tree — set by
    /// TourOverlayView from the `.tourAnchor(_:)` PreferenceKey each time it
    /// changes (initial resolve + any later layout change, e.g. a lane
    /// gaining/losing its SWITCH verb).
    @Published var availableTargets: Set<String> = []
    @Published private(set) var index: Int = 0

    init(steps: [TourStep] = TourStepCatalog.all) {
        self.steps = steps
    }

    /// Tour.tsx:58 — only steps whose target actually exists in this
    /// cockpit, in the original order (this IS the renumbering: a dropped
    /// step simply isn't counted).
    var live: [TourStep] { steps.filter { availableTargets.contains($0.target) } }

    var current: TourStep? { live.indices.contains(index) ? live[index] : nil }

    /// Tour.tsx:154 `STEP {i + 1} OF {live.length}`.
    var stepNumber: Int { index + 1 }
    var total: Int { live.count }
    var isLast: Bool { index == live.count - 1 }

    /// Tour.tsx:100-103 — done when there was never anything on screen
    /// worth pointing at, or the walk advanced past the last live step.
    var isDone: Bool { live.isEmpty || index >= live.count }

    /// Tour.tsx:168's `setI((n) => n + 1)` (Next) and the ArrowRight handler
    /// (Tour.tsx:90) — both just advance; walking past the last live step
    /// IS the "Got it" / last-step case (`index == live.count` reads
    /// `isDone`).
    func advance() { index += 1 }

    /// Tour.tsx:100-103's forced end — used when a step's target vanished
    /// out from under an in-progress walk (the live list shrank below the
    /// current index). Idempotent.
    func end() { index = live.count }
}

// MARK: - card placement (Tour.tsx:107-116)

/// Pure port of Tour.tsx's card-clamp math: place the card below the
/// target if it fits, above otherwise, then clamp to the viewport either
/// way (the overlay is fixed and cannot scroll, so a card placed past the
/// fold would take its own buttons off screen with it).
enum TourCardLayout {
    static let cardWidth: CGFloat = 300
    /// Tour.tsx's CARD_H_EST — enough to decide above-vs-below before the
    /// card has been measured; TourOverlayView reads the REAL height back
    /// once laid out (Tour.tsx:146-149's ref callback) and uses it on the
    /// next placement.
    static let cardHeightEstimate: CGFloat = 150
    static let pad: CGFloat = 8
    static let margin: CGFloat = 12

    static func origin(targetRect: CGRect, cardHeight: CGFloat, viewport: CGSize) -> CGPoint {
        let below = targetRect.maxY + pad + cardHeight < viewport.height
        let rawTop = below ? targetRect.maxY + pad + 4 : targetRect.minY - pad - cardHeight
        let top = min(max(margin, rawTop), max(margin, viewport.height - cardHeight - margin))
        let left = min(max(margin, targetRect.minX), max(margin, viewport.width - cardWidth - margin))
        return CGPoint(x: left, y: top)
    }
}
