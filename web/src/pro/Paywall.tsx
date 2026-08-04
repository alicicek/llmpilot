import { useEffect, useRef, useState } from "react";
import type { License, Quote, QuoteEcho, Rung } from "../api.ts";
import { StepDots } from "../shell/StepDots.tsx";
import { licenseErrorCopy } from "./errors.ts";
import { CloseButton } from "./CloseButton.tsx";
import { Remind } from "./Remind.tsx";
import { chargeInstant, remindDate, rungCopy, STATEMENT_NOTE } from "./ladder.ts";

// The reshaped paywall (owner 2026-07-31, reworked for SPEC 1.2.6): ONE
// offer — the free trial that converts to £9.99 charged once, lifetime —
// rendered from the server quote in two steps. The OFFER states the terms
// (headline, timeline, no payment due today); its CTA advances to the
// REMINDER screen (pro/Remind.tsx), which owns the reminder-timing choice
// and the trial-starting CTA — checkout begins there. Pressing close IS the
// decline: the first ✕ surfaces the standing £5.99 offer once, the second ✕
// closes for real, from either step. Copy obeys VOICE.md; every figure comes
// from the quote — no quote, no consent, no checkout. The reminder choice is
// a REAL control: it rides the checkout call, lands on the license row, and
// the worker's hourly sweep honors it.

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
  // A failed checkout START (the POST, not the payment). Rendered on the
  // reminder screen so the buyer sees the remedy next to the button they
  // pressed — a flash elsewhere reads as a dead button under a modal.
  checkoutError?: string | null;
  // True while a checkout start is in flight or its window is being handed
  // off — the button shows busy instead of silently swallowing clicks.
  busy?: boolean;
  /** first-run step dots — base is the offer step's index. Absent outside
   *  the guided flow (the reopened overlay is not a guided run). */
  dots?: { base: number; total: number };
  /** fleet size for the activation facts; 0/undefined omits the line. */
  accountsWatched?: number;
}

// bg-acc-tx (dark:bg-accent) keeps white text ≥4.5:1 at this size — the app's
// proven filled-button idiom (Toolbar/FirstRun); the light accent alone is 4:1.
const btnPrimary =
  "rounded-lg bg-acc-tx px-4 py-2 text-[13px] font-semibold text-white transition-colors duration-150 disabled:opacity-50 dark:bg-accent focus:outline-none focus-visible:ring-2 focus-visible:ring-acc-bd";
const btnGhost =
  "text-[12px] text-sec underline-offset-2 hover:underline focus:outline-none focus-visible:underline";

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

// The one consent card: price line, timeline, statement note. Used by the
// main ask AND the trial-restart (paused) screen — every screen that starts
// a card-upfront trial owes the same dates. The reminder-timing control
// lives on the next screen (pro/Remind.tsx); the timeline reflects the
// current choice.
function OfferCard({
  copy,
  quote,
  remindDays,
  locale,
}: {
  copy: NonNullable<ReturnType<typeof rungCopy>>;
  quote: Quote;
  remindDays: number;
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
      <p className="mt-3 text-[11px] text-ter">{STATEMENT_NOTE}</p>
    </div>
  );
}

export function Paywall({ license, quote, quoteFailed, onRetryQuote, onCheckout, onRecover, onDismiss, caughtThisWeek, handoffURL, checkoutError, busy, dots, accountsWatched }: PaywallProps) {
  // The decline walk: the offer → (first ✕) the standing lower price →
  // (second ✕ or "No thanks") closed. ask advances offer → remind; the
  // reminder screen owns checkout.
  const [declined, setDeclined] = useState(false);
  const [remindDays, setRemindDays] = useState(1);
  const [ask, setAsk] = useState<"offer" | "remind">("offer");
  // The amount the buyer committed to, kept for the activation facts —
  // license state doesn't echo the price back.
  const [committedAmount, setCommittedAmount] = useState<string | null>(null);
  const locale = typeof navigator !== "undefined" ? navigator.language : "en-GB";
  const fullCopy = quote ? rungCopy("full", quote, locale) : null;

  // A quote whose TERMS changed (the worker's quote_stale refusal reloads
  // it) bounces the ask back to the offer: re-consent must happen on the
  // screen that states the new terms, never on the reminder screen
  // mid-flight. Compared by terms, not object identity — useQuote re-quotes
  // on a 15-minute TTL and every fetch parses fresh, so an identity compare
  // would throw the buyer off the commit screen on a routine re-quote. And
  // never while a payment window is open: yanking the handoff line invites
  // the re-click that orphans a live Session's activation poll.
  const termsSig = (q: Quote) => `${q.trial_days}|${JSON.stringify(q.prices)}`;
  const seenQuote = useRef<Quote | null>(quote);
  useEffect(() => {
    // Reloads pass through null (useQuote clears synchronously), so compare
    // against the last NON-null quote or the bounce never fires.
    if (quote && seenQuote.current && !handoffURL && termsSig(quote) !== termsSig(seenQuote.current))
      setAsk("offer");
    if (quote) seenQuote.current = quote;
  }, [quote, handoffURL]);

  if (license.active) {
    // Screen 5, facts only: what is watched, what it does, when the reminder
    // lands, what is charged and when. Never invent a fact — a missing one
    // (a reload dropped the committed amount) omits its row.
    const charge = license.trial?.charge_date;
    const chargeLong = charge
      ? new Date(charge).toLocaleDateString(locale, { day: "numeric", month: "long" })
      : null;
    const facts: string[] = [];
    if (accountsWatched && accountsWatched > 0)
      facts.push(`Watching ${accountsWatched} ${accountsWatched === 1 ? "account" : "accounts"}`);
    facts.push("Switches you before the wall");
    if (charge) facts.push(`Reminder email — ${remindDate(charge, remindDays, locale)}`);
    if (chargeLong && committedAmount) facts.push(`${committedAmount} once — ${chargeLong}`);
    return (
      <section
        className="mx-auto w-[440px] max-w-[92vw] animate-[rise-in_200ms_ease-out_both] text-center"
        aria-live="polite"
      >
        {dots && <StepDots step={dots.base + 2} total={dots.total} />}
        <p className="text-[15px] font-semibold text-ok-tx">Pro is on</p>
        <ul className="mx-auto mt-3 w-[320px] max-w-full rounded-[11px] border border-hair bg-panel text-left">
          {facts.map((f) => (
            <li
              key={f}
              className="border-b border-hairsoft px-4 py-2 text-[12.5px] tabular-nums last:border-b-0"
            >
              {f}
            </li>
          ))}
        </ul>
        {onDismiss && (
          <button className={`mt-5 ${btnPrimary}`} onClick={onDismiss}>
            Open the cockpit
          </button>
        )}
      </section>
    );
  }

  const paused = license.status === "lapsed" || license.status === "revoked";

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
    if (!declined && hasLowerOffer) {
      setDeclined(true);
      setAsk("offer");
    } else onDismiss?.();
  };

  const commitCopy = quote
    ? rungCopy(declined && !paused ? "discount_trial" : "full", quote, locale)
    : null;
  if (ask === "remind" && commitCopy && quote) {
    return (
      <Remind
        copy={commitCopy}
        quote={quote}
        remindDays={remindDays}
        onRemindDays={setRemindDays}
        locale={locale}
        busy={busy}
        handoffURL={handoffURL}
        checkoutError={checkoutError}
        onCommit={() => {
          setCommittedAmount(commitCopy.amount);
          onCheckout(commitCopy.rung, commitCopy.echo, remindDays);
        }}
        onBack={() => setAsk("offer")}
        onClose={!paused && onDismiss ? close : undefined}
        dots={dots && { step: dots.base + 1, total: dots.total }}
      />
    );
  }

  if (paused) {
    return (
      <section className="mx-auto w-[460px] max-w-[92vw] animate-[rise-in_200ms_ease-out_both]">
        {dots && <StepDots step={dots.base} total={dots.total} />}
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
        {/* Restarting the trial is the SAME card-upfront consent as the
            first one — the exact dates are owed here too, and the reminder
            screen (with its control) follows before checkout. */}
        {fullCopy && quote ? (
          <>
            <OfferCard copy={fullCopy} quote={quote} remindDays={remindDays} locale={locale} />
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
            disabled={!fullCopy}
            onClick={() => setAsk("remind")}
          >
            {fullCopy && quote ? `Try it free for ${quote.trial_days} days` : "Turn on the autopilot"}
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
      <section className="relative mx-auto w-[460px] max-w-[92vw] animate-[rise-in_200ms_ease-out_both]">
        {dots && <StepDots step={dots.base} total={dots.total} />}
        {onDismiss && <CloseButton onClick={onDismiss} />}
        <h2 className="text-[16px] font-semibold">Turn on the autopilot</h2>
        {/* A quote_stale refusal lands HERE first (the reload nulls the
            quote) — the remedy for the button that was pressed must not be
            lost to the loading state. */}
        {checkoutError && (
          <p className="mt-3 rounded-lg border border-hair bg-panel px-3 py-2 text-[11.5px] text-sec" role="alert" data-testid="checkout-error">
            {checkoutError}
          </p>
        )}
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

  return (
    <section className="relative mx-auto w-[460px] max-w-[92vw] animate-[rise-in_200ms_ease-out_both]">
      {dots && <StepDots step={dots.base} total={dots.total} />}
      {onDismiss && <CloseButton onClick={close} />}
      <h2 className="text-[16px] font-semibold">{copy.headline}</h2>
      <p className="mt-2 text-[12.5px] leading-relaxed text-sec">{copy.lede}</p>

      <OfferCard copy={copy} quote={quote} remindDays={remindDays} locale={locale} />

      {licenseErrorCopy(license.error_code) && (
        <p className="mt-3 rounded-lg border border-hair bg-panel px-3 py-2 text-[11.5px] text-sec" role="alert">
          {licenseErrorCopy(license.error_code)}
        </p>
      )}

      {/* A quote_stale refusal bounces here with the reloaded terms — its
          remedy line renders beside the terms being re-consented to. */}
      {checkoutError && (
        <p className="mt-3 rounded-lg border border-hair bg-panel px-3 py-2 text-[11.5px] text-sec" role="alert" data-testid="checkout-error">
          {checkoutError}
        </p>
      )}

      <p className="mt-4 text-center text-[11.5px] text-sec">No payment due today.</p>
      <div className="mt-2 flex flex-col gap-2.5">
        <button className={btnPrimary} onClick={() => setAsk("remind")}>
          Try it free for {quote.trial_days} days
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
