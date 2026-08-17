import AppKit
import SwiftUI

// Native ports of the board's presentational "component grammar" —
// web/src/board/ChargeBlock.tsx, TimeChip.tsx, NowLine.tsx, Axis.tsx,
// Hud.tsx. Pure rendering only: no gesture handling, no animation-timing
// orchestration (that lives in BoardTrackView.swift, which owns the
// `TrackDragModel` these pieces render from).

// MARK: - shared shapes

/// Per-corner rounded rectangle — SwiftUI's `UnevenRoundedRectangle` needs
/// macOS 15; this project's floor is macOS 13 (project.yml), so
/// `ChargeBlock`'s squared-off chained edges (ChargeBlock.tsx's
/// `squareLeft`/`squareRight` -> zeroed corner radii) are drawn by hand.
struct BoardRoundedCorners: InsettableShape {
    var topLeft: CGFloat
    var topRight: CGFloat
    var bottomRight: CGFloat
    var bottomLeft: CGFloat
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let tl = max(0, topLeft - insetAmount)
        let tr = max(0, topRight - insetAmount)
        let br = max(0, bottomRight - insetAmount)
        let bl = max(0, bottomLeft - insetAmount)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY + tl))
        p.addArc(center: CGPoint(x: r.minX + tl, y: r.minY + tl),
                  radius: tl, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.addLine(to: CGPoint(x: r.maxX - tr, y: r.minY))
        p.addArc(center: CGPoint(x: r.maxX - tr, y: r.minY + tr),
                  radius: tr, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - br))
        p.addArc(center: CGPoint(x: r.maxX - br, y: r.maxY - br),
                  radius: br, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: r.minX + bl, y: r.maxY))
        p.addArc(center: CGPoint(x: r.minX + bl, y: r.maxY - bl),
                  radius: bl, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.closeSubpath()
        return p
    }

    func inset(by amount: CGFloat) -> some InsettableShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }
}

/// Approximates CSS `repeating-linear-gradient(135deg, stripe 0 stripeWidth,
/// bg stripeWidth period)` — used by both the mid-window "in use" pill
/// (`--hatch`/`--hatchbg`) and the drag-time forbidden-zone fill
/// (`--critzone1`/`--critzone2`). Canvas-drawn diagonal strokes rather than
/// a literal gradient port (SwiftUI has no repeating-linear-gradient
/// primitive); visually equivalent two-tone diagonal stripes, not a pixel
/// match.
struct BoardDiagonalHatch: View {
    var stripeColor: Color
    var backgroundColor: Color
    var stripeWidth: CGFloat = 4
    var period: CGFloat = 9

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(backgroundColor))
            let span = size.width + size.height
            var offset: CGFloat = -span
            while offset < span {
                var path = Path()
                path.move(to: CGPoint(x: offset, y: 0))
                path.addLine(to: CGPoint(x: offset + size.height, y: size.height))
                context.stroke(path, with: .color(stripeColor), style: StrokeStyle(lineWidth: stripeWidth))
                offset += period
            }
        }
        .clipped()
    }
}

// MARK: - ChargeBlock (component grammar #1)

/// web/src/board/ChargeBlock.tsx — a reset is never a point, it's the
/// trailing edge of a rigid 5h object, visible at rest. 30pt tall (top 34),
/// the app's only gradient (accA -> accB, charge direction), 1pt acc-bd
/// border, centered "5:00" watermark.
struct BoardChargeBlock: View {
    let trigger: Int
    let reset: Int
    var squareLeft = false
    var squareRight = false
    var dragging = false
    var hovered = false
    var ghost = false

    /// F16: the board's live track width — see BoardGeometry.swift's
    /// `boardTrackPx` environment key.
    @Environment(\.boardTrackPx) private var trackPx

    private var left: Double { BoardGeometry.toPx(Double(trigger), trackPx: trackPx) }
    private var width: Double { max(0, BoardGeometry.toPx(Double(reset), trackPx: trackPx) - BoardGeometry.toPx(Double(trigger), trackPx: trackPx)) }

    var body: some View {
        Group {
            if ghost {
                BoardRoundedCorners(topLeft: 7, topRight: 7, bottomRight: 7, bottomLeft: 7)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .foregroundColor(CockpitTheme.accBd)
                    .opacity(0.5)
                    .frame(width: width, height: 30)
            } else {
                ZStack {
                    BoardRoundedCorners(
                        topLeft: squareLeft ? 0 : 7, topRight: squareRight ? 0 : 7,
                        bottomRight: squareRight ? 0 : 7, bottomLeft: squareLeft ? 0 : 7
                    )
                    .fill(LinearGradient(colors: [CockpitTheme.accA, CockpitTheme.accB], startPoint: .leading, endPoint: .trailing))
                    BoardRoundedCorners(
                        topLeft: squareLeft ? 0 : 7, topRight: squareRight ? 0 : 7,
                        bottomRight: squareRight ? 0 : 7, bottomLeft: squareLeft ? 0 : 7
                    )
                    .strokeBorder(CockpitTheme.accBd, lineWidth: 1)
                    Text("5:00")
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.4)
                        .foregroundColor(CockpitTheme.accTx)
                        .opacity(0.55)
                }
                .frame(width: width, height: 30)
                .overlay {
                    if dragging {
                        BoardRoundedCorners(topLeft: 7, topRight: 7, bottomRight: 7, bottomLeft: 7)
                            .strokeBorder(CockpitTheme.accBd, lineWidth: 1.5)
                    }
                }
                .shadow(
                    color: dragging ? CockpitTheme.shadowDrag[0].color : .clear,
                    radius: dragging ? CockpitTheme.shadowDrag[0].radius : 0,
                    x: 0, y: dragging ? CockpitTheme.shadowDrag[0].y : 0
                )
                .opacity(hovered && !dragging ? 0.94 : 1)
                .animation(.easeOut(duration: 0.15), value: dragging)
            }
        }
        .position(x: left + width / 2, y: 34 + 15)
    }
}

// MARK: - TimeChip (component grammar #2)

/// web/src/board/TimeChip.tsx — the Radix thumb: 20pt tall, radius 6, 6pt
/// meaning-dot + HH:MM at 11/600; selected = accent fill, white text, an
/// accent ring OUTSIDE the chip's own bounds (CSS `box-shadow`, not an inner
/// border — reproduced here as a padded stroked shape).
struct BoardTimeChip: View {
    let label: String
    let dot: BoardClassify.Dot
    var selected = false
    var removing = false

    private var dotColor: Color {
        switch dot {
        case .gray: return CockpitTheme.grayDot
        case .green: return CockpitTheme.ok
        case .amber: return CockpitTheme.warnRaw
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            // TimeChip.tsx: `removing ? "bg-white" : DOT_CLASS[dot]` and the
            // amber selected-ring's `rgba(255,255,255,.85)` are BOTH fixed
            // white in the web too — white-on-crit-fill and a white ring on
            // an amber dot are theme-independent contrast choices there, not
            // a missed token. Kept fixed to match.
            Circle()
                .fill(removing ? Color.white : dotColor)
                .frame(width: 6, height: 6)
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.85), lineWidth: selected && !removing && dot == .amber ? 1.5 : 0)
                )
            Text(label)
                .font(CockpitTheme.numeric(11, weight: .semibold))
        }
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(removing ? CockpitTheme.crit : (selected ? CockpitTheme.accent : CockpitTheme.chipBg))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(removing || selected ? Color.clear : CockpitTheme.chipBd, lineWidth: 1)
        )
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 8.5)
                    .strokeBorder(CockpitTheme.accent, lineWidth: 2.5)
                    .padding(-2.5)
            }
        }
        .foregroundColor(removing || selected ? .white : CockpitTheme.accTx)
        .cursor(.openHand)
    }
}

private extension View {
    /// `cursor-grab`/`active:cursor-grabbing` (TimeChip.tsx) — best-effort;
    /// AppKit has no "grabbing" system cursor distinct from open/closed hand
    /// beyond `NSCursor.closedHand`, not wired per-press here (a P2 cosmetic
    /// gap, not a feel parameter).
    func cursor(_ cursor: NSCursor) -> some View {
        onHover { inside in
            if inside { cursor.set() } else { NSCursor.arrow.set() }
        }
    }
}

// MARK: - NowLine

/// web/src/board/NowLine.tsx — red now-line + time bubble spanning every
/// lane, past-time wash to its left. Rendered ONCE by `BoardView` (not per
/// lane), absolutely positioned over the full lanes stack.
struct BoardNowLine: View {
    let nowMinutes: Int
    /// Axis height (30) + every lane's row height — the wash/line's total
    /// vertical extent.
    let totalHeight: Double

    /// F16: the board's live track width — see BoardGeometry.swift's
    /// `boardTrackPx` environment key.
    @Environment(\.boardTrackPx) private var trackPx

    private var left: Double { BoardGeometry.headerPx + BoardGeometry.toPx(Double(nowMinutes), trackPx: trackPx) }
    private var washWidth: Double { max(0, BoardGeometry.toPx(Double(nowMinutes), trackPx: trackPx)) }
    private var lineHeight: Double { max(0, totalHeight - 14) }
    private var washHeight: Double { max(0, totalHeight - 30) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(CockpitTheme.wash)
                .frame(width: washWidth, height: washHeight)
                .position(x: BoardGeometry.headerPx + washWidth / 2, y: 30 + washHeight / 2)

            Rectangle()
                .fill(CockpitTheme.crit.opacity(0.9))
                .frame(width: 1.5, height: lineHeight)
                .position(x: left, y: 14 + lineHeight / 2)

            Text(BoardSchedule.fmtHM(nowMinutes))
                .font(CockpitTheme.numeric(9.5, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 1)
                .background(Capsule().fill(CockpitTheme.critDeep))
                .fixedSize()
                .position(x: left, y: 8)
        }
        .frame(width: BoardGeometry.headerPx + trackPx, height: totalHeight, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

// MARK: - Axis

/// web/src/board/Axis.tsx — shared 24h axis: hour ticks, labels every 2h
/// (F16: every 4h once the live track drops under ~900pt, so the labels
/// never crowd together at the cockpit's minimum width), right cap
/// "24h · local". 0..22 only — the right cap IS the 24h marker.
struct BoardAxis: View {
    /// F16: the board's live track width — see BoardGeometry.swift's
    /// `boardTrackPx` environment key.
    @Environment(\.boardTrackPx) private var trackPx

    private var totalWidth: Double { BoardGeometry.headerPx + trackPx }
    /// F16: hour-label stride — thins from every 2h to every 4h once the
    /// TRACK itself (not header+track) is narrower than ~900pt.
    private var labelStrideHours: Int { trackPx < 900 ? 4 : 2 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(CockpitTheme.hair)
                .frame(width: totalWidth, height: 1)
                .position(x: totalWidth / 2, y: 29.5)

            ForEach(0...24, id: \.self) { h in
                Rectangle()
                    .fill(CockpitTheme.hair)
                    .frame(width: 1, height: 5)
                    .position(x: BoardGeometry.headerPx + BoardGeometry.toPx(Double(h * 60), trackPx: trackPx), y: 27.5)
            }
            ForEach(Array(stride(from: 0, to: 24, by: labelStrideHours)), id: \.self) { h in
                Text(String(format: "%02d", h))
                    .font(.system(size: 9.5))
                    .foregroundColor(CockpitTheme.ter)
                    .position(x: BoardGeometry.headerPx + BoardGeometry.toPx(Double(h * 60), trackPx: trackPx), y: 14)
            }
            Text("24h · local")
                .font(.system(size: 9.5))
                .foregroundColor(CockpitTheme.ter)
                .position(x: totalWidth - 34, y: 14)
        }
        .frame(width: totalWidth, height: 30, alignment: .topLeading)
    }
}

// MARK: - Hud (component grammar #5)

/// web/src/board/Hud.tsx — the dark pill streaming the live outcome while
/// dragging. Purely presentational: `BoardTrackView` owns the fade-in-only
/// opacity (see its header comment — the web itself never fades this out,
/// an inconsistency this port keeps for parity) and 1:1 positional tracking.
struct BoardHud: View {
    let reset: Int
    let trigger: Int
    let chained: Bool
    /// Track.tsx always passes a literal `"busy-risk"` warn string; kept as
    /// a parameter (not hardcoded) since it is one in Hud.tsx's own props.
    let warn: String?

    /// F16: the board's live track width — see BoardGeometry.swift's
    /// `boardTrackPx` environment key.
    @Environment(\.boardTrackPx) private var trackPx

    private var left: Double { BoardGeometry.toPx(Double(reset), trackPx: trackPx) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                Text(BoardSchedule.fmtHM(reset))
                    .font(.system(size: 11.5, weight: .bold))
                Text(" · nudge \(BoardSchedule.fmtHM(trigger)) · ")
                    .font(.system(size: 10.5))
                    .opacity(0.62)
                if chained {
                    Text("⛓︎ chained").font(.system(size: 10.5, weight: .semibold)).foregroundColor(CockpitTheme.ok)
                } else if let warn {
                    // Hud.tsx: `text-[#ffb340]` — a literal hex in the web
                    // source itself, not a theme.css var (theme.css's own
                    // --warnraw differs in both light/dark). Nothing to add
                    // to CockpitTheme: this hex has no token to receipt
                    // against on either side, so it stays a fixed literal
                    // here too, in lockstep with Hud.tsx.
                    Text("⚠︎ \(warn)").font(.system(size: 10.5, weight: .semibold)).foregroundColor(Color(red: 1, green: 0.702, blue: 0.251))
                }
            }
            .foregroundColor(CockpitTheme.hudTx)
            .padding(.horizontal, 11)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(CockpitTheme.hudBg)
                    // Hud.tsx: `border border-white/[0.14]` on `bg-hudbg` —
                    // hudBg (theme.css --hudbg) is a fixed dark pill in BOTH
                    // light and dark mode, so a fixed white hairline stays
                    // legible in both too. Matches the web exactly.
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                    .shadow(color: CockpitTheme.shadowHud[0].color, radius: CockpitTheme.shadowHud[0].radius, x: 0, y: CockpitTheme.shadowHud[0].y)
            )
            .fixedSize()
            .position(x: left, y: 13)

            Rectangle()
                .fill(CockpitTheme.accBd)
                .frame(width: 1.5, height: 9)
                .position(x: left, y: 29.5)
        }
        .allowsHitTesting(false)
    }
}
