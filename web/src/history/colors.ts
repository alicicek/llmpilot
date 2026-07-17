import { useEffect, useState } from "react";

// Series colors for the History charts — the ONLY raw hex allowed in this
// directory (dataviz spec: pre-validated ordinal ramp, six-checks already
// run offline; do not re-derive or eyeball). Everything else (chrome, text,
// status) rides theme.css tokens.
//
// Assignment is fixed by prominence rank, not data size: Fable always gets
// the strongest-contrast step for the current mode, then Opus, Sonnet,
// Haiku. Color follows the entity — a filter that drops a family never
// repaints the survivors, because the rank -> step mapping never depends on
// what's present in the current slice.
const MODEL_RAMP_LIGHT = ["#083a80", "#0a6ae0", "#4a90ee", "#82b3ea"] as const;
const MODEL_RAMP_DARK = ["#0a5bbf", "#3d8ef7", "#7ab8ff", "#b8d9ff"] as const;

export const FAMILY_ORDER = ["Fable", "Opus", "Sonnet", "Haiku"] as const;
export type KnownFamily = (typeof FAMILY_ORDER)[number];
export const OTHER_FAMILY = "Other";

// Model id -> canonical family. Anything that doesn't match a known family
// keeps its verbatim id (bucket-agnostic rule) and folds into the "Other"
// color slot on the chart — its own id still surfaces in the tooltip and
// the table-view fallback, never silently dropped.
export function familyOf(modelID: string): string {
  const id = modelID.toLowerCase();
  if (id.includes("fable")) return "Fable";
  if (id.includes("opus")) return "Opus";
  if (id.includes("sonnet")) return "Sonnet";
  if (id.includes("haiku")) return "Haiku";
  return modelID;
}

export function colorForFamily(family: string, dark: boolean): string {
  const i = FAMILY_ORDER.indexOf(family as KnownFamily);
  if (i === -1) return "var(--graydot)"; // Other — reserved gray, never a generated hue
  return dark ? MODEL_RAMP_DARK[3 - i] : MODEL_RAMP_LIGHT[i];
}

// On-fill text — marks-and-anatomy's one exception to "text wears text
// tokens": a label set *inside* a colored fill picks white or ink by the
// fill's own luminance, fixed regardless of page mode (page-mode --text
// would pick near-white text for a pale fill in dark mode, e.g. Fable's
// lightest step, and read invisible). Not a series color — a legibility
// anchor, pinned to the app's own light-mode ink value so it never drifts
// into a new hue.
const ON_FILL_INK = "#1d1d1f";
const ON_FILL_WHITE = "#ffffff";
// Per-ramp-index decision (index = the position actually used in
// MODEL_RAMP_LIGHT/DARK, matching colorForFamily's own indexing), computed
// against WCAG relative luminance for the fixed six-hex set.
const TEXT_ON_LIGHT_RAMP = [ON_FILL_WHITE, ON_FILL_WHITE, ON_FILL_INK, ON_FILL_INK];
const TEXT_ON_DARK_RAMP = [ON_FILL_WHITE, ON_FILL_INK, ON_FILL_INK, ON_FILL_INK];

export function textOnFamilyFill(family: string, dark: boolean): string {
  const i = FAMILY_ORDER.indexOf(family as KnownFamily);
  if (i === -1) return dark ? ON_FILL_WHITE : ON_FILL_INK; // Other / graydot
  return dark ? TEXT_ON_DARK_RAMP[3 - i] : TEXT_ON_LIGHT_RAMP[i];
}

// Sequential ramp for the rhythm heatmap — the same four hex steps reused as
// a one-hue magnitude scale (near-surface -> strongest), per the dataviz
// "interpolate the same ramp" instruction rather than a second, separate one.
function hexToRgb(hex: string): [number, number, number] {
  const n = parseInt(hex.slice(1), 16);
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
}

function rgbToHex(r: number, g: number, b: number): string {
  const c = (v: number) => Math.round(Math.max(0, Math.min(255, v))).toString(16).padStart(2, "0");
  return `#${c(r)}${c(g)}${c(b)}`;
}

function interpolateStops(stops: readonly string[], t: number): string {
  const clamped = Math.max(0, Math.min(1, t));
  const scaled = clamped * (stops.length - 1);
  const i = Math.floor(scaled);
  const frac = scaled - i;
  if (i >= stops.length - 1) return stops[stops.length - 1];
  const [r1, g1, b1] = hexToRgb(stops[i]);
  const [r2, g2, b2] = hexToRgb(stops[i + 1]);
  return rgbToHex(r1 + (r2 - r1) * frac, g1 + (g2 - g1) * frac, b1 + (b2 - b1) * frac);
}

// t in [0,1]: 0 = near-zero (recedes toward the surface), 1 = strongest step.
export function sequentialColor(t: number, dark: boolean): string {
  const stops = dark ? MODEL_RAMP_DARK : ([...MODEL_RAMP_LIGHT].reverse() as string[]);
  return interpolateStops(stops, t);
}

export function useIsDark(): boolean {
  const [dark, setDark] = useState(
    () => typeof matchMedia !== "undefined" && matchMedia("(prefers-color-scheme: dark)").matches,
  );
  useEffect(() => {
    if (typeof matchMedia === "undefined") return;
    const mql = matchMedia("(prefers-color-scheme: dark)");
    const onChange = () => setDark(mql.matches);
    mql.addEventListener("change", onChange);
    return () => mql.removeEventListener("change", onChange);
  }, []);
  return dark;
}
