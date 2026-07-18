// The ONE derivation of pre-checkout consent terms. The quote route, the
// checkout-time echo compare, and Session creation all read from here — a
// second copy of this logic is how displayed terms and charged terms drift.

import type Stripe from "stripe";
import type { WorkerEnv } from "../env.ts";
import type { Rung } from "../routes/checkout.ts";

export const DEFAULT_TRIAL_DAYS = 8;

/** The effective trial length: env.TRIAL_DAYS when sane (>=3), else the default. */
export function effectiveTrialDays(env: WorkerEnv): number {
  const configured = Number(env.TRIAL_DAYS);
  return Number.isInteger(configured) && configured >= 3 ? configured : DEFAULT_TRIAL_DAYS;
}

/** The launch-price window's end, or null when no window is configured.
 *  Both PRICE_LAUNCH and LAUNCH_ENDS_AT (RFC 3339) must be set — a real
 *  window with a real end date; there is no synthetic-urgency mode. */
export function launchEndsAt(env: WorkerEnv): Date | null {
  if (!env.PRICE_LAUNCH || !env.LAUNCH_ENDS_AT) return null;
  const t = Date.parse(env.LAUNCH_ENDS_AT);
  return Number.isNaN(t) ? null : new Date(t);
}

/** The window is [open, ends_at): at the boundary instant it is over. */
export function launchActive(env: WorkerEnv, now: Date): boolean {
  const ends = launchEndsAt(env);
  return ends !== null && now.getTime() < ends.getTime();
}

/** The ONE price-id resolution. The full rung sells at the launch price
 *  while the window is open; the ladder's discount rung never changes.
 *  Quote, echo compare, and Session creation must all pass the same `now`
 *  so a request can't straddle the boundary. */
export function resolvePriceID(env: WorkerEnv, rung: Rung, now: Date): string {
  if (rung !== "full") return env.PRICE_DISCOUNT;
  return launchActive(env, now) ? env.PRICE_LAUNCH! : env.PRICE_FULL;
}

export interface PriceTerms {
  priceId: string;
  /** currency (lowercase ISO) → minor units, from the live Stripe Price. */
  amounts: Record<string, number>;
}

/** currentTerms reads the live Stripe Price (currency_options expanded) and
 *  asserts the recurring-yearly contract this product sells. */
export async function currentTerms(stripe: Stripe, env: WorkerEnv, rung: Rung, now: Date = new Date()): Promise<PriceTerms> {
  return priceTermsByID(stripe, resolvePriceID(env, rung, now));
}

/** priceTermsByID is the raw read behind currentTerms; the quote route also
 *  uses it to show the regular price beside an active launch price. */
export async function priceTermsByID(stripe: Stripe, priceId: string): Promise<PriceTerms> {
  const price = await stripe.prices.retrieve(priceId, { expand: ["currency_options"] });
  if (price.type !== "recurring" || price.recurring?.interval !== "year") {
    throw new Error("price_interval_must_be_year");
  }
  const amounts: Record<string, number> = {};
  if (price.currency && price.unit_amount != null) {
    amounts[price.currency] = price.unit_amount;
  }
  for (const [currency, opt] of Object.entries(price.currency_options ?? {})) {
    if (opt.unit_amount != null) amounts[currency] = opt.unit_amount;
  }
  return { priceId, amounts };
}
