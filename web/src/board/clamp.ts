// Pure spacing-clamp physics for one lane's reset-time thumbs — ported 1:1
// from design/llmpilot-scheduler-radix.html's clamp() (the interaction
// contract), generalized from a 0..24h float scale to 0..1439 minutes.
// Clamping happens here, in the caller's onValueChange, never via Radix's
// own minStepsBetweenThumbs (which clamps before this runs and kills the
// flash physics — the contract's explicit warning).
import { DAY_MIN, MIN_GAP_MIN, SNAP_MIN } from "../schedule.ts";

export interface ClampOutcome {
  /** the corrected values array (only the moved index differs from `next`). */
  values: number[];
  index: number;
  hitWall: boolean;
  /** forbidden zone to flash amber, if the move hit a wall. */
  flashZone: [number, number] | null;
}

/**
 * Given the previous committed values and Radix's proposed `next`, find the
 * one thumb that moved and clamp it to [floor, neighbors ± MIN_GAP_MIN],
 * circular across the midnight seam between the first and last thumb.
 */
export function clampMove(prev: number[], next: number[], floor: number): ClampOutcome | null {
  let i = -1;
  for (let k = 0; k < next.length; k++) {
    if (next[k] !== prev[k]) {
      i = k;
      break;
    }
  }
  if (i === -1) return null;

  const n = next.length;
  let v = next[i]!;
  let lo = Math.max(floor, i > 0 ? next[i - 1]! + MIN_GAP_MIN : 0);
  let hi = Math.min(DAY_MIN - SNAP_MIN, i < n - 1 ? next[i + 1]! - MIN_GAP_MIN : DAY_MIN);
  if (n >= 2) {
    if (i === 0) lo = Math.max(lo, next[n - 1]! - (DAY_MIN - MIN_GAP_MIN));
    if (i === n - 1) hi = Math.min(hi, next[0]! + (DAY_MIN - MIN_GAP_MIN));
  }

  let hitWall = false;
  let flashZone: [number, number] | null = null;
  if (v < lo) {
    flashZone = [i > 0 ? next[i - 1]! : Math.max(0, lo - MIN_GAP_MIN), lo];
    if (v !== lo) hitWall = true;
    v = lo;
  } else if (v > hi) {
    flashZone = [hi, i < n - 1 ? next[i + 1]! : Math.min(DAY_MIN, hi + MIN_GAP_MIN)];
    if (v !== hi) hitWall = true;
    v = hi;
  }

  const values = [...next];
  values[i] = v;
  return { values, index: i, hitWall, flashZone };
}

/** Can a new reset be booked at `t` given the lane's existing resets + floor? */
export function canBookAt(t: number, existing: number[], floor: number): [number, number] | null {
  if (t < floor) return [0, floor];
  for (const v of existing) {
    const d = Math.abs(v - t) % DAY_MIN;
    const gap = Math.min(d, DAY_MIN - d);
    if (gap < MIN_GAP_MIN) return [Math.max(0, v - MIN_GAP_MIN), Math.min(DAY_MIN, v + MIN_GAP_MIN)];
  }
  return null;
}
