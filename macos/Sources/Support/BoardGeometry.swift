import SwiftUI

/// Pure 1:1 port of web/src/board/geometry.ts — pixel geometry for the 24h
/// track, mirroring design/reference/schedule-mockup.html. Kept as a
/// single source of truth so every layer (axis, blocks, zones, HUD,
/// now-line) agrees on the same px-per-minute. Cross-stack parity is
/// pinned by testdata/golden-vectors/board-geometry.json (which pins the
/// 1160pt default `trackPx` below — the web's own TRACK_PX is still a
/// fixed constant; only the native side went fluid for F16).
///
/// F16 (fresh-user audit 2026-08-16): the web's fixed 1160pt track used to
/// be the ONLY width every layer read — at any cockpit width narrower than
/// headerPx+trackPx (1400pt) the day clipped with no visible hint. `toPx`
/// now takes the live track width as a parameter (defaulting to the old
/// 1160pt constant so every existing call site / golden-vector test keeps
/// working unchanged); board views instead read the LIVE width through the
/// `boardTrackPx` environment value below, threaded from a GeometryReader
/// at BoardView's root (see BoardView.swift, BoardTrackView.swift).
enum BoardGeometry {
    /// web/src/board/geometry.ts `TRACK_PX` — kept as the default width for
    /// callers that don't thread a live value (golden-vector tests,
    /// previews) and as the `boardTrackPx` environment default.
    static let trackPx: Double = 1160

    /// web/src/board/geometry.ts `HEADER_PX`.
    /// 240 → 296 (fresh-user audit 2026-08-16, F17): room for the full
    /// scoped-model label ("Fable") and "100% · resets Tue 13:00" without
    /// truncation. The fluid track (F16) absorbs the difference.
    static let headerPx: Double = 296

    /// web/src/board/geometry.ts `ROW_PX`.
    static let rowPx: Double = 116

    /// web/src/board/geometry.ts `PPM`, at the default 1160pt track width.
    static let ppm: Double = trackPx / Double(BoardSchedule.dayMin)

    /// The narrowest a track is ever allowed to lay out at — guards
    /// `trackWidth(forAvailable:)`/`ppm(forTrackPx:)` against a negative or
    /// zero track width (and the NaN/negative geometry that would follow)
    /// if the board's container is ever narrower than the header column
    /// itself. Well under the cockpit's own 1000pt minimum window width
    /// minus headerPx (760pt), so this floor is a safety net, not a size
    /// the board is expected to render at in practice.
    static let minTrackPx: Double = 200

    /// Live per-minute pixel density for a track of the given width. Falls
    /// back to 0 (not a crash, not NaN) for a non-finite or non-positive
    /// width — the fixed `ppm` above stays the 1160pt default other callers
    /// still rely on.
    static func ppm(forTrackPx trackPx: Double) -> Double {
        guard trackPx.isFinite, trackPx > 0 else { return 0 }
        return trackPx / Double(BoardSchedule.dayMin)
    }

    /// web/src/board/geometry.ts `toPx`. minutes -> track-local px, rounded
    /// to 1 decimal, matching the mockup. `trackPx` defaults to the fixed
    /// 1160pt constant so every pre-F16 call site (and the golden-vector
    /// test) is unaffected; F16 callers pass the board's live width.
    static func toPx(_ minutes: Double, trackPx: Double = BoardGeometry.trackPx) -> Double {
        (minutes * ppm(forTrackPx: trackPx) * 10).rounded() / 10
    }

    /// web/src/board/geometry.ts `toPct`. minutes -> percent of track
    /// width (for slider thumb positioning) — width-independent by
    /// definition, so this one never needed a live-width parameter.
    static func toPct(_ minutes: Double) -> Double {
        (minutes / Double(BoardSchedule.dayMin)) * 100
    }

    /// F16: derive the live track width from the board's own measured
    /// available width (a GeometryReader at BoardView's root) minus the
    /// fixed header column. Clamped to `minTrackPx` so a pathological
    /// resize — or a container briefly narrower than the header mid-layout
    /// — never derives non-positive or NaN geometry for `toPx`/`ppm`.
    static func trackWidth(forAvailable available: Double, headerPx: Double = BoardGeometry.headerPx) -> Double {
        guard available.isFinite else { return minTrackPx }
        return max(minTrackPx, available - headerPx)
    }
}

// MARK: - live track width, threaded via the environment

private struct BoardTrackWidthKey: EnvironmentKey {
    static let defaultValue: Double = BoardGeometry.trackPx
}

extension EnvironmentValues {
    /// F16: the board's LIVE track width, set once per render by
    /// BoardView's GeometryReader and read by every geometry-consuming
    /// board piece (BoardAxis, BoardNowLine, BoardTrackView,
    /// BoardChargeBlock, BoardHud) instead of the old fixed
    /// `BoardGeometry.trackPx` constant. `TrackDragModel` deliberately has
    /// no SwiftUI import (see its header comment), so it does NOT read this
    /// — `BoardTrackView` passes the same value into it explicitly as a
    /// `trackWidth:` argument, mirroring the existing ref-refresh pattern
    /// used for `floor`/`ticker`/`onMove`/`onDelete`/`onCreate`.
    var boardTrackPx: Double {
        get { self[BoardTrackWidthKey.self] }
        set { self[BoardTrackWidthKey.self] = newValue }
    }
}
