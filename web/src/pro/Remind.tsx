import { useEffect } from "react";
import type { Quote } from "../api.ts";
import { StepDots } from "../shell/StepDots.tsx";
import { CloseButton } from "./CloseButton.tsx";
import { chargeInstant, remindDate } from "./ladder.ts";

// SPEC-127 screen ⑦ — the reminder choice, and NOTHING else.
//
// It moved ahead of the price (owner 2026-08-05, following Duolingo's
// ladder), which changed what this screen may say. It states no amount: the
// price screen that follows owns every consent fact — trial length, amount,
// charge date, reminder date, statement descriptor — so the disclosure sits
// on the one screen carrying the money button, immediately above it. That is
// stricter than 1.2.6, where terms were split across two screens.
//
// The screen contextualises itself in its own headline ("your N free days end
// <date>") because a reminder about an unnamed thing is a non-sequitur, and
// ⑥ has only just announced the trial.
//
// Continue is locked until a day is picked: a deliberate micro-commitment
// (Duolingo does the same), and the one disabled sole-control in the flow.
// It is safe because both options are on screen and one tap frees it — unlike
// the 1.2.6 dead end, where the sole control was disabled with nothing on
// screen that could enable it.

const btnPrimary =
  "w-full rounded-lg bg-acc-tx px-4 py-2.5 text-[13px] font-semibold text-white transition-colors duration-150 disabled:opacity-40 dark:bg-accent focus:outline-none focus-visible:ring-2 focus-visible:ring-acc-bd";

export function Remind({
  quote,
  remindDays,
  onRemindDays,
  locale,
  onContinue,
  onClose,
  dots,
}: {
  quote: Quote;
  /** null until the buyer picks — Continue stays locked. */
  remindDays: number | null;
  onRemindDays: (d: number) => void;
  locale: string;
  onContinue: () => void;
  /** Absent inside the guided flow (SPEC-127 D9: the corridor's only door is
   *  ⑧). A paywall reopened later from the banner passes it. */
  onClose?: () => void;
  dots?: { step: number; total: number };
}) {
  const chargeISO = chargeInstant(quote);
  const charge = new Date(chargeISO);
  const chargeLong = charge.toLocaleDateString(locale, { day: "numeric", month: "long" });
  const chargeShort = charge
    .toLocaleDateString(locale, { day: "numeric", month: "short" })
    .toUpperCase();
  const days = quote.trial_days;
  // trial_days is server-controlled: an offset that doesn't fit the trial
  // never renders as a chip, and the amber dot only marks a day strictly
  // inside the strip (index 0 is TODAY, the last is the charge).
  const offsets = [2, 1].filter((d) => d < days);
  const remindIdx = remindDays === null ? -1 : days - remindDays;

  // With a single possible answer there is no question, so locking Continue
  // behind a mandatory tap on the only button is friction with no consent
  // value. (Paywall never routes here with ZERO offsets — that would be a
  // question nothing on screen could answer, and it skips ⑦ instead.)
  useEffect(() => {
    if (remindDays === null && offsets.length === 1) onRemindDays(offsets[0]);
  }, [remindDays, offsets, onRemindDays]);

  return (
    <section className="relative mx-auto w-[620px] max-w-[92vw] animate-[rise-in_200ms_ease-out_both]">
      {dots && <StepDots {...dots} />}
      {onClose && <CloseButton onClick={onClose} />}
      <h2
        className="text-[19px] font-semibold leading-[1.3] tracking-[-0.015em] tabular-nums"
        data-testid="remind-headline"
      >
        Your {days} free days end <span className="text-acc-tx">{chargeLong}</span>.
      </h2>
      <p className="mt-[9px] text-[12.5px] leading-relaxed text-sec">
        We email you once before that, so nothing is ever a surprise. Pick the day.
      </p>

      <div className="mt-5 flex flex-col gap-2.5" role="group" aria-label="When should we remind you?">
        {offsets.map((d) => (
          <button
            key={d}
            aria-pressed={remindDays === d}
            onClick={() => onRemindDays(d)}
            className={`flex items-center justify-between rounded-[10px] border px-4 py-3 text-[13px] font-semibold transition-colors duration-150 focus:outline-none focus-visible:ring-2 focus-visible:ring-acc-bd ${
              remindDays === d
                ? "border-acc-bd bg-chipbg text-text"
                : "border-hair bg-panel text-text hover:border-acc-bd"
            }`}
          >
            <span>{d === 1 ? "1 day before" : `${d} days before`}</span>
            <span
              className={`text-[12px] font-medium tabular-nums ${
                remindDays === d ? "text-acc-tx" : "text-sec"
              }`}
            >
              {remindDate(chargeISO, d, locale)}
            </span>
          </button>
        ))}
      </div>

      <div className="mt-4 rounded-[11px] border border-hair bg-panel px-4 pb-3.5 pt-4">
        <div className="relative flex items-center justify-between px-[2px]" aria-hidden="true">
          <span className="absolute left-[6px] right-[6px] top-1/2 h-px -translate-y-1/2 bg-rail" />
          {Array.from({ length: days + 1 }, (_, i) => (
            <i
              key={i}
              className={`relative h-[10px] w-[10px] rounded-full transition-colors duration-200 ${
                i === remindIdx && i > 0 && i < days
                  ? "bg-warnraw"
                  : i === days
                    ? "border-[1.5px] border-sec bg-rail"
                    : i === 0
                      ? "bg-accent"
                      : "bg-acc-b"
              }`}
            />
          ))}
        </div>
        <div className="mt-2 flex justify-between text-[9px] font-bold tracking-[0.06em] text-ter">
          <span>TODAY</span>
          <span className="tabular-nums">{chargeShort} · TRIAL ENDS</span>
        </div>
        <p className="mt-2.5 text-[11px] leading-relaxed text-sec">
          {remindDays === null
            ? "Pick a day and the amber dot shows when the email lands."
            : `The amber dot is your reminder email — ${remindDate(chargeISO, remindDays, locale)}.`}
        </p>
      </div>

      <p className="mt-4 text-center text-[11.5px] text-sec">
        Cancelling takes one click in Settings. No penalties, no fees.
      </p>
      <button
        className={`mt-2.5 ${btnPrimary}`}
        disabled={remindDays === null}
        onClick={onContinue}
        data-testid="remind-continue"
      >
        Continue
      </button>
    </section>
  );
}
