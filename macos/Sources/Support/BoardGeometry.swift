import Foundation

/// Pure 1:1 port of web/src/board/geometry.ts — pixel geometry for the 24h
/// track, mirroring design/reference/schedule-mockup.html. Kept as a
/// single source of truth so every layer (axis, blocks, zones, HUD,
/// now-line) agrees on the same px-per-minute. Cross-stack parity is
/// pinned by testdata/golden-vectors/board-geometry.json.
enum BoardGeometry {
    /// web/src/board/geometry.ts `TRACK_PX`.
    static let trackPx: Double = 1160

    /// web/src/board/geometry.ts `HEADER_PX`.
    static let headerPx: Double = 240

    /// web/src/board/geometry.ts `ROW_PX`.
    static let rowPx: Double = 116

    /// web/src/board/geometry.ts `PPM`.
    static let ppm: Double = trackPx / Double(BoardSchedule.dayMin)

    /// web/src/board/geometry.ts `toPx`. minutes -> track-local px,
    /// rounded to 1 decimal, matching the mockup.
    static func toPx(_ minutes: Double) -> Double {
        (minutes * ppm * 10).rounded() / 10
    }

    /// web/src/board/geometry.ts `toPct`. minutes -> percent of track
    /// width (for slider thumb positioning).
    static func toPct(_ minutes: Double) -> Double {
        (minutes / Double(BoardSchedule.dayMin)) * 100
    }
}
