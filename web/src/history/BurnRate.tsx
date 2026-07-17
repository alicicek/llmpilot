import { useMemo, useRef, useState } from "react";
import type { State } from "../api.ts";
import type { AnalyticsCell, Analytics, HistorySample } from "./analytics.ts";
import { hourlyRate, hoursWithActivityToday } from "./burnMath.ts";
import { Card, QuietState, TooltipPill } from "./ChartKit.tsx";
import { dateOnly, hhmm, hhmmAtEpoch, isoOffsetMinutes } from "./format.ts";

const W = 640;
const H = 150;
const PAD_L = 4;
const PAD_R = 4;
const PAD_T = 10;
const PAD_B = 22;

function activeBucket(state: State) {
  const acct = state.accounts.find((a) => a.id === state.active_id);
  return acct?.snapshot?.buckets.find(
    (b) => (b.kind === "session" || b.kind === "five_hour") && b.active && b.resets_at,
  );
}

// Linear fit over the last ~30 min of samples, extended to percent=100.
// Returns the projected epoch ms, or null when the trend isn't climbing
// (flat/decreasing burn has no meaningful "hit the wall" time).
function projectWallMs(samples: HistorySample[]): number | null {
  if (samples.length < 2) return null;
  const last = samples[samples.length - 1];
  const lastMs = Date.parse(last.at);
  const recent = samples.filter((s) => lastMs - Date.parse(s.at) <= 30 * 60_000);
  const pts = recent.length >= 2 ? recent : samples.slice(-2);
  const x0 = Date.parse(pts[0].at);
  const xs = pts.map((p) => (Date.parse(p.at) - x0) / 60_000);
  const ys = pts.map((p) => p.percent);
  const n = xs.length;
  const meanX = xs.reduce((a, b) => a + b, 0) / n;
  const meanY = ys.reduce((a, b) => a + b, 0) / n;
  let num = 0;
  let den = 0;
  for (let i = 0; i < n; i++) {
    num += (xs[i] - meanX) * (ys[i] - meanY);
    den += (xs[i] - meanX) ** 2;
  }
  const slope = den === 0 ? 0 : num / den;
  if (slope <= 0) return null;
  const intercept = meanY - slope * meanX;
  return x0 + ((100 - intercept) / slope) * 60_000;
}

export function BurnRateCard(props: {
  state: State;
  analytics: Analytics | null;
  samples: HistorySample[] | null;
  loading: boolean;
  error: string | null;
}) {
  const bucket = activeBucket(props.state);
  const activeAccount = props.state.accounts.find((a) => a.id === props.state.active_id);
  const samples = props.samples ?? [];
  const containerRef = useRef<HTMLDivElement>(null);
  const [hoverIdx, setHoverIdx] = useState<number | null>(null);

  const todayStr = dateOnly(props.state.as_of);
  const cellsToday: AnalyticsCell[] = useMemo(
    () => (props.analytics?.cells ?? []).filter((c) => c.account_id === props.state.active_id && c.day === todayStr),
    [props.analytics, props.state.active_id, todayStr],
  );
  const activityHours = props.analytics ? hoursWithActivityToday(props.analytics.hour_weekday, todayStr) : 1;
  const rate = hourlyRate(cellsToday, activityHours);
  const rateStr = `≈ $${rate < 10 ? rate.toFixed(1) : Math.round(rate)}/h`;

  const geometry = useMemo(() => {
    if (samples.length === 0 || !bucket?.resets_at) return null;
    const resetMs = Date.parse(bucket.resets_at);
    const projectedMs = projectWallMs(samples);
    const sampleMs = samples.map((s) => Date.parse(s.at));
    const xMin = sampleMs[0];
    const xMax = Math.max(sampleMs[sampleMs.length - 1], resetMs, projectedMs ?? -Infinity);
    const span = Math.max(1, xMax - xMin);
    const xScale = (ms: number) => PAD_L + ((ms - xMin) / span) * (W - PAD_L - PAD_R);
    const yScale = (pct: number) => H - PAD_B - (Math.min(100, pct) / 100) * (H - PAD_T - PAD_B);
    const baseline = H - PAD_B;
    const points = samples.map((s, i) => ({ x: xScale(sampleMs[i]), y: yScale(s.percent), s }));
    const linePath = points.map((p, i) => `${i === 0 ? "M" : "L"}${p.x.toFixed(1)},${p.y.toFixed(1)}`).join(" ");
    const areaPath = `${linePath} L${points[points.length - 1].x.toFixed(1)},${baseline} L${points[0].x.toFixed(1)},${baseline} Z`;
    const projectionPath =
      projectedMs !== null
        ? `M${points[points.length - 1].x.toFixed(1)},${points[points.length - 1].y.toFixed(1)} L${xScale(projectedMs).toFixed(1)},${yScale(100).toFixed(1)}`
        : null;
    const resetX = xScale(resetMs);
    return { points, linePath, areaPath, projectionPath, resetMs, projectedMs, resetX, baseline };
  }, [samples, bucket?.resets_at]);

  if (props.error) {
    return (
      <Card title="Burn rate" ariaLabel="Burn rate — unavailable" wide loading={props.loading}>
        <QuietState message="History unavailable — daemon too old or still indexing." />
      </Card>
    );
  }

  if (!bucket?.resets_at || !geometry) {
    return (
      <Card title="Burn rate" ariaLabel="Burn rate — no active window" wide loading={props.loading}>
        <QuietState message="No active window — burn appears when one starts." />
      </Card>
    );
  }

  const offset = isoOffsetMinutes(bucket.resets_at);
  const resetStr = hhmm(bucket.resets_at);
  const wallBeforeReset = geometry.projectedMs !== null && geometry.projectedMs < geometry.resetMs;
  const verdictText =
    geometry.projectedMs === null
      ? `resets ${resetStr}`
      : wallBeforeReset
        ? `wall ≈ ${hhmmAtEpoch(geometry.projectedMs, offset)} · resets ${resetStr} ⚠ — will be tight`
        : "resets before the wall ✓";
  const verdictTone = geometry.projectedMs === null ? "text-ter" : wallBeforeReset ? "text-warn" : "text-ok";

  const hovered = hoverIdx !== null ? geometry.points[hoverIdx] : null;

  const onMove = (e: React.PointerEvent<HTMLDivElement>) => {
    const rect = containerRef.current?.getBoundingClientRect();
    if (!rect) return;
    const fracX = (e.clientX - rect.left) / rect.width;
    const svgX = fracX * W;
    let nearest = 0;
    let bestDist = Infinity;
    geometry.points.forEach((p, i) => {
      const d = Math.abs(p.x - svgX);
      if (d < bestDist) {
        bestDist = d;
        nearest = i;
      }
    });
    setHoverIdx(nearest);
  };

  return (
    <Card
      title="Burn rate"
      subCaption={`${activeAccount?.label ?? props.state.active_id} — current 5h window`}
      ariaLabel={`Burn rate — ${activeAccount?.label ?? "active account"}'s current window, ${verdictText}, ${rateStr} API-equivalent per hour`}
      wide
      loading={props.loading}
    >
      <div
        ref={containerRef}
        className="relative"
        onPointerMove={onMove}
        onPointerLeave={() => setHoverIdx(null)}
      >
        <svg viewBox={`0 0 ${W} ${H}`} width="100%" height={H} preserveAspectRatio="none" aria-hidden="true">
          <line
            x1={PAD_L}
            x2={W - PAD_R}
            y1={geometry.baseline}
            y2={geometry.baseline}
            stroke="var(--hair)"
            strokeWidth={1}
          />
          <line
            x1={geometry.resetX}
            x2={geometry.resetX}
            y1={PAD_T}
            y2={geometry.baseline}
            stroke="var(--hairsoft)"
            strokeWidth={1}
          />
          <path d={geometry.areaPath} fill="var(--accent)" opacity={0.1} stroke="none" />
          <path d={geometry.linePath} fill="none" stroke="var(--accent)" strokeWidth={2} strokeLinejoin="round" strokeLinecap="round" />
          {geometry.projectionPath && (
            <path
              d={geometry.projectionPath}
              fill="none"
              stroke="var(--accent)"
              strokeWidth={2}
              strokeDasharray="1 4"
              strokeLinecap="round"
              opacity={0.65}
            />
          )}
          {hovered && (
            <>
              <line x1={hovered.x} x2={hovered.x} y1={PAD_T} y2={geometry.baseline} stroke="var(--acc-bd)" strokeWidth={1} />
              <circle cx={hovered.x} cy={hovered.y} r={4} fill="var(--accent)" stroke="var(--panel)" strokeWidth={2} />
            </>
          )}
          <text x={geometry.resetX} y={H - 6} textAnchor="middle" fontSize={9.5} fill="var(--ter)">
            resets {resetStr}
          </text>
        </svg>
        {hovered && (
          <TooltipPill xPct={(hovered.x / W) * 100} yPct={(hovered.y / H) * 100}>
            <strong className="font-semibold">{hovered.s.percent}%</strong>{" "}
            <span className="opacity-80">{hhmm(hovered.s.at)}</span>
          </TooltipPill>
        )}
      </div>
      <p className={`mt-2 text-[11px] font-medium ${verdictTone}`}>{verdictText}</p>
      <p className="mt-0.5 text-[10.5px] text-ter">{rateStr} API-equivalent</p>
    </Card>
  );
}
