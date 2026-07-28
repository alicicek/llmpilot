import type { TokenCounts } from "./pricing.ts";

// Mirrors of GET /v1/analytics and GET /v1/history (internal/daemon API).
export interface AnalyticsCell {
  account_id: string; // "" = activity in the shared global config dir
  project: string;
  model: string;
  day: string; // YYYY-MM-DD
  messages: number;
  tokens: TokenCounts;
}

export interface Analytics {
  cells: AnalyticsCell[];
  /** 7 rows (Sunday=0) × 24 local hours of total tokens. */
  hour_weekday: number[][];
  files_total: number;
  files_parsed: number;
  files_reused: number;
  as_of: string;
}

export interface HistorySample {
  at: string;
  percent: number;
}

export async function fetchAnalytics(days: number): Promise<Analytics> {
  const res = await fetch(`/v1/analytics?days=${days}`);
  if (!res.ok) throw new Error(`analytics: HTTP ${res.status}`);
  const raw = (await res.json()) as Analytics;
  return {
    ...raw,
    cells: raw.cells ?? [],
    hour_weekday: raw.hour_weekday ?? Array.from({ length: 7 }, () => Array(24).fill(0) as number[]),
  };
}

export async function fetchHistory(accountID: string, kind: string, scope?: string): Promise<HistorySample[]> {
  const params = new URLSearchParams({ account_id: accountID, kind });
  if (scope) params.set("scope", scope);
  const res = await fetch(`/v1/history?${params}`);
  if (!res.ok) throw new Error(`history: HTTP ${res.status}`);
  const raw = (await res.json()) as { samples: HistorySample[] | null };
  return raw.samples ?? [];
}

// ---- deterministic chart fixtures (?fixtures=1) ----

function cell(
  account_id: string,
  project: string,
  model: string,
  day: string,
  outMTok: number,
): AnalyticsCell {
  const output = Math.round(outMTok * 1_000_000);
  return {
    account_id,
    project,
    model,
    day,
    messages: Math.max(1, Math.round(outMTok * 900)),
    tokens: {
      input: Math.round(output * 0.35),
      output,
      cache_creation: Math.round(output * 2.1),
      cache_read: Math.round(output * 14),
    },
  };
}

const DAYS = ["2026-07-04", "2026-07-05", "2026-07-06", "2026-07-07", "2026-07-08", "2026-07-09", "2026-07-10"];

export const fixtureAnalytics: Analytics = {
  as_of: "2026-07-10T14:31:00+01:00",
  files_total: 3706,
  files_parsed: 214,
  files_reused: 3492,
  hour_weekday: Array.from({ length: 7 }, (_, wd) =>
    Array.from({ length: 24 }, (_, h) => {
      const workday = wd >= 1 && wd <= 5 ? 1 : 0.35;
      const peak = Math.exp(-((h - 15) ** 2) / 18) + 0.55 * Math.exp(-((h - 22) ** 2) / 8);
      return Math.round(2_400_000 * workday * peak);
    }),
  ),
  cells: DAYS.flatMap((day, i) => [
    cell("alex", "llmpilot", "claude-fable-5", day, 2.1 + i * 0.4),
    cell("alex", "llmpilot", "claude-sonnet-5", day, 1.2 + i * 0.15),
    cell("alex", "atlas", "claude-opus-4-8", day, 0.8),
    cell("kai", "llmpilot", "claude-fable-5", day, 1.4 + i * 0.2),
    cell("kai", "fleet-research", "claude-opus-4-8", day, 0.9),
    cell("mira", "atlas", "claude-sonnet-5", day, 0.6),
    cell("mira", "atlas", "claude-haiku-4-5", day, 0.3),
    cell("", "scratch", "claude-sonnet-5", day, 0.15),
  ]),
};

export const fixtureBurnSamples: HistorySample[] = Array.from({ length: 20 }, (_, i) => ({
  // kai's current window: 11:05 → 14:30, 23% → 78%, accelerating.
  at: `2026-07-10T${String(11 + Math.floor((i * 10 + 5) / 60)).padStart(2, "0")}:${String((i * 10 + 5) % 60).padStart(2, "0")}:00+01:00`,
  percent: Math.round(23 + 55 * Math.pow(i / 19, 1.35)),
}));
