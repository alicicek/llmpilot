import { useMemo } from "react";
import type { AnalyticsCell } from "./analytics.ts";
import { groupByFamily } from "./aggregate.ts";
import { buildSegments } from "./ModelMix.tsx";
import { topProjects } from "./Projects.tsx";
import { formatTokens, formatUSD } from "./format.ts";

// The WCAG-clean twin of the model-mix and projects charts — every value a
// tooltip or direct label shows above is also reachable here without
// hovering. dataviz anti-pattern: "no table view / color-only encoding on a
// continuous scale."
export function TableView(props: { cells: AnalyticsCell[] }) {
  const segments = useMemo(() => buildSegments(groupByFamily(props.cells)), [props.cells]);
  const totalTok = segments.reduce((s, g) => s + g.tokens, 0);
  const { rows, otherCount, otherTokens } = useMemo(() => topProjects(props.cells), [props.cells]);

  return (
    <details className="px-4 pb-4">
      <summary className="cursor-pointer text-[10.5px] text-ter hover:text-sec">as table</summary>
      <div className="mt-2 flex flex-col gap-4">
        <table className="w-full border-collapse text-[11px]">
          <caption className="mb-1 text-left text-[10px] font-semibold text-sec">Model mix</caption>
          <thead>
            <tr className="border-b border-hairsoft text-left text-ter">
              <th className="py-1 font-medium">Model</th>
              <th className="py-1 text-right font-medium">Tokens</th>
              <th className="py-1 text-right font-medium">Share</th>
              <th className="py-1 text-right font-medium">Value</th>
            </tr>
          </thead>
          <tbody>
            {segments.map((s) => (
              <tr key={s.family} className="border-b border-hairsoft last:border-b-0">
                <td className="py-1">
                  {s.family}
                  {s.unpricedIds.size > 0 && (
                    <span className="text-ter"> ({[...s.unpricedIds].join(", ")})</span>
                  )}
                </td>
                <td className="py-1 text-right tabular-nums">{formatTokens(s.tokens)}</td>
                <td className="py-1 text-right tabular-nums">
                  {totalTok > 0 ? Math.round((s.tokens / totalTok) * 100) : 0}%
                </td>
                <td className="py-1 text-right tabular-nums">{formatUSD(s.value)}</td>
              </tr>
            ))}
          </tbody>
        </table>
        <table className="w-full border-collapse text-[11px]">
          <caption className="mb-1 text-left text-[10px] font-semibold text-sec">Projects</caption>
          <thead>
            <tr className="border-b border-hairsoft text-left text-ter">
              <th className="py-1 font-medium">Project</th>
              <th className="py-1 text-right font-medium">Tokens</th>
              <th className="py-1 text-right font-medium">Value</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r) => (
              <tr key={r.project} className="border-b border-hairsoft last:border-b-0">
                <td className="py-1">{r.project}</td>
                <td className="py-1 text-right tabular-nums">{formatTokens(r.tokens)}</td>
                <td className="py-1 text-right tabular-nums">{formatUSD(r.value)}</td>
              </tr>
            ))}
            {otherCount > 0 && (
              <tr>
                <td className="py-1">other ({otherCount})</td>
                <td className="py-1 text-right tabular-nums">{formatTokens(otherTokens)}</td>
                <td className="py-1 text-right tabular-nums">—</td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </details>
  );
}
