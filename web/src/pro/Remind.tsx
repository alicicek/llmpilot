import type { Quote } from "../api.ts";
import { StepDots } from "../shell/StepDots.tsx";
import { CloseButton } from "./CloseButton.tsx";
import { chargeInstant, formatAmount, remindDate, type RungCopy } from "./ladder.ts";

// The reminder screen (SPEC 1.2.6 screen 4, heald's remind→commit shape):
// the headline IS the confirmation — it restates the live choice as a real
// date and re-renders when the choice changes. The trial rides a dot strip
// (free days, the reminder day in amber, the charge day last), the footer
// states the money fact, and THIS screen owns the trial-starting CTA —
// checkout begins here, never on the offer.

const btnPrimary =
  "rounded-lg bg-acc-tx px-4 py-2 text-[13px] font-semibold text-white transition-colors duration-150 disabled:opacity-50 dark:bg-accent focus:outline-none focus-visible:ring-2 focus-visible:ring-acc-bd";
const btnGhost =
  "text-[12px] text-sec underline-offset-2 hover:underline focus:outline-none focus-visible:underline";

export function Remind({
  copy,
  quote,
  remindDays,
  onRemindDays,
  locale,
  busy,
  handoffURL,
  checkoutError,
  onCommit,
  onBack,
  onClose,
  dots,
}: {
  copy: RungCopy;
  quote: Quote;
  remindDays: number;
  onRemindDays: (d: number) => void;
  locale: string;
  busy?: boolean;
  handoffURL?: string | null;
  checkoutError?: string | null;
  onCommit: () => void;
  onBack: () => void;
  onClose?: () => void;
  dots?: { step: number; total: number };
}) {
  const chargeISO = chargeInstant(quote);
  const charge = new Date(chargeISO);
  const chargeLong = charge.toLocaleDateString(locale, { day: "numeric", month: "long" });
  const chargeShort = charge
    .toLocaleDateString(locale, { day: "numeric", month: "short" })
    .toUpperCase();
  const remindLong = remindDate(chargeISO, remindDays, locale);
  const zero = formatAmount(locale, copy.echo.currency ?? "gbp", 0);
  const days = quote.trial_days;
  // trial_days is server-controlled: an offset that doesn't fit the trial
  // never renders as a chip, and the amber dot only marks a day strictly
  // inside the strip (index 0 is TODAY, the last is the charge).
  const offsets = [2, 1].filter((d) => d < days);
  const remindIdx = days - remindDays;

  return (
    <section className="relative mx-auto w-[460px] max-w-[92vw] animate-[rise-in_200ms_ease-out_both]">
      {dots && <StepDots {...dots} />}
      {onClose && <CloseButton onClick={onClose} />}
      <p className="text-[10px] font-bold tracking-[0.08em] text-ter">BEFORE ANYTHING IS CHARGED</p>
      <h2 className="mt-1.5 text-[16px] font-semibold tabular-nums" data-testid="remind-headline">
        We'll remind you on {remindLong}
      </h2>
      <p className="mt-1.5 text-[12.5px] leading-relaxed text-sec">
        One email before any charge — and cancelling is one click in Settings.
      </p>

      <div
        className="mt-4 flex gap-2"
        role="group"
        aria-label="When should we remind you?"
      >
        {offsets.map((d) => (
          <button
            key={d}
            aria-pressed={remindDays === d}
            onClick={() => onRemindDays(d)}
            className={`rounded-lg border px-3 py-1.5 text-left text-[11.5px] font-semibold tabular-nums transition-colors duration-150 focus:outline-none focus-visible:ring-2 focus-visible:ring-acc-bd ${
              remindDays === d
                ? // the app's proven filled-selection idiom — the tinted
                  // acc-a/acc-tx pair fails AA at this size (4.36:1)
                  "border-acc-bd bg-acc-tx text-white dark:bg-accent"
                : "border-hair bg-win text-sec hover:text-text"
            }`}
          >
            {d === 1 ? "1 day before" : `${d} days before`}
            <span className={`block text-[10.5px] font-medium ${remindDays === d ? "" : "text-ter"}`}>
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
              className={`relative h-[10px] w-[10px] rounded-full ${
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
          <span className="tabular-nums">{chargeShort} · CHARGES</span>
        </div>
        <p className="mt-2.5 text-[11px] leading-relaxed text-sec">
          The amber dot is the reminder email — {remindLong}.
        </p>
      </div>

      {handoffURL && (
        <p
          className="mt-3 text-[11.5px] text-sec"
          role="status"
          data-testid="checkout-handoff"
          data-url={handoffURL}
        >
          Checkout is open in the payment window — finish there, or start again here.
        </p>
      )}
      {checkoutError && (
        <p
          className="mt-3 rounded-lg border border-hair bg-panel px-3 py-2 text-[11.5px] text-sec"
          role="alert"
          data-testid="checkout-error"
        >
          {checkoutError}
        </p>
      )}

      {/* The commit screen states the exact amount (consumer-law rule in
          ladder.ts) — the spec's "nothing is charged before" fact rides the
          same line. */}
      <p className="mt-4 text-center text-[11.5px] tabular-nums text-sec">
        {zero} today · {copy.approx ? "≈ " : ""}
        {copy.amount} once on {chargeLong} — nothing before that
      </p>
      <div className="mt-2 flex flex-col gap-2.5">
        <button className={btnPrimary} disabled={busy} onClick={onCommit}>
          {busy ? "Opening checkout…" : copy.cta}
        </button>
        <div>
          <button className={btnGhost} onClick={onBack}>
            Back to the offer
          </button>
        </div>
      </div>
    </section>
  );
}
