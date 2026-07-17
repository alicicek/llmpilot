// The decline ladder (owner design): full price → decline → discounted trial →
// decline → no-card trial. Copy obeys VOICE.md — sentence case, no exclamation
// marks, no "unlock"/"premium", CTAs are verb+object. Consumer-law checklist
// (a): every rung states trial length, exact price, and the exact charge date —
// all read from the worker's quote (api.fetchQuote), never compiled into the
// client. The shown terms ride back into checkout as RungCopy.echo, where the
// worker refuses any drift (409 quote_stale) before a Session exists.

import type { Quote, QuoteEcho, Rung } from "../api.ts";

export const STATEMENT_NOTE = "Appears on your statement as LINK.COM* LLMPILOT.DEV.";

export interface RungCopy {
  rung: Rung;
  headline: string;
  amount: string; // the price line, or "" for the no-card rung
  approx: boolean;
  terms: string; // the exact terms (length · price · charge date · cancel)
  cta: string; // verb + object
  declineLabel: string | null; // advances to the next rung; null on the last
  /** the exact shown terms, echoed into checkout for the binding compare. */
  echo: QuoteEcho;
}

// formatAmount renders minor units for the buyer's locale with the same
// Intl.NumberFormat rule the worker's checkout page uses, so the paywall and
// the payment page always agree on the string.
export function formatAmount(locale: string, currency: string, amountMinor: number): string {
  const formatter = new Intl.NumberFormat(locale, { style: "currency", currency: currency.toUpperCase() });
  const options = formatter.resolvedOptions();
  const digits = options.maximumFractionDigits ?? options.minimumFractionDigits ?? 2;
  return formatter.format(amountMinor / 10 ** digits);
}

// localAmount picks the quoted currency GB/US buyers are charged exactly.
// Other locales pay Stripe's converted amount at the payment page, so the
// paywall marks the quoted figure approximate rather than promising a number
// it can't guarantee (F7).
export function localAmount(
  amounts: Record<string, number>,
  locale: string,
): { text: string; approx: boolean; echo: QuoteEcho } | null {
  const loc = locale.toLowerCase();
  const exact = loc === "en-us" || loc.endsWith("-us") ? "usd" : loc === "en-gb" || loc.endsWith("-gb") ? "gbp" : null;
  for (const currency of [...(exact ? [exact] : []), "gbp", ...Object.keys(amounts)]) {
    const minor = amounts[currency];
    if (minor === undefined) continue;
    return {
      text: formatAmount(locale, currency, minor),
      approx: currency !== exact,
      echo: { currency, amount_minor: minor },
    };
  }
  return null;
}

// chargeDate formats the worker's quoted charge instant for the buyer's locale.
export function chargeDate(iso: string, locale: string): string {
  return new Date(iso).toLocaleDateString(locale, { day: "numeric", month: "long", year: "numeric" });
}

// nextRung walks the ladder. The no-card rung is skipped when the native marker
// says this Apple ID already used it (advisor verdict item 3).
export function nextRung(current: Rung, nocardUsed: boolean): Rung | null {
  if (current === "full") return "discount_trial";
  if (current === "discount_trial") return nocardUsed ? null : "nocard_trial";
  return null;
}

// rungCopy builds one rung's consent copy from the quote. null means the quote
// cannot state this rung's price — the caller renders the retry state instead
// of a paywall that hides the amount.
export function rungCopy(rung: Rung, quote: Quote, locale: string): RungCopy | null {
  switch (rung) {
    case "full": {
      const a = localAmount(quote.prices.full, locale);
      if (!a) return null;
      return {
        rung,
        headline: "Turn on the autopilot",
        amount: a.text,
        approx: a.approx,
        terms: `${a.text} — charged once. We cancel the renewal automatically, so you are never billed again.`,
        cta: "Turn on the autopilot",
        declineLabel: "Try it free first",
        echo: a.echo,
      };
    }
    case "discount_trial": {
      const a = localAmount(quote.prices.discount, locale);
      if (!a) return null;
      return {
        rung,
        headline: "Try the autopilot free",
        amount: a.text,
        approx: a.approx,
        terms: `${quote.trial_days}-day free trial, then ${a.text} charged once on ${chargeDate(quote.charge_date, locale)}. Cancel anytime in Settings.`,
        cta: "Start the free trial",
        declineLabel: "Start without a card",
        echo: { trial_days: quote.trial_days, ...a.echo },
      };
    }
    case "nocard_trial":
      return {
        rung,
        headline: "Try it — no card",
        amount: "",
        approx: false,
        terms: `${quote.trial_days}-day free trial, no card. The autopilot turns on now and pauses when the trial ends.`,
        cta: "Start the free trial",
        declineLabel: null,
        echo: { trial_days: quote.trial_days },
      };
  }
}
