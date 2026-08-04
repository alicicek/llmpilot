import { useCallback, useEffect, useLayoutEffect, useState } from "react";
import { useReducedMotion } from "../board/useReducedMotion.ts";

// The guided tour: a dimmed backdrop with a cutout over a REAL element of the
// cockpit, and a small card naming what the user is looking at. The product's
// claim is that it watches real limits and moves you before a wall — so the
// tour points at the user's own numbers rather than describing them, which is
// the shortest path to believing it.
//
// A step whose target is not on screen is skipped, not faked: the switch step
// has no target on a one-account fleet, and inventing one would teach a
// control that isn't there.

export interface TourStep {
  /** the data-tour value of the element to spotlight. */
  target: string;
  title: string;
  body: string;
}

const CARD_W = 300;
// Enough to decide above-vs-below before the card has been measured; the
// clamp below keeps it on screen either way.
const CARD_H_EST = 150;
const PAD = 8;

interface Rect {
  top: number;
  left: number;
  width: number;
  height: number;
}

function rectOf(target: string): Rect | null {
  const el = document.querySelector(`[data-tour="${target}"]`);
  if (!el) return null;
  const r = el.getBoundingClientRect();
  if (r.width === 0 && r.height === 0) return null;
  return { top: r.top, left: r.left, width: r.width, height: r.height };
}

export function Tour({ steps, onDone }: { steps: TourStep[]; onDone: () => void }) {
  const reduced = useReducedMotion();
  const [i, setI] = useState(0);
  const [rect, setRect] = useState<Rect | null>(null);
  const [cardH, setCardH] = useState(CARD_H_EST);
  // Host nodes are inserted at COMMIT, after every component function has
  // returned, so reading the DOM while rendering can see a board that is not
  // there yet — and concluding "nothing to point at" is destructive here: it
  // ends the guide for good. Today the mount is always one commit behind the
  // board (App only opens the guide from an effect), so this is a guard on
  // that invariant rather than a fix for an observed failure; it costs one
  // layout effect and removes the whole class.
  const [ready, setReady] = useState(false);
  useLayoutEffect(() => setReady(true), []);

  // Only steps whose target actually exists in this cockpit.
  const live = ready ? steps.filter((s) => rectOf(s.target) !== null) : [];
  const step: TourStep | undefined = live[i];

  const measure = useCallback(() => {
    if (!step) return;
    setRect(rectOf(step.target));
  }, [step]);

  useLayoutEffect(() => {
    if (!step) return;
    const el = document.querySelector(`[data-tour="${step.target}"]`);
    el?.scrollIntoView({ block: "center", behavior: reduced ? "auto" : "smooth" });
    measure();
    const onMove = () => measure();
    window.addEventListener("resize", onMove);
    window.addEventListener("scroll", onMove, true);
    // The board re-renders on every SSE push; re-measure on a slow beat so a
    // lane that grows a row cannot leave the cutout behind.
    const t = window.setInterval(onMove, 500);
    return () => {
      window.removeEventListener("resize", onMove);
      window.removeEventListener("scroll", onMove, true);
      window.clearInterval(t);
    };
  }, [step, measure, reduced]);

  useEffect(() => {
    // Enter is deliberately absent: the Next button holds focus, so Enter
    // already clicks it — advancing here too would jump two steps and skip
    // one entirely.
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onDone();
      if (e.key === "ArrowRight") setI((n) => n + 1);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onDone]);

  // Ending is a parent state change, so it belongs in an effect — calling it
  // while rendering updates another component mid-render. Two ways to be
  // done: walked past the last step, or there was never anything on screen
  // worth pointing at (never show an empty guide).
  useEffect(() => {
    if (!ready) return;
    if (live.length === 0 || i >= live.length) onDone();
  }, [ready, i, live.length, onDone]);

  if (!step || !rect) return null;

  const vh = window.innerHeight;
  const vw = window.innerWidth;
  const below = rect.top + rect.height + PAD + cardH < vh;
  // The overlay is fixed and cannot scroll, so a card placed past the fold
  // takes its own buttons with it — clamp to the viewport either way.
  const cardTop = Math.min(
    Math.max(12, below ? rect.top + rect.height + PAD + 4 : rect.top - PAD - cardH),
    Math.max(12, vh - cardH - 12),
  );
  const cardLeft = Math.min(Math.max(12, rect.left), Math.max(12, vw - CARD_W - 12));
  const last = i === live.length - 1;

  // Deliberately NOT aria-modal: the point of each step is the element being
  // spotlighted, and marking this modal would hide exactly that from
  // assistive tech.
  return (
    <div className="fixed inset-0 z-50" role="dialog" aria-label="Guide">
      {/* The cutout: one element ringing the target, with an enormous spread
          shadow standing in for the dimmed rest of the screen. It jumps
          between steps rather than morphing — the card's entrance carries the
          motion, and tweening a rect means animating layout properties every
          frame for no gain the eye can use. */}
      <div
        aria-hidden="true"
        className="pointer-events-none absolute rounded-[7px] ring-2 ring-accent"
        style={{
          top: rect.top - 4,
          left: rect.left - 4,
          width: rect.width + 8,
          height: rect.height + 8,
          boxShadow: "0 0 0 9999px rgba(0,0,0,0.55)",
        }}
      />
      {/* Backdrop click ends the guide — the same escape the ✕ gives. */}
      <button
        aria-label="Close the guide"
        className="absolute inset-0 h-full w-full cursor-default"
        onClick={onDone}
      />
      <div
        ref={(el) => {
          if (el && Math.abs(el.offsetHeight - cardH) > 1) setCardH(el.offsetHeight);
        }}
        className="absolute rounded-[11px] border border-hair bg-win p-3.5 shadow-window animate-[rise-in_200ms_ease-out_both]"
        style={{ top: cardTop, left: cardLeft, width: CARD_W }}
      >
        <p className="text-[9px] font-bold tracking-[0.08em] text-ter">
          STEP {i + 1} OF {live.length}
        </p>
        <p className="mt-1.5 text-[12.5px] font-semibold">{step.title}</p>
        <p className="mt-1 text-[11.5px] leading-relaxed text-sec">{step.body}</p>
        <div className="mt-3 flex items-center justify-between">
          {last ? (
            <span />
          ) : (
            <button className="text-[11px] text-ter hover:underline" onClick={onDone}>
              Skip the guide
            </button>
          )}
          <button
            className="rounded-lg bg-acc-tx px-3 py-1.5 text-[11.5px] font-semibold text-white transition-colors duration-150 dark:bg-accent focus:outline-none focus-visible:ring-2 focus-visible:ring-acc-bd"
            onClick={() => (last ? onDone() : setI((n) => n + 1))}
            autoFocus
          >
            {last ? "Got it" : "Next"}
          </button>
        </div>
      </div>
    </div>
  );
}
