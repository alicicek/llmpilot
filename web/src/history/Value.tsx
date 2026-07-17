import { useMemo } from "react";
import type { AnalyticsCell } from "./analytics.ts";
import type { Config } from "../api.ts";
import { valueSummary } from "./aggregate.ts";
import { Card } from "./ChartKit.tsx";
import { formatUSD, RANGE_DAYS, type Range } from "./format.ts";

export function ValueCard(props: {
  cells: AnalyticsCell[];
  range: Range;
  fixturesMode: boolean;
  config: Config | null;
  selectedAccountIds: string[]; // real account ids only, "" (shared) excluded
}) {
  const { total, unpricedIds } = useMemo(() => valueSummary(props.cells), [props.cells]);
  const prorate = RANGE_DAYS[props.range] / 30;

  const planCost = useMemo(() => {
    if (props.fixturesMode) return props.selectedAccountIds.length * 200 * prorate;
    const perAccount = props.config?.plan_cost_monthly ?? {};
    return props.selectedAccountIds.reduce((sum, id) => sum + (perAccount[id] ?? 0), 0) * prorate;
  }, [props.fixturesMode, props.config, props.selectedAccountIds, prorate]);

  const ratio = planCost > 0 ? total / planCost : null;
  const barMax = Math.max(total, planCost, 1) * 1.15;
  const pulledPct = (total / barMax) * 100;
  const planPct = (planCost / barMax) * 100;

  const captionSuffix = ratio !== null ? ` · ${ratio.toFixed(1)}×` : "";
  const caption = `${formatUSD(total)} pulled vs ${formatUSD(planCost)} plan spend${captionSuffix}`;

  return (
    <Card
      title="Value extracted"
      subCaption="API-equivalent value vs plan cost, this range"
      ariaLabel={`Value extracted: ${caption}`}
    >
      <div className="text-[32px] font-semibold text-text">{formatUSD(total)}</div>
      {unpricedIds.size > 0 && (
        <p className="mt-0.5 text-[10px] text-ter">excl. {unpricedIds.size} unpriced models</p>
      )}
      <div className="relative mt-3 h-[10px] rounded-[4px] bg-rail">
        <div
          className="absolute inset-y-0 left-0 rounded-[4px] bg-accent"
          style={{ width: `${Math.min(100, pulledPct)}%` }}
        />
        <div
          className="absolute top-[-3px] h-[16px] w-[2px] bg-text"
          style={{ left: `${Math.min(100, planPct)}%` }}
          aria-hidden
        />
      </div>
      <p className="mt-2 text-[11px] text-sec">{caption}</p>
    </Card>
  );
}
