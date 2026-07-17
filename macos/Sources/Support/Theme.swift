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
