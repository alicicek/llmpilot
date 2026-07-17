// Component grammar #4 — INSPECTOR: contextual, not a resting column. Slides
// in 200ms ease-in-out on selection (reduced-motion instant), closes on Esc
// or outside click. Copy follows VOICE.md: outcome-first title, one bold
// fact line then the consequence then the action.
import { useEffect, useRef } from "react";
import { DAY_MIN, MIN_GAP_MIN, WINDOW_HOURS, circularGap, fmtHM } from "../schedule.ts";
import type { ChipClass, LaneSchedule, MidWindow } from "./classify.ts";

export interface InspectorProps {
  email: string;
  ls: LaneSchedule;
  cls: ChipClass;
  mid: MidWindow | null;
  nowMinutes: number;
  chainTarget: number | null;
  onChain: () => void;
  onDelete: () => void;
  onClose: () => void;
}

const WINDOW_MIN = WINDOW_HOURS * 60;

export default function Inspector({
  email,
  ls,
  cls,
  mid,
  nowMinutes,
  chainTarget,
  onChain,
  onDelete,
  onClose,
}: InspectorProps) {
  const panelRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    const onClick = (e: MouseEvent) => {
      if (panelRef.current && !panelRef.current.contains(e.target as Node)) onClose();
    };
    document.addEventListener("keydown", onKey);
    document.addEventListener("mousedown", onClick);
    return () => {
      document.removeEventListener("keydown", onKey);
      document.removeEventListener("mousedown", onClick);
    };
  }, [onClose]);

  const dotClass =
    cls === "blocked" || cls === "missed" ? "bg-warnraw" : ls.chained ? "bg-ok" : "bg-graydot";

  const nextGap = chainTarget == null ? null : circularGap(ls.reset, chainTarget);
  const gapOk = nextGap != null && nextGap >= MIN_GAP_MIN;

  const catchUp = fmtHM(nowMinutes + WINDOW_MIN);
  const chainResult = chainTarget != null ? fmtHM((chainTarget + WINDOW_MIN) % DAY_MIN) : null;

  return (
    <div
      ref={panelRef}
      className="flex h-full w-[302px] flex-col gap-[11px] overflow-y-auto border-l border-hair bg-panel px-4 py-3.5"
    >
      <div className="text-[9px] font-bold tracking-[0.07em] text-ter">
        {email.toUpperCase()} — REPEATS DAILY
      </div>
      <div className="flex items-center gap-2 text-[15px] font-bold tracking-[-0.01em]">
        <span className={`h-2 w-2 rounded-full ${dotClass}`} />
        Fresh window at {fmtHM(ls.reset)}
      </div>

      <div className="flex items-center gap-[7px]">
        <span className="whitespace-nowrap text-[10px] font-bold text-sec">▲︎ {fmtHM(ls.trigger)}</span>
        <span className="relative h-[14px] flex-1 rounded border border-acc-bd bg-linear-to-r from-acc-a to-acc-b">
          <span className="absolute inset-0 flex items-center justify-center text-[8.5px] font-semibold tracking-[0.05em] text-acc-tx">
            charges 5:00
          </span>
        </span>
        <span className="whitespace-nowrap text-[10px] font-bold text-ok">⚑︎ {fmtHM(ls.reset)}</span>
      </div>

      <dl className="flex flex-col">
        <Row label="Auto-nudge" value={fmtHM(ls.trigger)} />
        <Row label="Charges unattended" value={`${fmtHM(ls.trigger)} – ${fmtHM(ls.reset)}`} />
        <Row label="Fresh & full" value={`from ${fmtHM(ls.reset)}`} />
        {nextGap != null && (
          <Row label="Gap to next reset" value={`${fmtHM(nextGap)} ${gapOk ? "✓︎" : "⚠︎"}`} />
        )}
      </dl>

      {/* Idle-dependency honesty card: every standalone (non-chained) nudge
          carries this risk, missed-today or not — the mockup and brief both
          show this alongside the catch-up/blocked cards, not instead of. */}
      {!ls.chained && cls !== "blocked" && (
        <div className="rounded-lg border border-warnbd bg-warnbg p-[10px] text-[10.5px] leading-[1.5] text-text">
          <b className="mb-0.5 block text-warn">Depends on you being idle at {fmtHM(ls.trigger)}</b>
          If you&apos;re still working, the nudge yields and today&apos;s reset drifts up to 5 h late.
          <div className="mt-2 flex flex-wrap gap-[7px]">
            {chainTarget != null && chainResult && (
              <button
                type="button"
                onClick={onChain}
                className="whitespace-nowrap rounded-md bg-ok px-[9px] py-[4px] text-[10px] font-bold text-white"
              >
                ⛓︎ Chain at {chainResult} — guaranteed
              </button>
            )}
            <button
              type="button"
              className="whitespace-nowrap rounded-md border border-hair px-[9px] py-[4px] text-[10px] font-bold text-sec"
            >
              Keep {fmtHM(ls.reset)}
            </button>
          </div>
        </div>
      )}

      {cls === "blocked" && mid && (
        <div className="rounded-lg border border-warnbd bg-warnbg p-[10px] text-[10.5px] leading-[1.5] text-text">
          <b className="mb-0.5 block text-warn">Lands inside the active session</b>
          The {fmtHM(ls.trigger)} nudge can&apos;t fire while the account is mid-window. It retries the
          instant that session resets at {fmtHM(mid.end)}, landing ≈ {fmtHM((mid.end + WINDOW_MIN) % DAY_MIN)}.
        </div>
      )}

      {cls === "missed" && (
        <div className="rounded-lg border border-hairsoft bg-hairsoft p-[10px] text-[10.5px] leading-[1.5] text-text">
          <b className="mr-1 inline text-sec">Today:</b>
          The {fmtHM(ls.trigger)} nudge has already passed (now {fmtHM(nowMinutes)}), so the first run
          is tomorrow.
          <div className="mt-2 flex flex-wrap gap-[7px]">
            <button
              type="button"
              disabled
              title="lands with the autopilot hookup"
              className="cursor-not-allowed whitespace-nowrap text-[10px] font-bold text-acc-tx opacity-60"
            >
              One-off catch-up now → fresh ≈ {catchUp} today
            </button>
          </div>
        </div>
      )}

      {ls.chained && (
        <div className="rounded-lg border border-okbd bg-okbg p-[10px] text-[10.5px] leading-[1.5] text-text">
          <b className="mb-0.5 block text-ok">⛓︎ Chained — guaranteed</b>
          Rides the {fmtHM(ls.trigger)} reset the instant it lands — no idle needed.
        </div>
      )}

      {cls === "ran" && (
        <div className="rounded-lg border border-okbd bg-okbg p-[10px] text-[10.5px] leading-[1.5] text-text">
          <b className="text-ok">✓︎ ran today</b> — fresh since {fmtHM(ls.reset)}.
        </div>
      )}

      <div className="mt-auto flex items-center justify-between border-t border-hairsoft pt-[10px] text-[10px]">
        <button type="button" onClick={onDelete} className="font-semibold text-crit">
          Remove reset
        </button>
        <span className="text-ter">← → move 15 min</span>
      </div>
    </div>
  );
}

function Row({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex items-baseline justify-between border-b border-hairsoft py-1.5">
      <dt className="text-[10.5px] text-sec">{label}</dt>
      <dd className="text-[11px] font-semibold">{value}</dd>
    </div>
  );
}
