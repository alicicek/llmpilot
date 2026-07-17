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

export interface PriceTerms {
  priceId: string;
  /** currency (lowercase ISO) → minor units, from the live Stripe Price. */
  amounts: Record<string, number>;
}

/** currentTerms reads the live Stripe Price (currency_options expanded) and
 *  asserts the recurring-yearly contract this product sells. */
export async function currentTerms(stripe: Stripe, env: WorkerEnv, rung: Rung): Promise<PriceTerms> {
  const priceId = rung === "full" ? env.PRICE_FULL : env.PRICE_DISCOUNT;
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
