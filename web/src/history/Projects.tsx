import { useMemo, useState } from "react";
import type { AnalyticsCell } from "./analytics.ts";
import { groupByProject, type ProjectGroup } from "./aggregate.ts";
import { Card, QuietState, TooltipPill } from "./ChartKit.tsx";
import { formatTokens, formatUSD } from "./format.ts";

const TOP_N = 5;

export function topProjects(cells: AnalyticsCell[]): { rows: ProjectGroup[]; otherCount: number; otherTokens: number } {
  const groups = groupByProject(cells).sort((a, b) => b.tokens - a.tokens);
  const rows = groups.slice(0, TOP_N);
  const rest = groups.slice(TOP_N);
  const otherTokens = rest.reduce((s, g) => s + g.tokens, 0);
  return { rows, otherCount: rest.length, otherTokens };
}

export function ProjectsCard(props: { cells: AnalyticsCell[] }) {
  const [hover, setHover] = useState<string | null>(null);
  const { rows, otherCount, otherTokens } = useMemo(() => topProjects(props.cells), [props.cells]);
  const otherValue = useMemo(() => {
    // "other" has no single model to price against — approximate its value
    // at the range's blended $/token so the bar still carries a tooltip
    // figure; rows keep their own exact per-model value.
    const totalTokens = rows.reduce((s, r) => s + r.tokens, 0) + otherTokens;
    const totalValue = rows.reduce((s, r) => s + r.value, 0);
    return totalTokens > 0 ? (totalValue / totalTokens) * otherTokens : 0;
  }, [rows, otherTokens]);

  const all = otherCount > 0 ? [...rows, { project: `other (${otherCount})`, tokens: otherTokens, value: otherValue }] : rows;
  const total = all.reduce((s, r) => s + r.tokens, 0);

  if (all.length === 0) {
    return (
      <Card title="Projects" ariaLabel="Projects — no data in range">
        <QuietState message="No usage recorded in this range." />
      </Card>
    );
  }

  const max = Math.max(...all.map((r) => r.tokens));

  return (
    <Card
      title="Projects"
      subCaption="top 5 by tokens, this range"
      ariaLabel={`Top projects by tokens: ${all.map((r) => `${r.project} ${formatTokens(r.tokens)}`).join(", ")}`}
    >
      <div className="flex flex-col gap-2">
        {all.map((r) => {
          const widthPct = max > 0 ? (r.tokens / max) * 100 : 0;
          const share = total > 0 ? (r.tokens / total) * 100 : 0;
          return (
            <div key={r.project} className="flex items-center gap-2">
              <span className="w-[104px] shrink-0 truncate text-[11px] text-sec" title={r.project}>
                {r.project}
              </span>
              <div className="relative h-[16px] flex-1">
                <div
                  className="absolute inset-y-0 left-0 h-full rounded-r-[4px] bg-accent"
                  style={{ width: `${Math.max(widthPct, 1.5)}%` }}
                  onPointerEnter={() => setHover(r.project)}
                  onPointerLeave={() => setHover((h) => (h === r.project ? null : h))}
                  aria-hidden="true"
                  aria-label={`${r.project}: ${formatTokens(r.tokens)} tokens, ${Math.round(share)}% share`}
                />
                {hover === r.project && (
                  <TooltipPill xPct={Math.max(widthPct, 1.5)} yPct={0}>
                    <strong className="font-semibold">{r.project}</strong>{" "}
                    <span className="opacity-80">
                      · {formatTokens(r.tokens)} tok · {formatUSD(r.value)}
                    </span>
                  </TooltipPill>
                )}
              </div>
              <span className="w-[38px] shrink-0 text-right text-[10.5px] text-ter tabular-nums">
                {Math.round(share)}%
              </span>
            </div>
          );
        })}
      </div>
    </Card>
  );
}
