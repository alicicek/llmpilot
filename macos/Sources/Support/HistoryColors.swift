import Foundation

/// Pure port of web/src/history/colors.ts's data functions — hex-string
/// math for an EXPLICIT `dark: Bool`, no SwiftUI/AppKit and no live
/// appearance lookup. This is a DIFFERENT namespace from
/// `CockpitTheme` (Support/CockpitTheme.swift): CockpitTheme owns the
/// live, appearance-tracking `Color` tokens actually painted on screen;
/// `HistoryColors` is the pure ramp-selection logic the web chart code
/// runs before those colors ever reach a view, kept testable against the
/// same golden vectors as its web source.
enum HistoryColors {
    /// web/src/history/colors.ts `MODEL_RAMP_LIGHT`.
    static let modelRampLight: [String] = ["#083a80", "#0a6ae0", "#4a90ee", "#82b3ea"]
    /// web/src/history/colors.ts `MODEL_RAMP_DARK`.
    static let modelRampDark: [String] = ["#0a5bbf", "#3d8ef7", "#7ab8ff", "#b8d9ff"]

    /// web/src/history/colors.ts `FAMILY_ORDER`.
    static let FAMILY_ORDER: [String] = ["Fable", "Opus", "Sonnet", "Haiku"]
    /// web/src/history/colors.ts `OTHER_FAMILY`.
    static let OTHER_FAMILY = "Other"

    /// web/src/history/colors.ts `familyOf`. Lowercases the id FIRST
    /// (unlike `HistoryPricing.priceFor`, which is case-sensitive), then
    /// checks substrings in this fixed order — fable, opus, sonnet, haiku
    /// — so an id matching more than one substring (never a real model id,
    /// but possible for a synthetic/test one) resolves to whichever comes
    /// first in that order. Anything matching none keeps its own verbatim,
    /// ORIGINAL-CASE id — the "fold to Other" step happens downstream, in
    /// `colorForFamily`/`HistoryAggregate.buildSegments`, not here.
    static func familyOf(_ modelID: String) -> String {
        let id = modelID.lowercased()
        if id.contains("fable") { return "Fable" }
        if id.contains("opus") { return "Opus" }
        if id.contains("sonnet") { return "Sonnet" }
        if id.contains("haiku") { return "Haiku" }
        return modelID
    }

    /// web/src/history/colors.ts `colorForFamily`. TRAP: the dark-ramp
    /// index is `3 - i`, NOT `i` — `modelRampLight` is stored
    /// strongest-first, `modelRampDark` weakest-first, so the same family
    /// rank needs opposite array positions in the two ramps. "Other" (or
    /// any unrecognized family) resolves to the graydot token's own
    /// resolved hex — the web returns the literal CSS var `var(--graydot)`
    /// instead, since it never leaves CSS; this pure, no-appearance-lookup
    /// port resolves it outright. MUST track `CockpitTheme.grayDot`'s two
    /// hex literals (`0xa5a5ac` light / `0x6f6f76` dark) if theme.css ever
    /// changes them.
    static func colorForFamily(_ family: String, dark: Bool) -> String {
        guard let i = FAMILY_ORDER.firstIndex(of: family) else {
            return dark ? "#6f6f76" : "#a5a5ac"
        }
        return dark ? modelRampDark[3 - i] : modelRampLight[i]
    }

    private static let onFillInk = "#1d1d1f"
    private static let onFillWhite = "#ffffff"
    private static let textOnLightRamp = [onFillWhite, onFillWhite, onFillInk, onFillInk]
    private static let textOnDarkRamp = [onFillWhite, onFillInk, onFillInk, onFillInk]

    /// web/src/history/colors.ts `textOnFamilyFill`. Per-ramp-index text
    /// pick (white vs the app's fixed ink), same `3 - i` dark-index flip as
    /// `colorForFamily`. "Other" falls through to `dark ? white : ink`.
    static func textOnFamilyFill(_ family: String, dark: Bool) -> String {
        guard let i = FAMILY_ORDER.firstIndex(of: family) else {
            return dark ? onFillWhite : onFillInk
        }
        return dark ? textOnDarkRamp[3 - i] : textOnLightRamp[i]
    }

    private static func hexToRGB(_ hex: String) -> (Double, Double, Double) {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let n = UInt32(s, radix: 16) ?? 0
        return (Double((n >> 16) & 0xFF), Double((n >> 8) & 0xFF), Double(n & 0xFF))
    }

    private static func rgbToHex(_ r: Double, _ g: Double, _ b: Double) -> String {
        func c(_ v: Double) -> String {
            let clamped = max(0, min(255, v))
            return String(format: "%02x", Int(HistoryFormat.mathRound(clamped)))
        }
        return "#\(c(r))\(c(g))\(c(b))"
    }

    /// web/src/history/colors.ts `interpolateStops` (module-private there).
    private static func interpolateStops(_ stops: [String], _ t: Double) -> String {
        let clamped = max(0, min(1, t))
        let scaled = clamped * Double(stops.count - 1)
        let i = Int(scaled.rounded(.down))
        let frac = scaled - Double(i)
        if i >= stops.count - 1 { return stops[stops.count - 1] }
        let (r1, g1, b1) = hexToRGB(stops[i])
        let (r2, g2, b2) = hexToRGB(stops[i + 1])
        return rgbToHex(r1 + (r2 - r1) * frac, g1 + (g2 - g1) * frac, b1 + (b2 - b1) * frac)
    }

    /// web/src/history/colors.ts `sequentialColor`. `t` in [0,1] (clamped
    /// outside it): 0 = near-zero/recedes toward the surface, 1 =
    /// strongest step. TRAP: the light stops are `modelRampLight`
    /// REVERSED, the dark stops are `modelRampDark` used AS-IS ascending —
    /// each ramp is read in its own natural weakest-to-strongest order,
    /// which happens to mean "reverse the light one, not the dark one"
    /// given how the two ramps are stored (see `colorForFamily`).
    static func sequentialColor(_ t: Double, dark: Bool) -> String {
        let stops = dark ? modelRampDark : Array(modelRampLight.reversed())
        return interpolateStops(stops, t)
    }
}
