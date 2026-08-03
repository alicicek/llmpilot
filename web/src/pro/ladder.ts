// The reshaped ask (owner 2026-07-31): ONE offer — a free trial that
// converts to the full £9.99 charged once, lifetime. Pressing close is the
// decline, and it surfaces the standing £5.99 rung once (same trial, lower
// price, no invented urgency — the Price exists year-round). The no-card
// rung stays server-side but is never offered here. Copy obeys VOICE.md:
// sentence case, no exclamation marks, CTAs are verb+object. Consumer-law
// checklist (a): every offer states trial length, exact price, and the exact
// charge date — all read from the worker's quote (api.fetchQuote), never
// compiled into the client. The shown terms ride back into checkout as
// RungCopy.echo, where the worker refuses any drift (409 quote_stale)
// before a Session exists.

import type { Quote, QuoteEcho, Rung } from "../api.ts";

export const STATEMENT_NOTE = "Appears on your statement as LINK.COM* LLMPILOT.DEV.";

export interface RungCopy {
  rung: Rung;
  headline: string;
  /** One-sentence support line under the headline. */
  lede: string;
  amount: string;
  /** The full-rung amount shown struck through beside a decline-offer price. */
  strikeAmount?: string;
  approx: boolean;
  /** The price-line suffix beside the amount (trial length · charged once · lifetime). */
  beside: string;
  cta: string;
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

/** remindDate resolves the reminder stop's calendar date from the quoted
 *  charge instant and the buyer's chosen offset — the picker always shows
 *  the real date beside the offset (the honest form of the control). */
export function remindDate(chargeISO: string, daysBefore: number, locale: string): string {
  const t = new Date(new Date(chargeISO).getTime() - daysBefore * 24 * 60 * 60 * 1000);
  return t.toLocaleDateString(locale, { day: "numeric", month: "long" });
}

// rungCopy builds one offer's consent copy from the quote. null means the
// quote cannot state this offer's price — the caller renders the retry state
// instead of a paywall that hides the amount. The decline offer
// (discount_trial) also carries the struck full price it undercuts.
export function rungCopy(rung: Rung, quote: Quote, locale: string): RungCopy | null {
  const days = quote.trial_days;
  switch (rung) {
    case "full": {
      const a = localAmount(quote.prices.full, locale);
      if (!a) return null;
      return {
        rung,
        headline: `Try the autopilot free for ${days} days`,
        lede: "It switches before the wall, revives stale accounts, and fires your scheduled windows — you never lose your place mid-thought.",
        amount: a.text,
        approx: a.approx,
        beside: `after a ${days}-day free trial · charged once · yours for life`,
        cta: `Start the ${days}-day free trial`,
        echo: { trial_days: days, ...a.echo },
      };
    }
    case "discount_trial": {
      const a = localAmount(quote.prices.discount, locale);
      if (!a) return null;
      const full = localAmount(quote.prices.full, locale);
      // The struck reference price only renders when it is genuinely
      // higher — under an active launch window both rungs quote the same
      // amount, and striking a price equal to the offer would be a fake
      // markdown (the class VOICE bans).
      const strike =
        full && a.echo.amount_minor !== undefined && full.echo.amount_minor !== undefined &&
        full.echo.amount_minor > a.echo.amount_minor
          ? full.text
          : undefined;
      return {
        rung,
        headline: "Same trial, lower price",
        lede: `${a.text} is the standing lower price, no deadline on it. Same ${days}-day free trial, same lifetime license.`,
        amount: a.text,
        strikeAmount: strike,
        approx: a.approx,
        beside: `after a ${days}-day free trial · charged once · yours for life`,
        cta: `Start the trial at ${a.text}`,
        echo: { trial_days: days, ...a.echo },
      };
    }
    case "nocard_trial":
      // Unlisted: the worker still sells it (support/CLI), the paywall never
      // renders it.
      return null;
  }
}
