import Foundation

/// Pure 1:1 port of web/src/board/clamp.ts — the spacing-clamp physics for
/// one lane's reset-time thumbs, ported from
/// design/llmpilot-scheduler-radix.html's clamp() (the interaction
/// contract), generalized from a 0..24h float scale to 0..1439 minutes.
/// Clamping happens here, in the gesture layer's onValueChange, never via
/// any native slider's own min-distance-between-thumbs feature (which would
/// clamp before this runs and kill the flash physics — the contract's
/// explicit warning, preserved from the web source's own comment). Cross-
/// stack parity is pinned by testdata/golden-vectors/board-clamp.json.
enum BoardClamp {
    /// web/src/board/clamp.ts `ClampOutcome`.
    struct ClampOutcome: Equatable {
        /// the corrected values array (only `index` differs from the
        /// caller's proposed `next`).
        let values: [Int]
        let index: Int
        let hitWall: Bool
        /// forbidden zone to flash amber, if the move hit a wall.
        let flashZone: (Int, Int)?

        static func == (lhs: ClampOutcome, rhs: ClampOutcome) -> Bool {
            lhs.values == rhs.values && lhs.index == rhs.index && lhs.hitWall == rhs.hitWall
                && lhs.flashZone?.0 == rhs.flashZone?.0 && lhs.flashZone?.1 == rhs.flashZone?.1
                && (lhs.flashZone == nil) == (rhs.flashZone == nil)
        }
    }

    /// web/src/board/clamp.ts `clampMove`. Given the previous committed
    /// values and the gesture layer's proposed `next`, find the ONE thumb
    /// that moved (first index where `next` differs from `prev`; nil, i.e.
    /// no-op, when none differs) and clamp it to
    /// `[floor, neighbors ± minGapMin]`, circular across the midnight seam
    /// between the first and last thumb when `n >= 2`.
    static func clampMove(prev: [Int], next: [Int], floor: Int) -> ClampOutcome? {
        var i = -1
        for k in 0..<next.count {
            if next[k] != prev[k] {
                i = k
                break
            }
        }
        if i == -1 { return nil }

        let n = next.count
        var v = next[i]
        var lo = max(floor, i > 0 ? next[i - 1] + BoardSchedule.minGapMin : 0)
        var hi = min(
            BoardSchedule.dayMin - BoardSchedule.snapMin,
            i < n - 1 ? next[i + 1] - BoardSchedule.minGapMin : BoardSchedule.dayMin
        )
        if n >= 2 {
            if i == 0 { lo = max(lo, next[n - 1] - (BoardSchedule.dayMin - BoardSchedule.minGapMin)) }
            if i == n - 1 { hi = min(hi, next[0] + (BoardSchedule.dayMin - BoardSchedule.minGapMin)) }
        }

        var hitWall = false
        var flashZone: (Int, Int)?
        if v < lo {
            flashZone = (i > 0 ? next[i - 1] : max(0, lo - BoardSchedule.minGapMin), lo)
            // hitWall ONLY when the raw proposed value strictly differs
            // from the clamped result — a proposal that already equals the
            // boundary is a silent clamp, not a wall hit.
            if v != lo { hitWall = true }
            v = lo
        } else if v > hi {
            flashZone = (hi, i < n - 1 ? next[i + 1] : min(BoardSchedule.dayMin, hi + BoardSchedule.minGapMin))
            if v != hi { hitWall = true }
            v = hi
        }

        var values = next
        values[i] = v
        return ClampOutcome(values: values, index: i, hitWall: hitWall, flashZone: flashZone)
    }

    /// web/src/board/clamp.ts `canBookAt`. Can a new reset be booked at `t`
    /// given the lane's existing resets + floor? Returns the forbidden zone
    /// `(lo, hi)` when `t` is illegal, nil when legal.
    static func canBookAt(_ t: Int, existing: [Int], floor: Int) -> (Int, Int)? {
        if t < floor { return (0, floor) }
        for v in existing {
            let d = abs(v - t) % BoardSchedule.dayMin
            let gap = min(d, BoardSchedule.dayMin - d)
            if gap < BoardSchedule.minGapMin {
                return (max(0, v - BoardSchedule.minGapMin), min(BoardSchedule.dayMin, v + BoardSchedule.minGapMin))
            }
        }
        return nil
    }
}
