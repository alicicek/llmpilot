// Component grammar #1 — CHARGE BLOCK: a reset is never a point, it's the
// trailing edge of a rigid 5-hour object, visible at rest (the BLOCK-MATERIAL
// variant's whole thesis). 30px tall, radius 7, the app's only gradient
// (accA→accB, charge direction), 1px acc-bd border, centered "5:00" watermark.
import { toPx } from "./geometry.ts";

export interface ChargeBlockProps {
  trigger: number;
  reset: number;
  /** meeting edge with a chained predecessor/follower on this lane — square it. */
  squareLeft?: boolean;
  squareRight?: boolean;
  dragging?: boolean;
  hovered?: boolean;
  ghost?: boolean;
}

export default function ChargeBlock({
  trigger,
  reset,
  squareLeft,
  squareRight,
  dragging,
  hovered,
  ghost,
}: ChargeBlockProps) {
  const left = toPx(trigger);
  const width = toPx(reset) - toPx(trigger);
  const radius = {
    borderTopLeftRadius: squareLeft ? 0 : 7,
    borderBottomLeftRadius: squareLeft ? 0 : 7,
    borderTopRightRadius: squareRight ? 0 : 7,
    borderBottomRightRadius: squareRight ? 0 : 7,
  };

  if (ghost) {
    return (
      <div
        className="pointer-events-none absolute top-[34px] h-[30px] rounded-[7px] border-[1.5px] border-dashed border-acc-bd opacity-50"
        style={{ left, width, ...radius }}
      />
    );
  }

  return (
    <div
      className={`pointer-events-none absolute top-[34px] h-[30px] border border-acc-bd bg-linear-to-r from-acc-a to-acc-b transition-shadow duration-150 ${
        dragging
          ? "z-[6] shadow-drag ring-[1.5px] ring-acc-bd"
          : hovered
            ? "z-[3] ring-1 ring-acc-bd/60"
            : "z-[2]"
      } ${squareRight ? "border-r-0" : ""}`}
      style={{ left, width, ...radius }}
    >
      <span className="flex h-full items-center justify-center text-[9px] font-semibold tracking-[0.04em] text-acc-tx opacity-55">
        5:00
      </span>
    </div>
  );
}
