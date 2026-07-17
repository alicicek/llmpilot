import { useMemo, useState } from "react";
import type { AnalyticsCell } from "./analytics.ts";
import { groupByFamily, type FamilyGroup } from "./aggregate.ts";
import { FAMILY_ORDER, OTHER_FAMILY, colorForFamily, textOnFamilyFill, type KnownFamily } from "./colors.ts";
import { Card, LegendRow, QuietState, TooltipPill } from "./ChartKit.tsx";
import { formatTokens, formatUSD } from "./format.ts";

interface Segment {
  family: string;
  tokens: number;
  value: number;
  unpricedIds: Set<string>;
}

// Known families always keep their own reserved slot (identity, not size);
// everything else folds into one "Other" segment — still bucket-agnostic,
// its constituent verbatim ids stay reachable via the table view.
function buildSegments(groups: FamilyGroup[]): Segment[] {
  const known = FAMILY_ORDER.map((f) => groups.find((g) => g.family === f)).filter(
    (g): g is FamilyGroup => !!g && g.tokens > 0,
  );
  const unknown = groups.filter((g) => !FAMILY_ORDER.includes(g.family as KnownFamily));
  const segments: Segment[] = known.map((g) => ({ ...g }));
  if (unknown.length > 0) {
    const other: Segment = { family: OTHER_FAMILY, tokens: 0, value: 0, unpricedIds: new Set() };
    for (const g of unknown) {
      other.tokens += g.tokens;
      other.value += g.value;
      g.unpricedIds.forEach((id) => other.unpricedIds.add(id));
    }
    if (other.tokens > 0) segments.push(other);
  }
  return segments;
}

export function ModelMixCard(props: { cells: AnalyticsCell[]; dark: boolean }) {
  const [hover, setHover] = useState<{ seg: Segment; midPct: number } | null>(null);
  const segments = useMemo(() => buildSegments(groupByFamily(props.cells)), [props.cells]);
  const total = segments.reduce((s, g) => s + g.tokens, 0);

  if (total === 0) {
    return (
      <Card title="Model mix" ariaLabel="Model mix — no data in range">
        <QuietState message="No usage recorded in this range." />
      </Card>
    );
  }

  let cum = 0;
  const withShare = segments.map((seg) => {
    const share = (seg.tokens / total) * 100;
    const mid = cum + share / 2;
    cum += share;
    return { seg, share, mid };
  });

  const ariaSummary = withShare
    .map((s) => `${s.seg.family} ${Math.round(s.share)}%`)
    .join(", ");

  return (
    <Card
      title="Model mix"
      subCaption="share of input + output tokens by model, Fable first"
      ariaLabel={`Model mix by token share: ${ariaSummary}`}
    >
      <div className="relative flex h-[22px] gap-[2px] overflow-hidden rounded-[4px]">
        {withShare.map(({ seg, share, mid }) => (
          <div
            key={seg.family}
            aria-hidden="true"
            aria-label={`${seg.family}: ${Math.round(share)}% — ${formatTokens(seg.tokens)} tokens`}
            className="flex items-center justify-center"
            style={{ flexGrow: seg.tokens, flexBasis: 0, backgroundColor: colorForFamily(seg.family, props.dark) }}
            onPointerEnter={() => setHover({ seg, midPct: mid })}
            onPointerLeave={() => setHover((h) => (h?.seg === seg ? null : h))}
          >
            {share >= 8 && (
              <span
                className="px-1 text-[10px] font-semibold tabular-nums"
                style={{ color: textOnFamilyFill(seg.family, props.dark) }}
              >
                {Math.round(share)}%
              </span>
            )}
          </div>
        ))}
        {hover && (
          <TooltipPill xPct={hover.midPct} yPct={0}>
            <strong className="font-semibold">{formatTokens(hover.seg.tokens)} tok</strong>{" "}
            <span className="opacity-80">
              {hover.seg.family} · {formatUSD(hover.seg.value)}
            </span>
          </TooltipPill>
        )}
      </div>
      <LegendRow
        entries={withShare.map(({ seg, share }) => ({
          label: seg.family,
          color: colorForFamily(seg.family, props.dark),
          share,
        }))}
      />
    </Card>
  );
}

export { buildSegments };
