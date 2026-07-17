import SwiftUI
import AppKit

/// The collapsed menu-bar icon. Modes per the demand-mined anchor
/// (ClaudeUsageBar #43): ring gauge (default) · compact % · tiny runway
/// bars · icon only.
struct MenuBarLabel: View {
    @ObservedObject var model: FleetViewModel

    var body: some View {
        let gauge = model.iconGauge
        // Drain on down AND on stale — the icon must not wear meaning
        // colors the daemon can't vouch for (pack material rule 5).
        let down = model.status != .live || model.staleLabel != nil
        switch model.iconMode {
        case .ring:
            Image(nsImage: StatusIcon.ring(session: gauge.session, weekly: gauge.weekly, drained: down))
        case .percent:
            Text(gauge.session.map { "\($0)%" } ?? "—")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
        case .bars:
            Image(nsImage: StatusIcon.bars(session: gauge.session, weekly: gauge.weekly, drained: down))
        case .iconOnly:
            Image(systemName: "speedometer")
        }
    }
}

enum StatusIcon {
    /// Outer ring = 5h session, inner ring = worst weekly. Severity-colored;
    /// drained gray when the daemon can't vouch for the numbers.
    static func ring(session: Int?, weekly: Int?, drained: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: false) { _ in
            let center = NSPoint(x: 9, y: 9)
            drawRing(center: center, radius: 7, lineWidth: 2.4,
                     percent: session, drained: drained)
            drawRing(center: center, radius: 3.4, lineWidth: 2.0,
                     percent: weekly, drained: drained)
            return true
        }
        img.isTemplate = false
        return img
    }

    static func bars(session: Int?, weekly: Int?, drained: Bool) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let img = NSImage(size: size, flipped: false) { _ in
            drawBar(y: 9, percent: session, drained: drained)
            drawBar(y: 4, percent: weekly, drained: drained)
            return true
        }
        img.isTemplate = false
        return img
    }

    private static func drawRing(center: NSPoint, radius: CGFloat,
                                 lineWidth: CGFloat, percent: Int?, drained: Bool) {
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius,
                        startAngle: 0, endAngle: 360)
        track.lineWidth = lineWidth
        NSColor.tertiaryLabelColor.withAlphaComponent(0.35).setStroke()
        track.stroke()

        guard let percent, percent > 0 else { return }
        let p = min(percent, 100)
        // Start at 12 o'clock (90°), sweep clockwise.
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius,
                      startAngle: 90, endAngle: 90 - CGFloat(p) * 3.6,
                      clockwise: true)
        arc.lineWidth = lineWidth
        arc.lineCapStyle = .round
        (drained ? NSColor.tertiaryLabelColor : Theme.severityNS(Double(percent))).setStroke()
        arc.stroke()
    }

    private static func drawBar(y: CGFloat, percent: Int?, drained: Bool) {
        let track = NSBezierPath(roundedRect: NSRect(x: 1, y: y, width: 14, height: 3),
                                 xRadius: 1.5, yRadius: 1.5)
        NSColor.tertiaryLabelColor.withAlphaComponent(0.35).setFill()
        track.fill()
        guard let percent, percent > 0 else { return }
        let w = max(2, 14 * CGFloat(min(percent, 100)) / 100)
        let fill = NSBezierPath(roundedRect: NSRect(x: 1, y: y, width: w, height: 3),
                                xRadius: 1.5, yRadius: 1.5)
        (drained ? NSColor.tertiaryLabelColor : Theme.severityNS(Double(percent))).setFill()
        fill.fill()
    }
}
