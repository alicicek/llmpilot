import SwiftUI

/// One bucket as the signature runway bar: label · bar · ring · % used ·
/// reset time. Stale data drops its meaning color (pack material rule 5).
///
/// Two legibility guards for high fill (the 90%-reads-as-100% defect):
/// the track carries a terminus tick (the fill covers it only at a true
/// 100%), and a mini ring beside the number gives the angular headroom cue
/// — a 10% gap is 36° of arc, visible at a glance where a 13pt bar sliver
/// is not. Ring language mirrors the menu-bar icon (ClaudeUsageBar #43).
struct RunwayBar: View {
    let bucket: Bucket
    let now: Date
    var drained = false

    var body: some View {
        HStack(spacing: 8) {
            Text(bucket.shortLabel)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.rail)
                    // Terminus tick sits UNDER the fill, and only from warn
                    // up: that is where the fill's rounded end starts to
                    // pass for a full bar, so the tick marks the real end
                    // and the gap before it IS the headroom. On a near-empty
                    // track it would just be a speck with nothing to
                    // reference — it fades in when it earns its place.
                    Capsule()
                        .fill(Theme.railEnd)
                        .frame(width: 1.5)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .opacity(bucket.percent >= 70 ? 1 : 0)
                    Capsule()
                        .fill(drained ? Theme.drained : Theme.severity(bucket.percent))
                        .frame(width: max(3, geo.size.width * CGFloat(min(bucket.percent, 100)) / 100))
                }
            }
            .frame(height: 4)
            .animation(.easeOut(duration: 0.2), value: bucket.percent)
            RingGauge(percent: bucket.percent, drained: drained)
                .frame(width: 12, height: 12)
                .animation(.easeOut(duration: 0.2), value: bucket.percent)
            Text("\(bucket.percentInt)%")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .frame(width: 34, alignment: .trailing)
            Text(bucket.resetsAt.map { Format.resets($0, now: now) } ?? "")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 92, alignment: .leading)
                .lineLimit(1)
        }
    }
}

/// The popover's mini ring: same encoding as the menu-bar icon's
/// StatusIcon.ring (12 o'clock start, clockwise sweep, severity color,
/// drained gray when the daemon can't vouch for the number).
struct RingGauge: View {
    let percent: Double
    var drained = false

    var body: some View {
        ZStack {
            Circle().stroke(Theme.rail, lineWidth: 2.2)
            Circle()
                .trim(from: 0, to: CGFloat(min(percent, 100)) / 100)
                .stroke(
                    drained ? Theme.drained : Theme.severity(percent),
                    style: StrokeStyle(lineWidth: 2.2, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
        }
        .padding(1.1) // keep the stroke inside the frame
    }
}
