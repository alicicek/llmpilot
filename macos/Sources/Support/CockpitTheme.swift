import AppKit
import SwiftUI

/// Native token port of the cockpit's "Native Instrument" design system.
///
/// Source of truth: web/src/theme.css. Every value here must track that
/// file exactly — do not hand-tune a color here without updating theme.css
/// first (and vice versa). The light column mirrors theme.css's `:root`
/// block; the dark column mirrors its `@media (prefers-color-scheme: dark)`
/// override block. This is a SEPARATE namespace from `Theme` (Support/
/// Theme.swift), which maps the menu bar to system colors — CockpitTheme
/// exists because the native cockpit reproduces the web app's exact custom
/// palette, not system semantics.
enum CockpitTheme {
    // MARK: - Construction helpers

    /// Builds a `Color` that resolves to `light` under `.aqua` and `dark`
    /// under `.darkAqua` (and anything `bestMatch` prefers to darkAqua),
    /// tracking live appearance changes automatically.
    private static func dyn(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            let best = appearance.bestMatch(from: [.aqua, .darkAqua])
            return best == .darkAqua ? dark : light
        }))
    }

    /// Opaque color from a `0xRRGGBB` literal, matching theme.css `#rrggbb`.
    private static func hex(_ rgb: UInt32) -> NSColor {
        NSColor(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }

    /// Color from 0-255 channel values plus alpha, matching theme.css
    /// `rgba(r, g, b, a)`.
    private static func rgba(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat) -> NSColor {
        NSColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
    }

    // MARK: - Surfaces

    static let win = dyn(light: hex(0xffffff), dark: hex(0x1e1e21))
    static let toolbar = dyn(light: hex(0xf5f5f7), dark: hex(0x29292d))
    static let panel = dyn(light: hex(0xf8f8fa), dark: hex(0x232327))
    static let rail = dyn(light: hex(0xe8e8ed), dark: hex(0x3a3a3f))
    static let hair = dyn(light: rgba(0, 0, 0, 0.11), dark: rgba(255, 255, 255, 0.1))
    static let hairSoft = dyn(light: rgba(0, 0, 0, 0.06), dark: rgba(255, 255, 255, 0.055))

    // MARK: - Text

    static let text = dyn(light: hex(0x1d1d1f), dark: hex(0xf2f2f4))
    static let sec = dyn(light: hex(0x59595e), dark: hex(0xa8a8af))
    /// was #86868b — fails AA at annotation sizes; passing on win AND panel
    /// (5.07:1). Dark: was #77777e — 3.74:1 on dark; nearest passing step.
    static let ter = dyn(light: hex(0x6a6a6f), dark: hex(0x8a8a91))
    static let wash = dyn(light: rgba(20, 20, 40, 0.035), dark: rgba(0, 0, 0, 0.17))

    // MARK: - Accent

    static let accent = dyn(light: hex(0x0a7aff), dark: hex(0x0a84ff))
    static let accA = dyn(light: rgba(10, 122, 255, 0.07), dark: rgba(10, 132, 255, 0.1))
    static let accB = dyn(light: rgba(10, 122, 255, 0.34), dark: rgba(10, 132, 255, 0.4))
    static let accBd = dyn(light: rgba(10, 122, 255, 0.5), dark: rgba(90, 170, 255, 0.55))
    static let accTx = dyn(light: hex(0x0a6ae0), dark: hex(0x7ab8ff))
    /// Fill for a FILLED primary action carrying white text. `accTx`'s dark
    /// value is the light text-on-tint blue: white over it measures 2.07:1,
    /// far under the 4.5:1 small-text floor (design critique 2026-08-09,
    /// ratio computed, and visible as the washed-out paywall CTA against the
    /// education screens' saturated one). This token is the one both button
    /// styles fill with, so the corridor's primary action is a single colour
    /// throughout: white over it is 5.06:1 light / 5.27:1 dark.
    static let actionFill = dyn(light: hex(0x0a6ae0), dark: hex(0x0068d9))
    static let chipBg = dyn(light: hex(0xeaf3ff), dark: rgba(10, 132, 255, 0.17))
    static let chipBd = dyn(light: rgba(10, 122, 255, 0.42), dark: rgba(100, 175, 255, 0.5))

    // MARK: - Success

    static let ok = dyn(light: hex(0x1fa943), dark: hex(0x30d158))
    /// was #147d33 — 4.49:1 on okbg-over-panel (ACTIVE badge), a hair
    /// under AA; nearest passing step (4.86:1).
    static let okTx = dyn(light: hex(0x137731), dark: hex(0x30d158))
    static let okBg = dyn(light: rgba(52, 199, 89, 0.12), dark: rgba(48, 209, 88, 0.13))
    static let okBd = dyn(light: rgba(40, 170, 80, 0.4), dark: rgba(48, 209, 88, 0.4))

    // MARK: - Warning

    /// pack #c86f00 = 3.46:1 on panel, fails AA; nearest passing amber text
    /// (5.2:1).
    static let warn = dyn(light: hex(0x9d5700), dark: hex(0xffab3d))
    static let warnRaw = dyn(light: hex(0xff9500), dark: hex(0xff9f0a))
    static let warnBg = dyn(light: rgba(255, 149, 0, 0.1), dark: rgba(255, 159, 10, 0.12))
    static let warnBd = dyn(light: rgba(255, 149, 0, 0.4), dark: rgba(255, 159, 10, 0.42))
    static let warnZone = dyn(light: rgba(255, 149, 0, 0.09), dark: rgba(255, 159, 10, 0.1))

    // MARK: - Critical

    static let crit = dyn(light: hex(0xe5493f), dark: hex(0xff5f55))
    /// white-text-safe red (4.99:1) for filled pills. Same value in light
    /// and dark by design — do not split this into two hexes.
    static let critDeep = dyn(light: hex(0xd0342b), dark: hex(0xd0342b))
    static let critZone1 = dyn(light: rgba(255, 59, 48, 0.13), dark: rgba(255, 69, 58, 0.16))
    static let critZone2 = dyn(light: rgba(255, 59, 48, 0.045), dark: rgba(255, 69, 58, 0.05))

    // MARK: - Misc

    static let grayDot = dyn(light: hex(0xa5a5ac), dark: hex(0x6f6f76))
    static let hatch = dyn(light: rgba(60, 60, 67, 0.3), dark: rgba(255, 255, 255, 0.17))
    static let hatchBg = dyn(light: rgba(60, 60, 67, 0.05), dark: rgba(255, 255, 255, 0.045))
    static let hudBg = dyn(light: rgba(28, 28, 32, 0.95), dark: rgba(44, 44, 50, 0.97))
    static let hudTx = dyn(light: hex(0xf5f5f7), dark: hex(0xffffff))
    static let tick = dyn(light: rgba(10, 122, 255, 0.35), dark: rgba(120, 185, 255, 0.4))

    // MARK: - Shadows

    /// One CSS `box-shadow` layer. CSS gives blur radius, not a Gaussian
    /// sigma; SwiftUI's `.shadow(radius:)` expects the latter, so we
    /// approximate radius = blur / 2 (a common, visually-close mapping —
    /// not an exact translation of the CSS blur algorithm).
    struct ShadowSpec {
        let color: Color
        let radius: CGFloat
        let x: CGFloat
        let y: CGFloat
    }

    /// theme.css `--shadow-window` (`:root`), three layers:
    /// `0 22px 60px rgba(0,0,0,.16)`, `0 3px 12px rgba(0,0,0,.08)`,
    /// `0 0 0 .5px rgba(0,0,0,.14)`. The third layer is a 0-blur/0.5px-
    /// spread hairline outline; spread has no ShadowSpec equivalent here,
    /// so it is carried through as `radius` directly (not halved).
    static let shadowWindowLight: [ShadowSpec] = [
        ShadowSpec(color: Color(nsColor: rgba(0, 0, 0, 0.16)), radius: 30, x: 0, y: 22),
        ShadowSpec(color: Color(nsColor: rgba(0, 0, 0, 0.08)), radius: 6, x: 0, y: 3),
        ShadowSpec(color: Color(nsColor: rgba(0, 0, 0, 0.14)), radius: 0.5, x: 0, y: 0),
    ]

    /// theme.css `--shadow-window` (dark override), three layers:
    /// `0 26px 70px rgba(0,0,0,.55)`, `0 4px 14px rgba(0,0,0,.4)`,
    /// `0 0 0 .5px rgba(255,255,255,.12)`.
    static let shadowWindowDark: [ShadowSpec] = [
        ShadowSpec(color: Color(nsColor: rgba(0, 0, 0, 0.55)), radius: 35, x: 0, y: 26),
        ShadowSpec(color: Color(nsColor: rgba(0, 0, 0, 0.4)), radius: 7, x: 0, y: 4),
        ShadowSpec(color: Color(nsColor: rgba(255, 255, 255, 0.12)), radius: 0.5, x: 0, y: 0),
    ]

    /// theme.css `--shadow-drag`: `0 7px 18px rgba(0,0,0,.38)`. Identical
    /// in light and dark.
    static let shadowDrag: [ShadowSpec] = [
        ShadowSpec(color: Color(nsColor: rgba(0, 0, 0, 0.38)), radius: 9, x: 0, y: 7),
    ]

    /// theme.css `--shadow-hud`: `0 4px 14px rgba(0,0,0,.4)`. Identical in
    /// light and dark.
    static let shadowHud: [ShadowSpec] = [
        ShadowSpec(color: Color(nsColor: rgba(0, 0, 0, 0.4)), radius: 7, x: 0, y: 4),
    ]

    // MARK: - Severity

    /// The shipped severity trio, in the web cockpit's vocabulary
    /// (web/src/board/severity.ts `Severity`).
    enum SeverityBand: String {
        case calm, warn, crit
    }

    /// Native mirror of web/src/board/severity.ts `bucketSeverity`: the
    /// server-supplied severity string ("critical"/"warning") OVERRIDES the
    /// percent thresholds; anything else falls through to percent (warn ≥70,
    /// crit ≥90). Pinned cross-stack by testdata/golden-vectors/severity.json
    /// — change either side only through that file.
    static func severityBand(percent: Double, severity: String? = nil) -> SeverityBand {
        if severity == "critical" { return .crit }
        if severity == "warning" { return .warn }
        if percent >= 90 { return .crit }
        if percent >= 70 { return .warn }
        return .calm
    }

    // MARK: - Typography

    /// Tabular numerals are mandatory for every count/timer
    /// (design/DESIGN-SYSTEM.md) — theme.css enforces this globally via
    /// `font-variant-numeric: tabular-nums`.
    static func numeric(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight).monospacedDigit()
    }

    /// Onboarding corridor type scale — a documented EXCEPTION to
    /// design/DESIGN-SYSTEM.md's 15pt title scale (see that file's
    /// "Onboarding corridor type scale" amendment, added design critique
    /// 2026-08-09): a full-window first-run surface reads at arm's length
    /// like a landing page, not a 302pt in-cockpit inspector rail, so its
    /// headline earns a larger size than any in-cockpit panel uses. Every
    /// onboarding/education/paywall screen routes through these named
    /// tokens instead of ad-hoc `.system(size:)` calls, so the scale lives
    /// in exactly one place.
    ///
    /// Every token is built on `numeric(_:weight:)` — `.monospacedDigit()`
    /// is a pure font trait that leaves non-digit glyphs untouched, so
    /// baking it into every corridor token (not just the ones an author
    /// remembers carry a numeral) is what makes "every numeral inside a
    /// mixed string is tabular" (design/DESIGN-SYSTEM.md) true by
    /// construction rather than by per-call-site discipline.
    ///
    /// Line-height constants are `.lineSpacing()` deltas (SwiftUI has no
    /// direct line-height API): `target line height − point size`, the
    /// same approximation trade CockpitTheme's shadow radii already make
    /// for CSS blur — not an exact typographic leading calculation, close
    /// enough for the corridor's short, mostly single-line copy.
    enum Onboarding {
        /// The screen's one big statement — 20pt semibold / ~26pt line
        /// height / −0.2 tracking.
        static let headline = CockpitTheme.numeric(20, weight: .semibold)
        /// The headline's emphasized clause — heavier weight carries the
        /// emphasis design/DESIGN-SYSTEM.md's reserved accent blue used to
        /// (color is meaning: booked/charging + actions only, never
        /// decoration).
        static let headlineEmphasis = CockpitTheme.numeric(20, weight: .bold)
        static let headlineTracking: CGFloat = -0.2
        static let headlineLineSpacing: CGFloat = 6

        /// The one-line support sentence directly under the headline.
        static let lede = CockpitTheme.numeric(13, weight: .regular)
        static let ledeLineSpacing: CGFloat = 5

        /// Body copy and the closing note.
        static let body = CockpitTheme.numeric(12.5, weight: .regular)
        static let bodyLineSpacing: CGFloat = 4.5

        /// A control's own label (buttons, selectable rows).
        static let controlLabel = CockpitTheme.numeric(13, weight: .semibold)

        /// A data-table row (the receipt table).
        static let tableRow = CockpitTheme.numeric(12.5, weight: .regular)
        static let tableRowLineSpacing: CGFloat = 4.5

        /// A secondary status/fact line (lane status, timeline stops).
        static let status = CockpitTheme.numeric(11.5, weight: .regular)
        static let statusLineSpacing: CGFloat = 3.5

        /// Annotation / disclosure copy — the smallest readable size in
        /// the corridor.
        static let annotation = CockpitTheme.numeric(10.5, weight: .regular)
        static let annotationLineSpacing: CGFloat = 3.5

        /// The commercial amount line (price screen, offer card).
        static let commercialAmount = CockpitTheme.numeric(16, weight: .semibold)
        /// The struck reference amount beside a lower offer.
        static let strikeAmount = CockpitTheme.numeric(13, weight: .medium)

        /// "N of M" step counter.
        static let progressLabel = CockpitTheme.numeric(11, weight: .medium)
    }

    // MARK: - Motion

    /// design/DESIGN-SYSTEM.md motion budget: 150-250ms, state-only.
    /// theme.css's FACE-SWAP move (token swap on `body`) uses 200ms.
    enum Motion {
        static let swap: TimeInterval = 0.2
        static let state: ClosedRange<TimeInterval> = 0.15...0.25
    }
}
