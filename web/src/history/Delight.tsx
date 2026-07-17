import { useMemo } from "react";
import type { AnalyticsCell } from "./analytics.ts";
import { totalTokens } from "./aggregate.ts";
import { rangeScopeWord, type Range } from "./format.ts";

const HOBBIT_TOKENS = 125_000;

export function DelightFooter(props: { cells: AnalyticsCell[]; range: Range }) {
  const factor = useMemo(() => {
    const total = props.cells.reduce((s, c) => s + totalTokens(c.tokens), 0);
    return total / HOBBIT_TOKENS;
  }, [props.cells]);

  if (factor <= 0) return null;

  const factorStr = factor >= 100 ? Math.round(factor).toLocaleString("en-US") : factor.toFixed(1);

  return (
    <p className="px-4 pb-3 text-[10.5px] text-ter">
      ≈ {factorStr}× The Hobbit {rangeScopeWord(props.range)}
    </p>
  );
}
