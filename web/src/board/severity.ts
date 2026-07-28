// Runway-bar labeling, severity coloring, and the stale-snapshot rule
// (pack rule 5: stale is drained + stamped, never color-judged).
import type { Bucket } from "../api.ts";
import { DAY_MIN } from "../schedule.ts";

export function bucketLabel(b: Bucket): string {
  if (b.kind === "session") return "5h";
  if (b.kind === "weekly_all") return "wk";
  if (b.kind === "weekly_scoped") return (b.scope?.[0] ?? "?").toUpperCase();
  return b.kind;
}

export type Severity = "calm" | "warn" | "crit";

/** The doctor's finding severities ride the SAME shipped trio — the panel
 *  invents no hue of its own, reusing the shipped severity vocabulary
 *  instead. An informational finding is calm on purpose: a watched lane
 *  is a feature, not a fault. */
export function findingSeverity(s: "critical" | "warning" | "info"): Severity {
  if (s === "critical") return "crit";
  if (s === "warning") return "warn";
  return "calm";
}

export function bucketSeverity(b: Bucket): Severity {
  if (b.severity === "critical") return "crit";
  if (b.severity === "warning") return "warn";
  if (b.percent >= 90) return "crit";
  if (b.percent >= 70) return "warn";
  return "calm";
}

export function minutesOfDay(iso: string): number {
  const d = new Date(iso);
  return d.getHours() * 60 + d.getMinutes();
}

/** minutes between an ISO instant's time-of-day and nowMinutes (same-day, wraps). */
export function minutesAgo(iso: string, nowMinutes: number): number {
  const d = new Date(iso);
  const asOf = d.getHours() * 60 + d.getMinutes();
  const diff = nowMinutes - asOf;
  return diff < 0 ? diff + DAY_MIN : diff;
}

/** minutes from nowMinutes forward to an ISO instant's time-of-day (same-day, wraps). */
export function minutesUntil(iso: string, nowMinutes: number): number {
  const d = new Date(iso);
  const at = d.getHours() * 60 + d.getMinutes();
  const diff = at - nowMinutes;
  return diff < 0 ? diff + DAY_MIN : diff;
}

export function fmtDurationLeft(minutes: number): string {
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  return `${h}:${String(m).padStart(2, "0")} left`;
}

export const STALE_AFTER_MIN = 10;

export function isStale(asOf: string, nowMinutes: number): boolean {
  return minutesAgo(asOf, nowMinutes) > STALE_AFTER_MIN;
}

export function staleStamp(asOf: string, nowMinutes: number): string {
  const mins = minutesAgo(asOf, nowMinutes);
  if (mins < 60) return `as of ${mins}m ago`;
  return `as of ${Math.round(mins / 60)}h ago`;
}

/** whether an ISO instant falls on the same calendar day as `refIso`. */
export function isSameDay(iso: string, refIso: string): boolean {
  return iso.slice(0, 10) === refIso.slice(0, 10);
}

export function fmtHMFromIso(iso: string): string {
  const d = new Date(iso);
  return `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
}

export function fmtDowFromIso(iso: string): string {
  return new Date(iso).toLocaleDateString("en-US", { weekday: "short" });
}
