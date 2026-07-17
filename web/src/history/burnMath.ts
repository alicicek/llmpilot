import type { AnalyticsCell } from "./analytics.ts";
import { valueSummary } from "./aggregate.ts";

// Contract gap: AnalyticsCell carries only day-level granularity, no
// per-hour timestamps, so "hours with activity today" can't be read
// directly off today's cells. Approximated from the rhythm heatmap's row
// for today's weekday within the current fetch (nonzero-token hours) —
// honest given the data available, flagged in the build report.
export function hoursWithActivityToday(hourWeekday: number[][], todayDateStr: string): number {
  const weekday = new Date(`${todayDateStr}T00:00:00Z`).getUTCDay(); // 0 = Sun, matches hour_weekday row index
  const row = hourWeekday[weekday] ?? [];
  const hours = row.filter((v) => v > 0).length;
  return Math.max(1, hours);
}

export function hourlyRate(cellsToday: AnalyticsCell[], activityHours: number): number {
  const { total } = valueSummary(cellsToday);
  return activityHours > 0 ? total / activityHours : 0;
}
