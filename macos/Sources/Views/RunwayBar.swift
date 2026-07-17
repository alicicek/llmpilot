import SwiftUI

/// One bucket as the signature runway bar: label · % used · reset time.
/// Stale data drops its meaning color (pack material rule 5).
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
                    Capsule()
                        .fill(drained ? Theme.drained : Theme.severity(bucket.percent))
                        .frame(width: max(3, geo.size.width * CGFloat(min(bucket.percent, 100)) / 100))
                }
            }
            .frame(height: 4)
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
