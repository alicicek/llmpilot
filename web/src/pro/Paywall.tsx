import { useState } from "react";
import type { License, Quote, QuoteEcho, Rung } from "../api.ts";
import { licenseErrorCopy } from "./errors.ts";
import { nextRung, rungCopy, STATEMENT_NOTE } from "./ladder.ts";

// The decline-ladder paywall. Copy obeys VOICE.md: sentence case, no exclamation
// marks, verb+object CTAs, and the honest "charged once — we cancel the renewal"
// framing beside the price. The rung state walks full → discount → no-card as the
// buyer declines; the no-card rung is hidden once the native marker reports it
// was used. Activation is silent: on the SSE license flip this renders "Pro is on".
// Every price/trial figure comes from the server quote — no quote, no consent,
// no checkout.

interface PaywallProps {
  license: License;
  // quote is the worker's authoritative terms; null while loading or failed.
  quote: Quote | null;
  quoteFailed?: boolean;
  onRetryQuote?: () => void;
  // onCheckout opens the returned checkout URL (native intercepts; browser
  // follows). The parent decides navigate-vs-simulate so tests stay daemon-free.
  // echo is the exact consent statement this paywall rendered.
  onCheckout: (rung: Rung, echo: QuoteEcho) => void;
  onRecover: () => void;
  onDismiss?: () => void;
  // caughtThisWeek is the buyer's own honest number for the paused variant;
  // undefined omits the line entirely (never invent a stat).
  caughtThisWeek?: number;
  handoffURL?: string | null;
}

// bg-acc-tx (dark:bg-accent) keeps white text ≥4.5:1 at this size — the app's
// proven filled-button idiom (Toolbar/FirstRun); the light accent alone is 4:1.
const btnPrimary =
  "rounded-lg bg-acc-tx px-4 py-2 text-[13px] font-semibold text-white transition-colors duration-150 disabled:opacity-50 dark:bg-accent focus:outline-none focus-visible:ring-2 focus-visible:ring-acc-bd";
const btnGhost =
  "text-[12px] text-sec underline-offset-2 hover:underline focus:outline-none focus-visible:underline";

export function Paywall({ license, quote, quoteFailed, onRetryQuote, onCheckout, onRecover, onDismiss, caughtThisWeek, handoffURL }: PaywallProps) {
  const [rung, setRung] = useState<Rung>("full");
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
        <div className="mt-4 flex items-center gap-4">
          <button
            className={btnPrimary}
            disabled={!fullCopy}
            onClick={() => fullCopy && onCheckout("full", fullCopy.echo)}
          >
            Turn on the autopilot
          </button>
          <button className={btnGhost} onClick={onRecover}>
            Restore a purchase
          </button>
        </div>
        {fullCopy ? (
          <p className="mt-2 text-[11.5px] text-sec">{fullCopy.terms}</p>
        ) : quoteFailed ? (
          <p className="mt-2 text-[11.5px] text-sec" role="alert">
            The price could not be loaded — check your connection.{" "}
            {onRetryQuote && (
              <button className={btnGhost} onClick={onRetryQuote}>
                Try again
              </button>
            )}
          </p>
        ) : (
          <p className="mt-2 text-[11.5px] text-sec" role="status">
            Loading the price…
          </p>
        )}
      </section>
    );
  }

  const copy = quote ? rungCopy(rung, quote, locale) : null;
  if (!copy) {
    // No server quote means no honest terms to consent to — never render a
    // paywall that hides the price.
    return (
      <section className="mx-auto mt-14 w-[460px] max-w-[92vw]">
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
        {onDismiss && (
          <button className="mt-5 block text-[11.5px] text-ter hover:underline" onClick={onDismiss}>
            Keep using the free tools for now
          </button>
        )}
      </section>
    );
  }

  const advance = () => {
    const next = nextRung(rung, license.nocard_trial_used);
    if (next) setRung(next);
  };

  return (
    <section className="mx-auto mt-14 w-[460px] max-w-[92vw]">
      <h2 className="text-[16px] font-semibold">{copy.headline}</h2>
      <p className="mt-2 text-[12.5px] leading-relaxed text-sec">
        The autopilot switches accounts before you hit a wall, revives a stale account once a
        refresh proves it live, and fires your scheduled nudges — so you never lose your place
        mid-thought.
      </p>

      <div className="mt-4 rounded-[11px] border border-hair bg-panel p-4">
        {copy.amount && (
          <p className="text-[15px] font-semibold">
            {copy.approx ? "≈ " : ""}
            {copy.amount}
            {copy.rung === "full" ? " once" : ""}
          </p>
        )}
        <p className={`${copy.amount ? "mt-1 " : ""}text-[12.5px] leading-relaxed text-text`}>{copy.terms}</p>
        {copy.rung !== "nocard_trial" && (
          <p className="mt-2 text-[11px] text-ter">{STATEMENT_NOTE}</p>
        )}
      </div>

      {handoffURL && (
        <p className="mt-3 text-[11.5px] text-sec" role="status" data-testid="checkout-handoff" data-url={handoffURL}>
          Opening secure checkout…
        </p>
      )}

      {licenseErrorCopy(license.error_code) && (
        <p className="mt-3 rounded-lg border border-hair bg-panel px-3 py-2 text-[11.5px] text-sec" role="alert">
          {licenseErrorCopy(license.error_code)}
        </p>
      )}

      <div className="mt-4 flex flex-col gap-2.5">
        <button className={btnPrimary} onClick={() => onCheckout(copy.rung, copy.echo)}>
          {copy.cta}
        </button>
        <div className="flex items-center justify-between">
          {copy.declineLabel ? (
            <button className={btnGhost} onClick={advance}>
              {copy.declineLabel}
            </button>
          ) : (
            <span />
          )}
          <button className={btnGhost} onClick={onRecover}>
            Restore a purchase
          </button>
        </div>
      </div>

      {onDismiss && (
        <button className="mt-5 block text-[11.5px] text-ter hover:underline" onClick={onDismiss}>
          Keep using the free tools for now
        </button>
      )}
    </section>
  );
}
