// Component grammar #2 — TIME CHIP (the Radix thumb): 20px, radius 6,
// chipbg/chipbd, 6px meaning-dot + HH:MM at 11/600; selected = accent fill,
// white text, 2.5px accent ring. Rendered as the asChild target of
// Slider.Thumb — Radix's own wrapper handles horizontal centering, this
// component only owns its vertical offset (mirrors the interaction
// contract's .thumb { position:absolute; top:-5px } pattern).
import { forwardRef, type ComponentPropsWithoutRef } from "react";
import type { Dot } from "./classify.ts";

const DOT_CLASS: Record<Dot, string> = {
  gray: "bg-graydot",
  green: "bg-ok",
  amber: "bg-warnraw",
};

export interface TimeChipProps extends ComponentPropsWithoutRef<"span"> {
  label: string;
  dot: Dot;
  selected?: boolean;
  removing?: boolean;
}

const TimeChip = forwardRef<HTMLSpanElement, TimeChipProps>(function TimeChip(
  { label, dot, selected, removing, className = "", style, ...rest },
  ref,
) {
  return (
    <span
      ref={ref}
      style={{ position: "absolute", top: 6, ...style }}
      className={`flex h-5 cursor-grab items-center gap-[5px] whitespace-nowrap rounded-md border px-2 text-[11px] font-semibold outline-none active:cursor-grabbing ${
        removing
          ? "border-transparent bg-crit text-white"
          : selected
            ? "border-transparent bg-accent text-white shadow-[0_0_0_2.5px_var(--accent)]"
            : "border-chipbd bg-chipbg text-acc-tx"
      } focus-visible:shadow-[0_0_0_2.5px_var(--accent)] ${className}`}
      {...rest}
    >
      <span
        className={`h-1.5 w-1.5 shrink-0 rounded-full ${removing ? "bg-white" : DOT_CLASS[dot]} ${
          selected && dot === "amber" ? "shadow-[0_0_0_1.5px_rgba(255,255,255,.85)]" : ""
        }`}
      />
      {label}
    </span>
  );
});

export default TimeChip;
