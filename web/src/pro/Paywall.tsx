import { useState } from "react";
import type { License, Quote, QuoteEcho, Rung } from "../api.ts";
import { licenseErrorCopy } from "./errors.ts";
import { remindDate, rungCopy, STATEMENT_NOTE } from "./ladder.ts";

// The reshaped paywall (owner 2026-07-31): ONE offer — the free trial that
// converts to £9.99 charged once, lifetime — with the trial timeline and the
// reminder-timing choice rendered from the server quote. Pressing close IS
// the decline: the first ✕ surfaces the standing £5.99 offer once, the
// second ✕ closes for real. No free-tools link, no no-card rung. Copy obeys
// VOICE.md; every figure comes from the quote — no quote, no consent, no
// checkout. The reminder choice is a REAL control: it rides the checkout
// call, lands on the license row, and the worker's hourly sweep honors it.

interface PaywallProps {
  license: License;
  // quote is the worker's authoritative terms; null while loading or failed.
  quote: Quote | null;
  quoteFailed?: boolean;
  onRetryQuote?: () => void;
  // onCheckout opens the returned checkout URL (native intercepts; browser
  // follows). The parent decides navigate-vs-simulate so tests stay daemon-free.
  // echo is the exact consent statement this paywall rendered; remindDays is
  // the buyer's reminder-timing choice (1 or 2 days before the charge).
  onCheckout: (rung: Rung, echo: QuoteEcho, remindDays: number) => void;
  onRecover: () => void;
  onDismiss?: () => void;
  // caughtThisWeek is the buyer's own honest number for the paused variant;
  // undefined omits the line entirely (never invent a stat).
  caughtThisWeek?: number;
  handoffURL?: string | null;
  // A failed checkout START (the POST, not the payment). Rendered here so the
  // buyer sees the remedy next to the button they pressed — a flash elsewhere
  // reads as a dead button under a modal.
  checkoutError?: string | null;
  // True while a checkout start is in flight or its window is being handed
  // off — the button shows busy instead of silently swallowing clicks.
  busy?: boolean;
}

// bg-acc-tx (dark:bg-accent) keeps white text ≥4.5:1 at this size — the app's
// proven filled-button idiom (Toolbar/FirstRun); the light accent alone is 4:1.
const btnPrimary =
  "rounded-lg bg-acc-tx px-4 py-2 text-[13px] font-semibold text-white transition-colors duration-150 disabled:opacity-50 dark:bg-accent focus:outline-none focus-visible:ring-2 focus-visible:ring-acc-bd";
const btnGhost =
  "text-[12px] text-sec underline-offset-2 hover:underline focus:outline-none focus-visible:underline";

function CloseButton({ onClick }: { onClick: () => void }) {
  return (
    <button
      aria-label="Close the paywall"
      data-testid="paywall-close"
      className="absolute right-0 top-0 flex h-7 w-7 items-center justify-center rounded-full border border-hair bg-panel text-[13px] text-sec hover:text-text focus:outline-none focus-visible:ring-2 focus-visible:ring-acc-bd"
      onClick={onClick}
    >
      ✕
    </button>
  );
}

// The trial timeline: today → the chosen reminder date → the one charge.
// Every figure comes from the quote; the DATES are derived from the trial
// length at render time rather than read from the quote's charge_date —
// a quote fetched at app open can be hours old by the time the paywall
// shows, and Stripe anchors the trial at checkout COMPLETION, so the
// freshest honest date is "now + trial_days". Residual drift only exists
// while the payment window itself sits open; it can only move the charge
// LATER (more free days), and the reminder email states the subscription's
// real trial end.
function chargeInstant(quote: Quote): string {
  return new Date(Date.now() + quote.trial_days * 24 * 60 * 60 * 1000).toISOString();
}

function TrialTimeline({
  quote,
  amount,
  approx,
  remindDays,
  locale,
}: {
  quote: Quote;
  amount: string;
  approx: boolean;
  remindDays: number;
  locale: string;
}) {
  const amt = `${approx ? "≈ " : ""}${amount}`;
  const chargeISO = chargeInstant(quote);
  const stops = [
    { when: "Today", why: "The autopilot turns on. Every Pro feature, free.", tone: "bg-accent" },
    {
      when: remindDate(chargeISO, remindDays, locale),
      why: "We email you a reminder before anything is charged.",
      tone: "bg-warn",
    },
    {
      when: new Date(chargeISO).toLocaleDateString(locale, { day: "numeric", month: "long" }),
      why: `${amt}, charged once. We cancel the renewal automatically. Yours for life.`,
      tone: "border-[1.5px] border-sec bg-rail",
    },
  ];
  return (
    <ol className="mt-4 list-none">
      {stops.map((s, i) => (
        <li key={s.when + i} className="flex gap-3">
          <div className="flex w-[14px] flex-col items-center">
            <span className={`mt-[3px] h-[10px] w-[10px] flex-none rounded-full ${s.tone}`} aria-hidden="true" />
            {i < stops.length - 1 && <span className="min-h-[20px] w-px flex-1 bg-rail" aria-hidden="true" />}
          </div>
          <div className="pb-3.5">
            <div className="text-[12px] font-bold tabular-nums">{s.when}</div>
            <div className="text-[11.5px] text-sec">{s.why}</div>
          </div>
        </li>
      ))}
    </ol>
  );
}

// The one consent card: price line, timeline, reminder choice, statement
// note. Used by the main ask AND the trial-restart (paused) screen — every
// screen that starts a card-upfront trial owes the same dates and control.
function OfferCard({
  copy,
  quote,
  remindDays,
  onRemindDays,
  locale,
}: {
  copy: NonNullable<ReturnType<typeof rungCopy>>;
  quote: Quote;
  remindDays: number;
  onRemindDays: (d: number) => void;
  locale: string;
}) {
  return (
    <div className="mt-4 rounded-[11px] border border-hair bg-panel p-4">
      <p className="text-[15px] font-semibold tabular-nums">
        {copy.strikeAmount && (
          <s className="mr-1.5 text-[13px] font-medium text-ter">
            {copy.approx ? "≈ " : ""}
            {copy.strikeAmount}
          </s>
        )}
        {copy.approx ? "≈ " : ""}
        {copy.amount} <span className="text-[11.5px] font-medium text-sec">{copy.beside}</span>
      </p>
      <TrialTimeline
        quote={quote}
        amount={copy.amount}
        approx={copy.approx}
        remindDays={remindDays}
        locale={locale}
      />
      <div className="mt-1 border-t border-hairsoft pt-3">
        <p className="text-[12px] font-semibold">When should we remind you?</p>
        <div className="mt-2 flex gap-2" role="group" aria-label="When should we remind you?">
          {[2, 1].map((d) => (
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
                {remindDate(chargeInstant(quote), d, locale)}
              </span>
            </button>
          ))}
        </div>
      </div>
      <p className="mt-3 text-[11px] text-ter">{STATEMENT_NOTE}</p>
    </div>
  );
}

export function Paywall({ license, quote, quoteFailed, onRetryQuote, onCheckout, onRecover, onDismiss, caughtThisWeek, handoffURL, checkoutError, busy }: PaywallProps) {
  // The decline walk: the offer → (first ✕) the standing lower price →
  // (second ✕ or "No thanks") closed.
  const [declined, setDeclined] = useState(false);
  const [remindDays, setRemindDays] = useState(1);
  const locale = typeof navigator !== "undefined" ? navigator.language : "en-GB";
  const fullCopy = quote ? rungCopy("full", quote, locale) : null;

  if (license.active) {
    return (
      <section className="mx-auto mt-16 w-[440px] max-w-[92vw] text-center" aria-live="polite">
        <p className="text-[15px] font-semibold text-ok-tx">Pro is on</p>
        <p className="mt-1.5 text-[12.5px] text-sec">
          The autopilot is watching every account. You can close this and get back to work.
        </p>
        {onDismiss && (
          <button className={`mt-4 ${btnPrimary}`} onClick={onDismiss}>
            Open the cockpit
          </button>
        )}
      </section>
    );
  }

  const paused = license.status === "lapsed" || license.status === "revoked";
  if (paused) {
    return (
      <section className="mx-auto mt-16 w-[460px] max-w-[92vw]">
        <h2 className="text-[15px] font-semibold">Your trial ended — the autopilot is paused</h2>
        <p className="mt-1.5 text-[12.5px] leading-relaxed text-sec">
          Your schedules are kept and nothing was deleted. Switching, statusline, and analytics keep
          working. Turn the autopilot back on to have it watch your windows again.
        </p>
        {caughtThisWeek !== undefined && caughtThisWeek > 0 && (
          <p className="mt-2 text-[12.5px] text-text">
            While it ran, the autopilot caught {caughtThisWeek}{" "}
            {caughtThisWeek === 1 ? "window" : "windows"} this week.
          </p>
        )}
        {checkoutError && (
          <p className="mt-3 rounded-lg border border-hair bg-panel px-3 py-2 text-[11.5px] text-sec" role="alert" data-testid="checkout-error">
            {checkoutError}
          </p>
        )}
        {handoffURL && (
          <p className="mt-3 text-[11.5px] text-sec" role="status" data-testid="checkout-handoff" data-url={handoffURL}>
            Checkout is open in the payment window — finish there, or start again here.
          </p>
        )}
        {/* Restarting the trial is the SAME card-upfront consent as the
            first one — the exact dates and the reminder control are owed
            here too, not just on the first ask. */}
        {fullCopy && quote ? (
          <>
            <OfferCard
              copy={fullCopy}
              quote={quote}
              remindDays={remindDays}
              onRemindDays={setRemindDays}
              locale={locale}
            />
            <p className="mt-3 text-[11.5px] text-sec">No payment due today.</p>
          </>
        ) : quoteFailed ? (
          <p className="mt-3 text-[11.5px] text-sec" role="alert">
            The price could not be loaded — check your connection.{" "}
            {onRetryQuote && (
              <button className={btnGhost} onClick={onRetryQuote}>
                Try again
              </button>
            )}
          </p>
        ) : (
          <p className="mt-3 text-[11.5px] text-sec" role="status">
            Loading the price…
          </p>
        )}
        <div className="mt-3 flex items-center gap-4">
          <button
            className={btnPrimary}
            disabled={!fullCopy || busy}
            onClick={() => fullCopy && onCheckout("full", fullCopy.echo, remindDays)}
          >
            {busy ? "Opening checkout…" : fullCopy ? fullCopy.cta : "Turn on the autopilot"}
          </button>
          <button className={btnGhost} onClick={onRecover}>
            Restore a purchase
          </button>
        </div>
      </section>
    );
  }

  const copy = quote ? rungCopy(declined ? "discount_trial" : "full", quote, locale) : null;
  if (!copy || !quote) {
    // No server quote means no honest terms to consent to — never render a
    // paywall that hides the price. Without terms there is no decline offer
    // either: the ✕ just closes.
    return (
      <section className="relative mx-auto mt-14 w-[460px] max-w-[92vw]">
        {onDismiss && <CloseButton onClick={onDismiss} />}
        <h2 className="text-[16px] font-semibold">Turn on the autopilot</h2>
        <div className="mt-4 rounded-[11px] border border-hair bg-panel p-4">
          {quoteFailed ? (
            <>
              <p className="text-[12.5px] leading-relaxed text-text" role="alert">
                The price could not be loaded — check your connection.
              </p>
              {onRetryQuote && (
                <button className={`mt-2 ${btnGhost}`} onClick={onRetryQuote}>
                  Try again
                </button>
              )}
            </>
          ) : (
            <p className="text-[12.5px] leading-relaxed text-sec" role="status">
              Loading the price…
            </p>
          )}
        </div>
      </section>
    );
  }

  // The decline offer only exists while it is genuinely LOWER: under an
  // active launch window full already sells at the discount amount, and
  // striking through the same price it offers would be a lying screen —
  // in that configuration the close just closes.
  const declineCopy = quote ? rungCopy("discount_trial", quote, locale) : null;
  const hasLowerOffer =
    declineCopy?.echo.amount_minor !== undefined &&
    fullCopy?.echo.amount_minor !== undefined &&
    declineCopy.echo.amount_minor < fullCopy.echo.amount_minor;
  const close = () => {
    if (!declined && hasLowerOffer) setDeclined(true);
    else onDismiss?.();
  };

  return (
    <section className="relative mx-auto mt-14 w-[460px] max-w-[92vw]">
      {onDismiss && <CloseButton onClick={close} />}
      <h2 className="text-[16px] font-semibold">{copy.headline}</h2>
      <p className="mt-2 text-[12.5px] leading-relaxed text-sec">{copy.lede}</p>

      <OfferCard
        copy={copy}
        quote={quote}
        remindDays={remindDays}
        onRemindDays={setRemindDays}
        locale={locale}
      />

      {handoffURL && (
        <p className="mt-3 text-[11.5px] text-sec" role="status" data-testid="checkout-handoff" data-url={handoffURL}>
          Checkout is open in the payment window — finish there, or start again here.
        </p>
      )}

      {licenseErrorCopy(license.error_code) && (
        <p className="mt-3 rounded-lg border border-hair bg-panel px-3 py-2 text-[11.5px] text-sec" role="alert">
          {licenseErrorCopy(license.error_code)}
        </p>
      )}

      {checkoutError && (
        <p className="mt-3 rounded-lg border border-hair bg-panel px-3 py-2 text-[11.5px] text-sec" role="alert" data-testid="checkout-error">
          {checkoutError}
        </p>
      )}

      <p className="mt-4 text-center text-[11.5px] text-sec">No payment due today.</p>
      <div className="mt-2 flex flex-col gap-2.5">
        <button className={btnPrimary} disabled={busy} onClick={() => onCheckout(copy.rung, copy.echo, remindDays)}>
          {busy ? "Opening checkout…" : copy.cta}
        </button>
        <div className="flex items-center justify-between">
          {declined && onDismiss ? (
            <button className={btnGhost} onClick={onDismiss}>
              No thanks
            </button>
          ) : (
            <span />
          )}
          <button className={btnGhost} onClick={onRecover}>
            Restore a purchase
          </button>
        </div>
      </div>
    </section>
  );
}
