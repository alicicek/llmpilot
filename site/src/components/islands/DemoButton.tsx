import * as React from "react";
import { AnimatePresence, motion, useReducedMotion } from "motion/react";

/*
 * "Watch the demo" → an honest, clearly-empty framed slot for the launch
 * recording. Never a screenshot posing as video: no fake poster, no fake
 * duration, no fake progress bar. Fades in via Motion; Escape closes and
 * focus returns to the trigger.
 */
export default function DemoButton({
  label = "Watch the demo",
  frameLabel = "Live demo — one night on autopilot",
}: {
  label?: string;
  frameLabel?: string;
}) {
  const [open, setOpen] = React.useState(false);
  const reduced = useReducedMotion();
  const triggerRef = React.useRef<HTMLButtonElement>(null);
  const closeRef = React.useRef<HTMLButtonElement>(null);

  React.useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") setOpen(false);
    };
    document.addEventListener("keydown", onKey);
    closeRef.current?.focus();
    return () => document.removeEventListener("keydown", onKey);
  }, [open]);

  const dur = reduced ? 0 : 0.18;

  return (
    <>
      <button
        ref={triggerRef}
        type="button"
        onClick={() => setOpen(true)}
        className="inline-flex h-11 items-center justify-center gap-2 rounded-md border border-hair px-5 text-[14px] font-semibold text-text transition-colors duration-150 hover:bg-white/5"
      >
        <span aria-hidden="true">&#9654;&#65038;</span>
        {label}
      </button>

      <AnimatePresence onExitComplete={() => triggerRef.current?.focus()}>
        {open && (
          <motion.div
            className="fixed inset-0 z-50 flex items-center justify-center p-6"
            style={{ background: "rgba(0,0,0,0.6)" }}
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            exit={{ opacity: 0 }}
            transition={{ duration: dur }}
            onClick={() => setOpen(false)}
            role="dialog"
            aria-modal="true"
            aria-label={frameLabel}
          >
            <motion.div
              className="w-full max-w-3xl"
              initial={{ opacity: 0, y: reduced ? 0 : 8 }}
              animate={{ opacity: 1, y: 0 }}
              exit={{ opacity: 0, y: reduced ? 0 : 8 }}
              transition={{ duration: dur }}
              onClick={(e) => e.stopPropagation()}
            >
              <div
                className="flex aspect-video w-full flex-col items-center justify-center gap-3 rounded-xl border border-hair"
                style={{ background: "var(--panel)" }}
              >
                <span className="text-4xl text-ter" aria-hidden="true">
                  &#9654;&#65038;
                </span>
                <span className="text-[14px] text-sec">{frameLabel}</span>
                <span className="text-[12px] text-ter">recording lands at launch</span>
              </div>
              <div className="mt-3 flex justify-end">
                <button
                  ref={closeRef}
                  type="button"
                  onClick={() => setOpen(false)}
                  className="rounded-md border border-hair px-4 py-2 text-[13px] font-semibold text-text transition-colors duration-150 hover:bg-white/5"
                >
                  Close demo
                </button>
              </div>
            </motion.div>
          </motion.div>
        )}
      </AnimatePresence>
    </>
  );
}
