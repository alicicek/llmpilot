import Foundation
import SwiftUI

// Native port of web/src/shell/ansi.ts — the statusline preview's minimal
// ANSI SGR parser. The daemon's /v1/statusline/preview returns the binary's
// EXACT bytes (preview==production), so this parses only the escape
// vocabulary the Go renderer can emit: reset (0), dim (2), classic FG
// 30-37, bright FG 90-97 (same table minus 60), 256-color 38;5;n, and
// truecolor 38;2;r;g;b — no backgrounds, bold, or underline. Both sides
// must stay in exact lockstep; testdata/golden-vectors/ansi.json is the
// cross-stack proof (see web/tests/golden-vectors.spec.ts for the web run).

/// One contiguous run of styled text. `color` mirrors ansi.ts's CSS color
/// string EXACTLY — hex for the fixed palettes, `rgb(r,g,b)` for the cube,
/// grayscale ramp, and truecolor — so a reader can diff the two sides
/// byte-for-byte without a translation step.
struct AnsiSpan: Equatable {
    var text: String
    var color: String?
    var dim: Bool = false
}

/// Classic foreground colors tuned to read on the dark preview strip
/// (ansi.ts BASIC).
private let ansiBasic: [Int: String] = [
    30: "#a5a5ac",
    31: "#ff6f61",
    32: "#3ddc68",
    33: "#ffb340",
    34: "#6aa8ff",
    35: "#e58cff",
    36: "#54d1db",
    37: "#f5f5f7",
]

/// ansi.ts xterm256(n).
private func xterm256(_ n: Int) -> String {
    if n < 16 {
        let base = [
            "#000000", "#cd0000", "#00cd00", "#cdcd00", "#0000ee", "#cd00cd", "#00cdcd", "#e5e5e5",
            "#7f7f7f", "#ff0000", "#00ff00", "#ffff00", "#5c5cff", "#ff00ff", "#00ffff", "#ffffff",
        ]
        if n < 0 || n >= base.count { return base[0] }
        return base[n]
    }
    if n < 232 {
        let steps = [0, 95, 135, 175, 215, 255]
        let i = n - 16
        let r = steps[(i / 36) % 6]
        let g = steps[(i / 6) % 6]
        let b = steps[i % 6]
        return "rgb(\(r),\(g),\(b))"
    }
    let v = 8 + (n - 232) * 10
    return "rgb(\(v),\(v),\(v))"
}

/// ansi.ts parseAnsi(line). Operates on Characters (not UTF-16 code units
/// like the JS original) — the statusline's own bytes are ASCII-range
/// escapes plus simple text, so this stays a faithful, simpler port rather
/// than reproducing JS's UTF-16 indexing quirk.
func parseAnsi(_ line: String) -> [AnsiSpan] {
    var spans: [AnsiSpan] = []
    var color: String?
    var dim = false
    var buf = ""

    func flush() {
        if !buf.isEmpty {
            spans.append(AnsiSpan(text: buf, color: color, dim: dim))
        }
        buf = ""
    }

    let chars = Array(line)
    var i = 0
    while i < chars.count {
        if chars[i] == "\u{1B}", i + 1 < chars.count, chars[i + 1] == "[" {
            var end = -1
            var k = i + 2
            while k < chars.count {
                if chars[k] == "m" {
                    end = k
                    break
                }
                k += 1
            }
            if end == -1 { break }
            flush()
            let codesStr = String(chars[(i + 2)..<end])
            let codes: [Int?] = codesStr.split(separator: ";", omittingEmptySubsequences: false)
                .map { Int($0) }
            var j = 0
            while j < codes.count {
                guard let c = codes[j] else {
                    j += 1
                    continue
                }
                if c == 0 {
                    color = nil
                    dim = false
                } else if c == 2 {
                    dim = true
                } else if c >= 30, c <= 37 {
                    color = ansiBasic[c]
                } else if c >= 90, c <= 97 {
                    color = ansiBasic[c - 60]
                } else if c == 38, j + 1 < codes.count, codes[j + 1] == 5 {
                    color = xterm256((j + 2 < codes.count ? codes[j + 2] : nil) ?? 0)
                    j += 2
                } else if c == 38, j + 1 < codes.count, codes[j + 1] == 2 {
                    let r = (j + 2 < codes.count ? codes[j + 2] : nil) ?? 0
                    let g = (j + 3 < codes.count ? codes[j + 3] : nil) ?? 0
                    let b = (j + 4 < codes.count ? codes[j + 4] : nil) ?? 0
                    color = "rgb(\(r),\(g),\(b))"
                    j += 4
                }
                j += 1
            }
            i = end + 1
            continue
        }
        buf.append(chars[i])
        i += 1
    }
    flush()
    return spans
}

extension AnsiSpan {
    /// Parses `color` (hex `#rrggbb` or `rgb(r,g,b)`, the only two shapes
    /// this module ever emits) into a SwiftUI Color. Unrecognized/absent
    /// color falls through to nil (caller supplies the default foreground).
    var swiftUIColor: Color? {
        guard let color else { return nil }
        if color.hasPrefix("#") {
            let hex = color.dropFirst()
            guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
            return Color(
                red: Double((v >> 16) & 0xFF) / 255,
                green: Double((v >> 8) & 0xFF) / 255,
                blue: Double(v & 0xFF) / 255)
        }
        if color.hasPrefix("rgb("), color.hasSuffix(")") {
            let inner = color.dropFirst(4).dropLast(1)
            let parts = inner.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == 3 else { return nil }
            return Color(red: parts[0] / 255, green: parts[1] / 255, blue: parts[2] / 255)
        }
        return nil
    }
}

/// Builds the preview strip's AttributedString from parsed spans — native
/// mirror of StatuslineDialog.tsx:213-221
/// (`{color: s.color, opacity: s.dim ? 0.55 : 1}`). `defaultColor` is the
/// preview strip's own foreground (CockpitTheme.hudTx) for spans that never
/// set one.
func ansiAttributedString(_ spans: [AnsiSpan], defaultColor: Color) -> AttributedString {
    var result = AttributedString()
    for span in spans {
        var run = AttributedString(span.text)
        let base = span.swiftUIColor ?? defaultColor
        run.foregroundColor = span.dim ? base.opacity(0.55) : base
        result += run
    }
    return result
}

/// Claude Code never wraps a statusline row. Measured live in Claude Code
/// 2.1.289 (80 columns: 76 chars fit in full, 77 show 75 + "…"): a row of up
/// to `columns − 4` visible chars is shown unchanged; a longer one is cut to
/// `columns − 5` chars plus "…". The visible width is the Characters of the
/// parsed text, escape codes excluded; the cut keeps each surviving span's
/// colour.
func previewFitColumns(_ columns: Int) -> Int { max(columns - 4, 0) }
func previewVisibleColumns(_ columns: Int) -> Int { max(columns - 5, 0) }

/// The editor preview as Claude Code prints it: the daemon's bytes split
/// into rows on "\n", each row parsed and cut to the terminal's width.
/// Empty bytes are no rows at all (the view shows its placeholder).
func previewRows(_ ansi: String, columns: Int) -> [[AnsiSpan]] {
    guard !ansi.isEmpty else { return [] }
    let fits = previewFitColumns(columns)
    let limit = previewVisibleColumns(columns)
    return ansi.split(separator: "\n", omittingEmptySubsequences: false).map { row in
        let spans = parseAnsi(String(row))
        guard spans.reduce(0, { $0 + $1.text.count }) > fits else { return spans }
        var kept: [AnsiSpan] = []
        var left = limit
        for span in spans where left > 0 {
            var s = span
            s.text = String(span.text.prefix(left))
            left -= s.text.count
            kept.append(s)
        }
        kept.append(AnsiSpan(text: "…", color: nil))
        return kept
    }
}

/// The preview box's width in cells: the longest row as cut, plus the
/// 2-cell indent, never past the terminal's own width. A short line in a
/// wide terminal is a compact box, not 200 cells of empty black.
func previewBoxCells(_ rows: [[AnsiSpan]], columns: Int) -> Int {
    let longest = rows.map { $0.reduce(0) { $0 + $1.text.count } }.max() ?? 0
    return min(columns, longest + 2)
}
