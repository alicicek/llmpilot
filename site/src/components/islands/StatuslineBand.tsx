import * as React from "react";
import { Reorder, useReducedMotion } from "motion/react";

/*
 * The signature interaction: the real statusline as draggable segment chips.
 * - drag any chip to reorder (config order IS render order, as in the product)
 * - click a usage chip (5h / wk / F) to cycle its display mode
 * All strings are transcribed verbatim from the shipped binary
 * (design/od/llmpilot-landing/fixtures/statusline-modes.txt) — no invented
 * modes, no invented glyphs. Meaning colors: rotation = graydot (assumes-idle),
 * auto:down = amber (may-drift). Everything else is plain text.
 */
type Kind = "account" | "usage" | "rotation" | "auto";
interface Seg {
  id: string;
  kind: Kind;
  modes: string[]; // usage: 3 modes; others: single label at index 0
}

const SEGMENTS: Seg[] = [
  { id: "account", kind: "account", modes: ["[acct 1/4 | alex@example.dev]"] },
  { id: "5h", kind: "usage", modes: ["5h:23%(19:00)", "5h ▓▓░░░░░░░░ 23%", "5h→19:00"] },
  { id: "wk", kind: "usage", modes: ["wk:41%", "wk ▓▓▓▓░░░░░░ 41%", "wk→Mon"] },
  { id: "F", kind: "usage", modes: ["F:12%", "F ▓░░░░░░░░░ 12%", "F→Mon"] },
  { id: "rotation", kind: "rotation", modes: ["→noor:2%"] },
  { id: "auto", kind: "auto", modes: ["auto:down"] },
];

const MODE_LABELS = ["percent", "bar", "time"] as const;

function colorFor(kind: Kind): string {
  // --ter is graydot's text-safe sibling (4.85:1 on --win; graydot is 3.33)
  if (kind === "rotation") return "var(--ter)";
  if (kind === "auto") return "var(--amber-tx)";
  return "var(--text)";
}

export default function StatuslineBand() {
  const [items, setItems] = React.useState<Seg[]>(SEGMENTS);
  const [mode, setMode] = React.useState(0);
  const reduced = useReducedMotion();
  const draggedRef = React.useRef(false);

  const cycle = () => setMode((m) => (m + 1) % 3);

  return (
    <div className="not-prose">
      <div
        role="group"
        aria-label="llmpilot statusline — drag to reorder, click a usage segment to change mode"
        className="rounded-lg border border-hair bg-panel"
      >
        {/* window bar — chrome dots are graydot only (meaning colors stay meaning) */}
        <div className="flex items-center gap-2 border-b border-hair px-4 py-2.5">
          <span className="h-3 w-3 rounded-full" style={{ background: "var(--graydot)" }} />
          <span className="h-3 w-3 rounded-full" style={{ background: "var(--graydot)" }} />
          <span className="h-3 w-3 rounded-full" style={{ background: "var(--graydot)" }} />
          <span className="flex-1 text-center text-[12px] text-sec">statusline</span>
          <span className="text-[12px] text-sec" aria-hidden="true">
            {MODE_LABELS[mode]}
          </span>
        </div>

        {/* the draggable segment row — a real list; usage chips hold a real
            button (native semantics; the accessible name starts with the
            visible text, per label-in-name) */}
        <Reorder.Group
          axis="x"
          values={items}
          onReorder={setItems}
          as="ul"
          className="m-0 flex list-none flex-wrap items-center gap-2 px-4 py-4"
          style={{ fontSize: "var(--fs-mono)", fontVariantNumeric: "tabular-nums" }}
        >
          {items.map((seg) => {
            const label = seg.kind === "usage" ? seg.modes[mode] : seg.modes[0];
            const isUsage = seg.kind === "usage";
            return (
              <Reorder.Item
                key={seg.id}
                value={seg}
                onDragStart={() => (draggedRef.current = true)}
                onDragEnd={() => {
                  // let the click handler see the drag, then clear next tick
                  setTimeout(() => (draggedRef.current = false), 0);
                }}
                transition={reduced ? { duration: 0 } : { type: "spring", stiffness: 600, damping: 40 }}
                whileDrag={{ scale: 1.04, cursor: "grabbing" }}
                className="cursor-grab touch-none rounded-sm border border-hair bg-win leading-none"
                style={{ color: colorFor(seg.kind) }}
              >
                {isUsage ? (
                  <button
                    type="button"
                    aria-label={`${label} — change display mode`}
                    onClick={() => {
                      if (draggedRef.current) return;
                      cycle();
                    }}
                    className="cursor-inherit border-0 bg-transparent px-2.5 py-1.5 font-[inherit] text-[length:inherit] leading-none text-inherit"
                    style={{ fontVariantNumeric: "tabular-nums" }}
                  >
                    {label}
                  </button>
                ) : (
                  <span className="block px-2.5 py-1.5">{label}</span>
                )}
              </Reorder.Item>
            );
          })}
        </Reorder.Group>
      </div>

      <p className="mt-3 flex flex-wrap gap-x-6 gap-y-1 text-[13px] text-ter">
        <span>drag to reorder — the full editor lives in the cockpit</span>
        <span>click a usage segment to cycle percent → bar → time</span>
      </p>
    </div>
  );
}
