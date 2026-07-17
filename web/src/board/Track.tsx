// The interactive 24h track for one lane — a Radix Slider whose values are
// this lane's RESET times (minutes since midnight). Spacing clamp lives
// entirely in onValueChange (Radix's minStepsBetweenThumbs clamps before our
// handler runs and kills the flash physics — the interaction contract's
// explicit warning), circular across the midnight seam, 15-min detents.
import {
  useCallback,
  useEffect,
  useRef,
  useState,
  type KeyboardEvent as ReactKeyboardEvent,
  type PointerEvent as ReactPointerEvent,
} from "react";
import { Slider } from "radix-ui";
import { AnimatePresence, motion } from "motion/react";
import {
  DAY_MIN,
  MIN_GAP_MIN,
  SNAP_MIN,
  WINDOW_HOURS,
  circularGap,
  fmtHM,
} from "../schedule.ts";
import { toPx } from "./geometry.ts";
import { canBookAt, clampMove } from "./clamp.ts";
import { chipCopy, chipDot, classify, type LaneSchedule, type MidWindow } from "./classify.ts";
import { tickBook, tickDetent, tickRemove, tickWall } from "./audio.ts";
import ChargeBlock from "./ChargeBlock.tsx";
import TimeChip from "./TimeChip.tsx";
import Hud from "./Hud.tsx";

const WINDOW_MIN = WINDOW_HOURS * 60;
const wrap = (m: number) => ((m % DAY_MIN) + DAY_MIN) % DAY_MIN;
const triggerOf = (reset: number) => wrap(reset - WINDOW_MIN);

export interface TrackProps {
  accountLabel: string;
  schedules: LaneSchedule[];
  mid: MidWindow | null;
  nowMinutes: number;
  selectedId: string | null;
  onSelect: (id: string | null) => void;
  onCreate: (hour: number, minute: number) => void;
  onMove: (id: string, hour: number, minute: number) => void;
  onDelete: (id: string) => void;
}

export default function Track({
  accountLabel,
  schedules,
  mid,
  nowMinutes,
  selectedId,
  onSelect,
  onCreate,
  onMove,
  onDelete,
}: TrackProps) {
  // Mid-window lanes keep the cannot-shift lock (earliest fresh reset =
  // active end + 5h). Idle lanes have NO now-floor: schedules repeat daily,
  // so an earlier-than-now reset is a legal booking that classify() renders
  // honestly as "missed today"/"from tomorrow" — never silently relabeled
  // (selection-round judges, 2026-07-10).
  const floor = mid ? mid.end + WINDOW_MIN : 0;
  const [values, setValues] = useState<number[]>(() => schedules.map((s) => s.reset));
  const [flash, setFlash] = useState<{ left: number; width: number; key: number } | null>(null);
  const [removingIndex, setRemovingIndex] = useState(-1);
  const [hoveredIndex, setHoveredIndex] = useState(-1);
  const [draggingIndex, setDraggingIndex] = useState(-1);
  const [preview, setPreview] = useState<number | null>(null);

  const rootRef = useRef<HTMLSpanElement>(null);
  const dragIdxRef = useRef(-1);
  const originRef = useRef<number[]>([]);
  const valuesRef = useRef(values);
  const removingRef = useRef(-1);
  const schedulesRef = useRef(schedules);
  const onMoveRef = useRef(onMove);
  const onDeleteRef = useRef(onDelete);
  valuesRef.current = values;
  removingRef.current = removingIndex;
  schedulesRef.current = schedules;
  onMoveRef.current = onMove;
  onDeleteRef.current = onDelete;

  const sig = schedules.map((s) => `${s.schedule.id}:${s.reset}`).join(",");
  useEffect(() => {
    if (dragIdxRef.current === -1) setValues(schedules.map((s) => s.reset));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [sig]);

  useEffect(() => {
    const up = () => {
      const i = dragIdxRef.current;
      if (i === -1) return;
      const id = schedulesRef.current[i]?.schedule.id;
      if (id && removingRef.current === i && valuesRef.current.length > 1) {
        tickRemove();
        onDeleteRef.current(id);
      } else if (id) {
        const v = valuesRef.current[i]!;
        if (originRef.current[i] !== v) {
          const t = triggerOf(v);
          onMoveRef.current(id, Math.floor(t / 60), t % 60);
        }
      }
      dragIdxRef.current = -1;
      setDraggingIndex(-1);
      setRemovingIndex(-1);
      setFlash(null);
    };
    window.addEventListener("pointerup", up);
    return () => window.removeEventListener("pointerup", up);
  }, []);

  const doFlash = useCallback((from: number, to: number) => {
    setFlash({ left: toPx(from), width: toPx(to) - toPx(from), key: Math.random() });
  }, []);

  const handleValueChange = useCallback(
    (next: number[]) => {
      const prev = valuesRef.current;
      let i = -1;
      for (let k = 0; k < next.length; k++) {
        if (next[k] !== prev[k]) {
          i = k;
          break;
        }
      }
      if (i === -1) return;

      // chain-snap: within one detent of the previous neighbor's reset, the
      // block magnetizes to the seam (exact 5h touch, an explicit exception
      // to the normal 5h15m minimum gap).
      if (i > 0) {
        const prevReset = next[i - 1]!;
        const trigger = triggerOf(next[i]!);
        if (circularGap(trigger, prevReset) <= SNAP_MIN) {
          const snapped = (prevReset + WINDOW_MIN) % DAY_MIN;
          const out = [...next];
          out[i] = snapped;
          setValues(out);
          if (snapped !== prev[i]) tickDetent();
          return;
        }
      }

      const res = clampMove(prev, next, floor);
      if (!res) {
        setValues(next);
        return;
      }
      setValues(res.values);
      if (res.flashZone) {
        doFlash(res.flashZone[0], res.flashZone[1]);
        if (res.hitWall) tickWall();
      } else if (res.values[i] !== prev[i]) {
        tickDetent();
      }
    },
    [floor, doFlash],
  );

  const handleRootPointerMove = (e: ReactPointerEvent) => {
    const rect = rootRef.current?.getBoundingClientRect();
    if (!rect) return;
    if (dragIdxRef.current >= 0) {
      const dy = Math.abs(e.clientY - (rect.top + rect.height / 2));
      setRemovingIndex(dy > 56 && valuesRef.current.length > 1 ? dragIdxRef.current : -1);
      return;
    }
    const t = Math.round(((e.clientX - rect.left) / rect.width) * DAY_MIN / SNAP_MIN) * SNAP_MIN;
    const clamped = Math.min(DAY_MIN - SNAP_MIN, Math.max(0, t));
    setPreview(canBookAt(clamped, valuesRef.current, floor) ? null : clamped);
  };

  const handleRootPointerDownCapture = (e: ReactPointerEvent) => {
    if ((e.target as HTMLElement).closest('[role="slider"]')) return;
    const rect = rootRef.current?.getBoundingClientRect();
    if (!rect) return;
    const t = Math.round(((e.clientX - rect.left) / rect.width) * DAY_MIN / SNAP_MIN) * SNAP_MIN;
    const clamped = Math.min(DAY_MIN - SNAP_MIN, Math.max(0, t));
    e.preventDefault();
    e.stopPropagation();
    onSelect(null);
    const bad = canBookAt(clamped, valuesRef.current, floor);
    if (bad) {
      doFlash(bad[0], bad[1]);
      tickWall();
      return;
    }
    const t2 = triggerOf(clamped);
    tickBook();
    onCreate(Math.floor(t2 / 60), t2 % 60);
    setPreview(null);
  };

  const empty = values.length === 0;

  return (
    <div className="relative h-[116px]">
      {empty ? (
        <div className="pointer-events-none absolute inset-x-0 top-12 border-t-2 border-dashed border-rail" />
      ) : (
        <div className="pointer-events-none absolute inset-x-0 top-12 h-0.5 bg-rail" />
      )}
      {empty && !mid && (
        // The book-one nudge targets a genuinely idle lane; a mid-window
        // lane already says it's busy via the in-use band (and still books
        // via the hover ghost).
        <div className="pointer-events-none absolute inset-x-0 top-[42px] text-center text-[11px] text-ter">
          No fresh windows — click a time to book one
        </div>
      )}

      {mid && (
        <div
          className="pointer-events-none absolute top-[88px] z-[2] flex h-[15px] items-center justify-center rounded border border-hair text-[9px] font-semibold text-text"
          style={{
            left: toPx(mid.start),
            width: toPx(mid.end) - toPx(mid.start),
            backgroundImage: "repeating-linear-gradient(135deg, var(--hatch) 0 3px, var(--hatchbg) 3px 7.5px)",
          }}
        >
          in use — resets {fmtHM(mid.end)}
        </div>
      )}

      <Slider.Root
        ref={rootRef}
        className="absolute inset-0 cursor-crosshair"
        min={0}
        max={DAY_MIN}
        step={SNAP_MIN}
        minStepsBetweenThumbs={0}
        value={values}
        onValueChange={handleValueChange}
        onValueCommit={(vals) => {
          // Keyboard moves commit here (pointer drags commit on pointerup,
          // which owns remove-gesture handling — skip while one is live).
          if (dragIdxRef.current !== -1) return;
          vals.forEach((v, i) => {
            const s = schedulesRef.current[i];
            if (s && s.reset !== v) {
              const t = triggerOf(v);
              onMoveRef.current(s.schedule.id, Math.floor(t / 60), t % 60);
            }
          });
        }}
        onPointerDownCapture={handleRootPointerDownCapture}
        onPointerMove={handleRootPointerMove}
        onPointerLeave={() => setPreview(null)}
      >
        <Slider.Track className="absolute inset-0" />

        {draggingIndex >= 0 &&
          (() => {
            const dv = values[draggingIndex]!;
            const others = values.filter((_, k) => k !== draggingIndex);
            const zones: { from: number; to: number; kind: "red" | "amber" }[] = [];
            const walls: number[] = [];
            const chainPoints: number[] = [];
            if (floor > 0) {
              zones.push({ from: 0, to: floor, kind: "red" });
              walls.push(floor);
            }
            for (const v of others) {
              const lo = Math.max(0, v - MIN_GAP_MIN);
              const hi = Math.min(DAY_MIN, v + MIN_GAP_MIN);
              zones.push({ from: lo, to: hi, kind: "red" });
              walls.push(lo, hi);
              chainPoints.push((v + WINDOW_MIN) % DAY_MIN);
              zones.push({ from: hi, to: Math.min(DAY_MIN, hi + 120), kind: "amber" });
            }
            const origin = originRef.current[draggingIndex];
            return (
              <>
                {zones.map((z, k) => (
                  <div
                    key={k}
                    className="pointer-events-none absolute top-[31px] z-0 h-[37px]"
                    style={{
                      left: toPx(z.from),
                      width: toPx(z.to) - toPx(z.from),
                      backgroundImage:
                        z.kind === "red"
                          ? "repeating-linear-gradient(135deg, var(--critzone1) 0 4px, var(--critzone2) 4px 9px)"
                          : "var(--warnzone)",
                    }}
                  />
                ))}
                {walls.map((w, k) => (
                  <div
                    key={k}
                    className="pointer-events-none absolute top-[27px] z-[5] h-[45px] w-[2px] bg-crit"
                    style={{ left: toPx(w) - 1 }}
                  />
                ))}
                {chainPoints.map((c, k) => (
                  <div
                    key={k}
                    className="pointer-events-none absolute top-[45px] z-[6] h-2 w-2 rotate-45 bg-ok shadow-[0_0_6px_var(--ok)]"
                    style={{ left: toPx(c) }}
                  />
                ))}
                {origin != null && origin !== dv && (
                  <ChargeBlock ghost trigger={triggerOf(origin)} reset={origin} />
                )}
                <Hud
                  reset={dv}
                  trigger={triggerOf(dv)}
                  chained={values.length > 1 && draggingIndex > 0 && circularGap(triggerOf(dv), values[draggingIndex - 1]!) === 0}
                  warn="busy-risk"
                />
              </>
            );
          })()}

        <AnimatePresence>
          {flash && (
            <motion.div
              key={flash.key}
              initial={{ opacity: 0 }}
              animate={{ opacity: [0, 0.4, 0] }}
              exit={{ opacity: 0 }}
              transition={{ duration: 0.7, times: [0, 0.25, 1] }}
              onAnimationComplete={() => setFlash(null)}
              // Solid warn at 0.4 peak per the interaction contract
              // (design/llmpilot-scheduler-radix.html .flashzone) — the 10%
              // --warnzone wash is the sustained drag-zone fill and reads as
              // nothing when flashed for 0.7s.
              className="pointer-events-none absolute top-[31px] z-0 h-[37px] rounded-[3px] bg-warnraw"
              style={{ left: flash.left, width: flash.width }}
            />
          )}
        </AnimatePresence>

        {preview != null && (
          <div
            className="pointer-events-none absolute top-[40px] z-[3] -translate-x-1/2 rounded-full bg-ok/35 px-1.5 py-0.5 text-[10px] font-semibold text-sec"
            style={{ left: toPx(preview) }}
          >
            + {fmtHM(preview)}
          </div>
        )}

        {values.map((v, i) => {
          const ls = schedules[i];
          if (!ls) return null;
          const trigger = triggerOf(v);
          const chained =
            values.length > 1 && i > 0 && circularGap(trigger, values[i - 1]!) === 0;
          const nextChained =
            values.length > 1 &&
            i < values.length - 1 &&
            circularGap(triggerOf(values[i + 1]!), v) === 0;
          const live: LaneSchedule = { schedule: ls.schedule, trigger, reset: v, chained };
          const cls = classify(live, nowMinutes, mid);
          const copy = chipCopy(live, cls, mid);
          const dot = chipDot(cls, chained);
          const selected = selectedId === ls.schedule.id;

          return (
            <div key={ls.schedule.id}>
              <ChargeBlock
                trigger={trigger}
                reset={v}
                squareLeft={chained}
                squareRight={nextChained}
                dragging={draggingIndex === i}
                hovered={hoveredIndex === i}
              />
              {chained && (
                <div
                  className="pointer-events-none absolute top-[41px] z-[3] flex h-4 w-4 -translate-x-1/2 items-center justify-center rounded-full border border-hair bg-win text-[9px] text-sec"
                  style={{ left: toPx(v - WINDOW_MIN) }}
                >
                  ⛓︎
                </div>
              )}
              <div
                className="pointer-events-none absolute top-[26px] z-[4] h-2 w-[1.5px] -translate-x-1/2 bg-chipbd"
                style={{ left: toPx(v) }}
              />
              <Slider.Thumb
                aria-label={`reset at ${fmtHM(v)} for ${accountLabel}`}
                asChild
                onPointerDown={() => {
                  dragIdxRef.current = i;
                  originRef.current = valuesRef.current;
                  setDraggingIndex(i);
                }}
                onPointerEnter={() => setHoveredIndex(i)}
                onPointerLeave={() => setHoveredIndex(-1)}
                onClick={() => onSelect(ls.schedule.id)}
                onKeyDown={(e: ReactKeyboardEvent) => {
                  if (e.key === "Backspace" || e.key === "Delete") {
                    e.preventDefault();
                    tickRemove();
                    onDelete(ls.schedule.id);
                  }
                }}
              >
                <TimeChip label={fmtHM(v)} dot={dot} selected={selected} removing={removingIndex === i} />
              </Slider.Thumb>
              {copy.suffix && (
                <div
                  className={`pointer-events-none absolute top-[11px] z-[4] whitespace-nowrap text-[10px] ${
                    copy.suffixTone === "ok" ? "text-ok-tx" : copy.suffixTone === "amber" ? "font-semibold text-warn" : "text-sec"
                  }`}
                  style={{ left: toPx(v) + 68 }}
                >
                  {copy.suffix}
                </div>
              )}
              <div
                className={`pointer-events-none absolute top-[71px] z-[3] whitespace-nowrap text-[9.5px] ${
                  copy.trigTone === "amber" ? "text-warn" : "text-ter"
                }`}
                style={{ left: toPx(trigger) - 3 }}
              >
                {copy.trigLine}
              </div>
              <div
                className={`pointer-events-none absolute top-16 z-[3] h-1.5 w-[1.5px] opacity-80 ${
                  copy.trigTone === "amber" ? "bg-warnraw" : "bg-ter"
                }`}
                style={{ left: toPx(trigger) }}
              />
            </div>
          );
        })}
      </Slider.Root>
    </div>
  );
}
