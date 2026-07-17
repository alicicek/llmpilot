import { useMemo, useState } from "react";
import { Card, TooltipPill } from "./ChartKit.tsx";
import { sequentialColor } from "./colors.ts";
import { formatTokens, WEEKDAY_LABELS_MON_FIRST } from "./format.ts";

const HOUR_TICKS = [0, 6, 12, 18];

export function RhythmCard(props: { hourWeekday: number[][]; dark: boolean }) {
  const [hover, setHover] = useState<{ day: number; hour: number; colPct: number; rowPct: number } | null>(null);

  const max = useMemo(
    () => Math.max(1, ...props.hourWeekday.flatMap((row) => row)),
    [props.hourWeekday],
  );

  // Display rows are Mon-first; the API's rows are Sun-first (row 0 = Sun).
  const dataRowFor = (displayRow: number) => (displayRow + 1) % 7;

  return (
    <Card
      title="Rhythm"
      subCaption="your rhythm — quiet cells are good times for fresh windows"
      ariaLabel="Token activity by hour of day and day of week, a 24 by 7 heatmap"
    >
      <div className="flex gap-1.5">
        <div className="flex flex-col justify-between pt-[16px]">
          {WEEKDAY_LABELS_MON_FIRST.map((d) => (
            <div key={d} className="flex h-[14px] items-center text-[9px] text-ter">
              {d}
            </div>
          ))}
        </div>
        <div className="relative flex-1">
          <div
            className="grid text-[9px] text-ter"
            style={{ gridTemplateColumns: "repeat(24, 1fr)" }}
          >
            {Array.from({ length: 24 }, (_, h) => (
              <div key={h} className="h-[14px]">
                {HOUR_TICKS.includes(h) ? String(h).padStart(2, "0") : ""}
              </div>
            ))}
          </div>
          <div className="mt-0.5 flex flex-col gap-[2px]">
            {WEEKDAY_LABELS_MON_FIRST.map((dayLabel, displayRow) => {
              const row = props.hourWeekday[dataRowFor(displayRow)] ?? [];
              return (
                <div key={dayLabel} className="grid gap-[2px]" style={{ gridTemplateColumns: "repeat(24, 1fr)" }}>
                  {Array.from({ length: 24 }, (_, hour) => {
                    const v = row[hour] ?? 0;
                    const t = v / max;
                    return (
                      <button
                        key={hour}
                        type="button"
                        className="block h-[14px] w-full rounded-[2px] border-0 p-0 focus-visible:outline focus-visible:outline-2 focus-visible:outline-accent"
                        style={{ backgroundColor: sequentialColor(t, props.dark) }}
                        aria-label={`${dayLabel} ${String(hour).padStart(2, "0")}:00 — ${formatTokens(v)} tokens`}
                        onPointerEnter={() =>
                          setHover({ day: displayRow, hour, colPct: ((hour + 0.5) / 24) * 100, rowPct: ((displayRow + 0.5) / 7) * 100 })
                        }
                        onFocus={() =>
                          setHover({ day: displayRow, hour, colPct: ((hour + 0.5) / 24) * 100, rowPct: ((displayRow + 0.5) / 7) * 100 })
                        }
                        onPointerLeave={() => setHover(null)}
                        onBlur={() => setHover(null)}
                      />
                    );
                  })}
                </div>
              );
            })}
          </div>
          {hover && (
            <TooltipPill xPct={hover.colPct} yPct={hover.rowPct}>
              <strong className="font-semibold">
                {WEEKDAY_LABELS_MON_FIRST[hover.day]} {String(hover.hour).padStart(2, "0")}:00
              </strong>{" "}
              <span className="opacity-80">
                · {formatTokens(props.hourWeekday[dataRowFor(hover.day)]?.[hover.hour] ?? 0)} tokens
              </span>
            </TooltipPill>
          )}
        </div>
      </div>
      {/* TODO(board): click-to-book a fresh window from a quiet cell — the
          scheduler board owns booking; this build only surfaces the rhythm. */}
    </Card>
  );
}
