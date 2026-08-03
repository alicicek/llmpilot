import SwiftUI

/// Pack rule: Apple owns the materials — system colors ARE the tokens here
/// (DESIGN-SYSTEM.md: "production maps to NSColor/system vars where they
/// exist — token swap, not component swap"). Color is meaning, never
/// decoration; stale data is drained, never color-judged.
enum Theme {
    static let ok = Color(nsColor: .systemGreen)
    static let warn = Color(nsColor: .systemOrange)
    static let crit = Color(nsColor: .systemRed)
    static let accent = Color(nsColor: .systemBlue)
    static let drained = Color(nsColor: .tertiaryLabelColor)
    static let rail = Color(nsColor: .quaternaryLabelColor)
    /// The track's terminus tick. A filled capsule's rounded end is shaped
    /// exactly like a 100% bar's end, so at high fill the eye can't tell
    /// 90 from full — the tick marks where the track really ends, and the
    /// gap between fill and tick IS the headroom.
    static let railEnd = Color(nsColor: .tertiaryLabelColor)

    /// Runway severity trio: calm green → warn ≥70 amber → critical ≥90 red.
    static func severity(_ percent: Double) -> Color {
        if percent >= 90 { return crit }
        if percent >= 70 { return warn }
        return ok
    }

    static func severityNS(_ percent: Double) -> NSColor {
        if percent >= 90 { return .systemRed }
        if percent >= 70 { return .systemOrange }
        return .systemGreen
    }
}
