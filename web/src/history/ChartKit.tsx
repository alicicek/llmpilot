import type { ReactNode } from "react";

// Chart card shell — hairline border radius 8, title 10.5/600 in text-sec,
// sub-caption in text-ter (marks-and-anatomy: title/legend/labels wear text
// tokens, never a series color).
export function Card(props: {
  title: string;
  subCaption?: string;
  ariaLabel: string;
  wide?: boolean;
  loading?: boolean;
  children: ReactNode;
}) {
  return (
    <figure
      aria-label={props.ariaLabel}
      className={`rounded-[8px] border border-hair bg-panel p-3.5 transition-opacity duration-150 ${
        props.wide ? "col-span-full" : ""
      } ${props.loading ? "opacity-60" : ""}`}
    >
      <figcaption>
        <div className="text-[10.5px] font-semibold text-sec">{props.title}</div>
        {props.subCaption && <div className="mt-0.5 text-[10px] text-ter">{props.subCaption}</div>}
      </figcaption>
      <div className="mt-2.5">{props.children}</div>
    </figure>
  );
}

// A quiet, designed empty/failure state — never a spinner-forever, never a
// crash. VOICE.md: state what happened, plainly, no alarm.
export function QuietState(props: { message: string; wide?: boolean }) {
  return (
    <div
      className={`flex min-h-[120px] items-center justify-center rounded-[8px] border border-hair bg-panel px-4 text-center text-[11px] text-ter ${
        props.wide ? "col-span-full" : ""
      }`}
    >
      {props.message}
    </div>
  );
}

// Hover tooltip — the HUD pill from the pack (dark, floating, values-lead).
// aria-hidden: every value it shows is also reachable via a direct label or
// the table view underneath.
// xPct/yPct are 0-100, positioned against the nearest `relative` ancestor
// (the chart's SVG wrapper) — percentage-based so the pill tracks correctly
// regardless of how the SVG viewBox scales to its rendered size.
export function TooltipPill(props: { xPct: number; yPct: number; children: ReactNode }) {
  return (
    <div
      aria-hidden
      className="pointer-events-none absolute z-10 -translate-x-1/2 -translate-y-[calc(100%+8px)] rounded-[7px] bg-hudbg px-2.5 py-1.5 text-[10.5px] whitespace-nowrap text-hudtx shadow-hud"
      style={{ left: `${props.xPct}%`, top: `${props.yPct}%` }}
    >
      {props.children}
    </div>
  );
}

// Legend row: swatch + name + %, all in text tokens (identity rides the
// swatch, never colored text). Always present for >= 2 series.
export function LegendRow(props: { entries: { label: string; color: string; share: number }[] }) {
  return (
    <ul className="mt-2.5 flex flex-wrap gap-x-3.5 gap-y-1.5">
      {props.entries.map((e) => (
        <li key={e.label} className="flex items-center gap-1.5 text-[10.5px] text-sec">
          <i className="inline-block h-[8px] w-[8px] rounded-[2px]" style={{ backgroundColor: e.color }} />
          {e.label}
          <span className="text-ter">{Math.round(e.share)}%</span>
        </li>
      ))}
    </ul>
  );
}
