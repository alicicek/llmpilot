import { valueOf, type TokenCounts } from "./pricing.ts";
import type { AnalyticsCell } from "./analytics.ts";
import { familyOf } from "./colors.ts";

export function totalTokens(t: TokenCounts): number {
  return t.input + t.output + t.cache_creation + t.cache_read;
}

export function ioTokens(t: TokenCounts): number {
  return t.input + t.output;
}

export interface ValueSummary {
  total: number;
  unpricedIds: Set<string>;
}

// Sum of API-equivalent dollars across cells; models with no price entry are
// excluded from the total and named honestly rather than silently priced.
export function valueSummary(cells: AnalyticsCell[]): ValueSummary {
  let total = 0;
  const unpricedIds = new Set<string>();
  for (const c of cells) {
    const v = valueOf(c.model, c.tokens);
    if (v === null) unpricedIds.add(c.model);
    else total += v;
  }
  return { total, unpricedIds };
}

export interface FamilyGroup {
  family: string;
  tokens: number; // input + output, per the model-mix contract
  value: number;
  unpricedIds: Set<string>;
}

export function groupByFamily(cells: AnalyticsCell[]): FamilyGroup[] {
  const byFamily = new Map<string, FamilyGroup>();
  for (const c of cells) {
    const family = familyOf(c.model);
    let g = byFamily.get(family);
    if (!g) {
      g = { family, tokens: 0, value: 0, unpricedIds: new Set() };
      byFamily.set(family, g);
    }
    g.tokens += ioTokens(c.tokens);
    const v = valueOf(c.model, c.tokens);
    if (v === null) g.unpricedIds.add(c.model);
    else g.value += v;
  }
  return [...byFamily.values()];
}

export interface ProjectGroup {
  project: string;
  tokens: number;
  value: number;
}

export function groupByProject(cells: AnalyticsCell[]): ProjectGroup[] {
  const byProject = new Map<string, ProjectGroup>();
  for (const c of cells) {
    let g = byProject.get(c.project);
    if (!g) {
      g = { project: c.project, tokens: 0, value: 0 };
      byProject.set(c.project, g);
    }
    g.tokens += totalTokens(c.tokens);
    const v = valueOf(c.model, c.tokens);
    if (v !== null) g.value += v;
  }
  return [...byProject.values()];
}
