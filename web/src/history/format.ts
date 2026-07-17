// Formatting helpers for the History charts — VOICE.md mechanics: digits
// always, ≈ for estimates never fake precision, HH:MM 24-hour times.

export function formatTokens(n: number): string {
  const abs = Math.abs(n);
  if (abs >= 1_000_000) return `${(n / 1_000_000).toFixed(abs >= 10_000_000 ? 0 : 1)}M`;
  if (abs >= 1_000) return `${(n / 1_000).toFixed(abs >= 10_000 ? 0 : 1)}K`;
  return Math.round(n).toLocaleString("en-US");
}

export function formatUSD(n: number, approx = true): string {
  const v = Math.abs(n) >= 1000 ? Math.round(n).toLocaleString("en-US") : n.toFixed(n >= 100 ? 0 : 2);
  return `${approx ? "≈ " : ""}$${v}`;
}

export function formatPercent(n: number): string {
  return `${Math.round(n)}%`;
}

// Every ISO string in this app carries an explicit numeric offset
// ("+01:00") that is the wall-clock the copy should show — never the
// browser's own timezone. Extract HH:MM directly from the string when
// possible; fall back to computing from an epoch + a known offset for
// derived (projected) timestamps.
export function hhmm(iso: string): string {
  const m = /T(\d{2}):(\d{2})/.exec(iso);
  return m ? `${m[1]}:${m[2]}` : "";
}

export function isoOffsetMinutes(iso: string): number {
  const m = /([+-])(\d{2}):(\d{2})$/.exec(iso);
  if (!m) return 0;
  const sign = m[1] === "-" ? -1 : 1;
  return sign * (parseInt(m[2], 10) * 60 + parseInt(m[3], 10));
}

export function hhmmAtEpoch(epochMs: number, offsetMinutes: number): string {
  const d = new Date(epochMs + offsetMinutes * 60_000);
  const hh = String(d.getUTCHours()).padStart(2, "0");
  const mm = String(d.getUTCMinutes()).padStart(2, "0");
  return `${hh}:${mm}`;
}

// Date-only ("2026-07-10") from an ISO string with offset — the fixed
// reference point range filters count backward from.
export function dateOnly(iso: string): string {
  return iso.slice(0, 10);
}

export function addDays(dateStr: string, days: number): string {
  const d = new Date(`${dateStr}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + days);
  return d.toISOString().slice(0, 10);
}

export const RANGE_DAYS = { today: 1, "7d": 7, "30d": 30, "1y": 365 } as const;
export type Range = keyof typeof RANGE_DAYS;

export function rangeLabel(range: Range): string {
  switch (range) {
    case "today":
      return "today";
    case "7d":
      return "last 7 days";
    case "30d":
      return "last 30 days";
    case "1y":
      return "last 12 months";
  }
}

// The delight footer's scope word, echoing the active range.
export function rangeScopeWord(range: Range): string {
  switch (range) {
    case "today":
      return "today";
    case "7d":
      return "this week";
    case "30d":
      return "this month";
    case "1y":
      return "this year";
  }
}

export const WEEKDAY_LABELS_MON_FIRST = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
