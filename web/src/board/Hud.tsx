// Component grammar #5 — HUD: dark pill streaming the live outcome while
// dragging. HUD-FOLLOW motion move: tracking is raw (1:1, no animation), only
// the fade in/out animates (150ms ease-out).
import { motion } from "motion/react";
import { toPx } from "./geometry.ts";
import { fmtHM } from "../schedule.ts";

export interface HudProps {
  reset: number;
  trigger: number;
  warn: string | null;
  chained: boolean;
}

export default function Hud({ reset, trigger, warn, chained }: HudProps) {
  const left = toPx(reset);
  return (
    <>
      <motion.div
        initial={{ opacity: 0 }}
        animate={{ opacity: 1 }}
        exit={{ opacity: 0 }}
        transition={{ duration: 0.15, ease: "easeOut" }}
        className="pointer-events-none absolute top-px z-[8] h-6 -translate-x-1/2 whitespace-nowrap rounded-[7px] border border-white/[0.14] bg-hudbg px-[11px] text-[10.5px] leading-6 text-hudtx shadow-hud"
        style={{ left }}
      >
        <b className="text-[11.5px] font-bold">{fmtHM(reset)}</b>
        <span className="opacity-[0.62]"> · nudge {fmtHM(trigger)} · </span>
        {chained ? (
          <span className="font-semibold text-ok">⛓︎ chained</span>
        ) : warn ? (
          <span className="font-semibold text-[#ffb340]">⚠︎ {warn}</span>
        ) : null}
      </motion.div>
      <div
        className="pointer-events-none absolute top-[25px] z-[8] h-[9px] w-[1.5px] -translate-x-1/2 bg-acc-bd"
        style={{ left }}
      />
    </>
  );
}
