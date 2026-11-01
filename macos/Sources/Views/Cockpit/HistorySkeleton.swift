import SwiftUI

/// History's first load, drawn as the cards it is about to fill: the same
/// grid, card chrome and rough shapes (the burn chart, the model bar, the
/// project rows, the rhythm grid, the value figure) in the track colour,
/// so the section keeps its size and the data lands where the eye already
/// is. Still, not shimmering: motion is for state changes only
/// (DESIGN-SYSTEM.md §Motion) — the swap to real cards is the one fade.
/// Shown only while nothing has ever loaded; later loads keep the last
/// cards up (CockpitViewModel keeps every range it has seen).
struct HistorySkeleton: View {
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                card(subWidth: 220) {
                    block(height: 150)
                }
                .gridCellColumns(2)
            }
            GridRow {
                card(subWidth: 200) {
                    VStack(alignment: .leading, spacing: 10) {
                        block(height: 22)
                        HStack(spacing: 16) {
                            bar(width: 64)
                            bar(width: 64)
                        }
                    }
                }
                card(subWidth: 150) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(Self.projectWidths.enumerated()), id: \.offset) { _, w in
                            HStack(spacing: 12) {
                                bar(width: 70)
                                GeometryReader { g in
                                    block(height: 16).frame(width: g.size.width * w)
                                }
                                .frame(height: 16)
                            }
                        }
                    }
                }
            }
            GridRow {
                card(subWidth: 260) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(0..<7, id: \.self) { _ in
                            HStack(spacing: 3) {
                                bar(width: 24)
                                ForEach(0..<24, id: \.self) { _ in
                                    block(height: 14)
                                }
                            }
                        }
                    }
                }
                card(subWidth: 220) {
                    VStack(alignment: .leading, spacing: 10) {
                        block(height: 30).frame(width: 130)
                        block(height: 10)
                        bar(width: 180)
                    }
                }
            }
        }
        .padding(16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading history")
    }

    /// Project bars, longest first, the way the real list reads.
    static let projectWidths: [CGFloat] = [0.9, 0.72, 0.45, 0.36, 0.2, 0.3]

    /// HistoryCard's chrome around a title bar, a caption bar and content.
    private func card<Content: View>(subWidth: CGFloat, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                bar(width: 84, height: 10)
                bar(width: subWidth, height: 8)
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(CockpitTheme.panel)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(CockpitTheme.hair, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func bar(width: CGFloat, height: CGFloat = 10) -> some View {
        RoundedRectangle(cornerRadius: height / 2)
            .fill(CockpitTheme.rail)
            .frame(width: width, height: height)
    }

    private func block(height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(CockpitTheme.rail)
            .frame(maxWidth: .infinity)
            .frame(height: height)
    }
}

#Preview("History skeleton") {
    HistorySkeleton()
        .frame(width: 900)
        .background(CockpitTheme.win)
}
