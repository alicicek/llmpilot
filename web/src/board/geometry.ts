// Pixel geometry for the 24h track — mirrors design/reference/schedule-mockup.html
// (mockup TRACK=812 scaled to 1160 per the selection-round judge: fill the
// window, don't strand a dead right third; HDR=208 unchanged). Kept as a
// single source of truth so every layer (axis, blocks, zones, HUD, now-line)
// agrees on the same px-per-minute.
import { DAY_MIN } from "../schedule.ts";

export const TRACK_PX = 1160;
// 240 (was the mockup's 208): at 208 the header column truncated its own
// default-length content — an active account's email + ACTIVE badge, and
// "Mid-window — resets HH:MM" — in every screenshot.
export const HEADER_PX = 240;
export const ROW_PX = 116;
export const PPM = TRACK_PX / DAY_MIN;

/** minutes -> track-local px (rounded to 1 decimal, matching the mockup). */
export function toPx(minutes: number): number {
  return Math.round(minutes * PPM * 10) / 10;
}

/** minutes -> percent of track width (for Radix Slider thumb positioning). */
export function toPct(minutes: number): number {
  return (minutes / DAY_MIN) * 100;
}
