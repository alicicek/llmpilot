// GET /v1/quote — the authoritative pre-checkout terms. The paywall renders
// its consent copy from this response and echoes the shown values back into
// POST /v1/checkout, where they are compared against a fresh derivation
// before any Session exists. No client-compiled price or trial length.

import type Stripe from "stripe";
import type { WorkerEnv } from "../env.ts";
import { getStripe } from "../lib/stripe.ts";
import { takeRateLimit } from "../lib/rate-limit.ts";
import { currentTerms, effectiveTrialDays } from "../lib/terms.ts";

const QUOTE_LIMIT = 60;
const QUOTE_WINDOW_MS = 60 * 60 * 1000;

export async function getQuote(
  env: WorkerEnv,
  clientIP = "unknown",
  stripeOverride?: Stripe,
): Promise<{ status: number; body: Record<string, unknown> }> {
  const stripe = stripeOverride ?? getStripe(env);
  if (!stripe || !env.PRICE_FULL || !env.PRICE_DISCOUNT) {
    return { status: 500, body: { error: "billing_not_configured" } };
  }
  if (!await takeRateLimit(env.ENT_DB, "quote-ip", clientIP, new Date(), QUOTE_LIMIT, QUOTE_WINDOW_MS)) {
    return { status: 429, body: { error: "rate_limited" } };
  }
  try {
    const full = await currentTerms(stripe, env, "full");
    const discount = await currentTerms(stripe, env, "discount_trial");
    const trialDays = effectiveTrialDays(env);
    // The honest charge date for the copy; the binding compare uses
    // trial_days, since the real anchor is checkout completion.
    const chargeDate = new Date(Date.now() + trialDays * 24 * 60 * 60 * 1000);
    return {
      status: 200,
      body: {
        trial_days: trialDays,
        charge_date: chargeDate.toISOString(),
        prices: { full: full.amounts, discount: discount.amounts },
      },
    };
  } catch (err) {
    console.error(`quote_failed: ${err instanceof Error ? err.message : String(err)}`);
    return { status: 502, body: { error: "quote_failed" } };
  }
}
