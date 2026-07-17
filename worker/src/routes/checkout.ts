// POST /v1/checkout — create a Managed Payments Checkout Session for one
// decline-ladder rung. API-REJECTED params under Managed Payments are never sent
// (submit_type pay/book in subscription mode, custom_text,
// wallet_options.link — they 400 the session; button wording is fixed
// app-side around the checkout instead).

import type Stripe from "stripe";
import type { WorkerEnv } from "../env.ts";
import { getStripe } from "../lib/stripe.ts";
import { insertLicense, newLicenseID } from "../lib/licenses.ts";
import { takeRateLimit } from "../lib/rate-limit.ts";
import { validInstallID } from "../lib/seats.ts";
import { currentTerms, effectiveTrialDays, type PriceTerms } from "../lib/terms.ts";

export type Rung = "full" | "discount_trial" | "nocard_trial";

const CHECKOUT_LIMIT = 10;
const CHECKOUT_WINDOW_MS = 60 * 60 * 1000;

// The hosted success URL: the app's checkout window intercepts this
// navigation and calls /v1/activate with the session id. The page itself
// (llmpilot.dev) is the browser-flow fallback.
const SUCCESS_URL = "https://llmpilot.dev/pro/activated?session_id={CHECKOUT_SESSION_ID}";
const CANCEL_URL = "https://llmpilot.dev/pro/declined";

export function sessionParams(
  env: WorkerEnv,
  rung: Rung,
  licenseId: string,
  ui: "hosted" | "embedded",
): Stripe.Checkout.SessionCreateParams {
  const price = rung === "full" ? env.PRICE_FULL : env.PRICE_DISCOUNT;
  const trialDays = effectiveTrialDays(env);
  const params: Stripe.Checkout.SessionCreateParams = {
    mode: "subscription",
    managed_payments: { enabled: true },
    line_items: [{ price, quantity: 1 }],
    metadata: { license_id: licenseId, rung },
    subscription_data: {
      metadata: { license_id: licenseId, rung },
      ...(rung === "full" ? {} : { trial_period_days: trialDays }),
    },
    // Final ladder rung: trial without a card (payment_method_collection
    // default is card-upfront — the opt-out is only passed here).
    ...(rung === "nocard_trial" ? { payment_method_collection: "if_required" } : {}),
    ...(ui === "embedded"
      ? { ui_mode: "embedded_page", redirect_on_completion: "never" }
      : { success_url: SUCCESS_URL, cancel_url: CANCEL_URL }),
  };
  return params;
}

/** QuoteEcho is the consent statement the buyer actually saw, sent back by
 *  the client. Per rung it must carry exactly the terms that rung shows:
 *  full → currency+amount, nocard_trial → trial length, discount_trial → all
 *  three. Shape errors are invalid_input; value drift against a fresh
 *  derivation is quote_stale (refetch the quote, re-consent, retry). */
export interface QuoteEcho {
  trial_days?: number;
  currency?: string;
  amount_minor?: number;
}

function echoShapeValid(rung: Rung, q: QuoteEcho): boolean {
  const wantsTrial = rung !== "full";
  const wantsAmount = rung !== "nocard_trial";
  // Non-positive values are structurally impossible terms, not stale ones:
  // they refuse here as invalid_input, never as a misleading quote_stale.
  if (wantsTrial) {
    if (typeof q.trial_days !== "number" || !Number.isInteger(q.trial_days) || q.trial_days <= 0) return false;
  } else if (q.trial_days !== undefined) {
    return false; // the full rung shows no trial — a stray value is client drift
  }
  if (wantsAmount) {
    if (typeof q.currency !== "string" || q.currency === "") return false;
    if (typeof q.amount_minor !== "number" || !Number.isInteger(q.amount_minor) || q.amount_minor <= 0) return false;
  } else if (q.currency !== undefined || q.amount_minor !== undefined) {
    return false; // the no-card rung shows no amount
  }
  return true;
}

/** echoMatches compares the echoed consent terms against the fresh
 *  derivation. Only currencies the Price actually carries can match. */
function echoMatches(rung: Rung, q: QuoteEcho, trialDays: number, terms: PriceTerms): boolean {
  if (rung !== "full" && q.trial_days !== trialDays) return false;
  if (rung !== "nocard_trial") {
    const current = terms.amounts[(q.currency ?? "").toLowerCase()];
    if (current === undefined || current !== q.amount_minor) return false;
  }
  return true;
}

export async function createCheckout(
  env: WorkerEnv,
  body: { rung?: string; ui?: string; install_id?: string; quote?: unknown },
  clientIP = "unknown",
  stripeOverride?: Stripe,
  // origin is the WORKER's own public origin (from the incoming request). The
  // embedded /checkout host page is a worker route, NOT a site page — building
  // its URL from PUBLIC_ORIGIN (the llmpilot.dev site) 404s. Default to the
  // worker origin; PUBLIC_ORIGIN stays for the success/cancel SITE pages.
  origin?: string,
): Promise<{ status: number; body: Record<string, unknown> }> {
  const stripe = stripeOverride ?? getStripe(env);
  if (!stripe || !env.PRICE_FULL || !env.PRICE_DISCOUNT) {
    return { status: 500, body: { error: "billing_not_configured" } };
  }
  const rung = (body.rung ?? "full") as Rung;
  if (!["full", "discount_trial", "nocard_trial"].includes(rung)) {
    return { status: 400, body: { error: "invalid_rung" } };
  }
  // The install id binds the eventual token at checkout-creation time, so
  // even webhook-first fulfillment knows which Mac to mint for.
  if (!validInstallID(body.install_id)) {
    return { status: 400, body: { error: "invalid_input" } };
  }
  // The quote echo is mandatory: consent rendered from anything but the
  // server quote must never reach Session creation.
  const echo = (body.quote && typeof body.quote === "object" ? body.quote : null) as QuoteEcho | null;
  if (!echo || !echoShapeValid(rung, echo)) {
    return { status: 400, body: { error: "invalid_input" } };
  }
  const ui = body.ui === "hosted" ? "hosted" : "embedded";
  if (!await takeRateLimit(env.ENT_DB, "checkout-ip", clientIP, new Date(), CHECKOUT_LIMIT, CHECKOUT_WINDOW_MS)) {
    return { status: 429, body: { error: "rate_limited" } };
  }

  try {
    // Bind consent BEFORE any license row or Session exists: the shown terms
    // must equal the terms this Session will be created with, from the same
    // derivation (lib/terms.ts).
    const terms = await currentTerms(stripe, env, rung);
    if (!echoMatches(rung, echo, effectiveTrialDays(env), terms)) {
      return { status: 409, body: { error: "quote_stale" } };
    }

    const licenseId = newLicenseID();
    await insertLicense(env.ENT_DB, licenseId, rung, body.install_id);
    const params = sessionParams(env, rung, licenseId, ui);
    const session = await stripe.checkout.sessions.create(params, {
      idempotencyKey: `checkout:${licenseId}`,
    });
    return {
      status: 200,
      body: {
        sessionId: session.id,
        license: licenseId,
        ...(session.url ? { url: session.url } : {}),
        ...(session.client_secret ? { clientSecret: session.client_secret } : {}),
        ...(session.client_secret ? { checkoutUrl: `${origin ?? env.PUBLIC_ORIGIN}/checkout?session_id=${encodeURIComponent(session.id)}` } : {}),
      },
    };
  } catch (err) {
    // Server-side detail only — a misconfigured price/key must not be a
    // blind "checkout_failed" in the logs. The license id is a bearer
    // capability, so it stays out of the log line.
    console.error(
      `checkout_failed rung=${rung}: ${err instanceof Error ? err.message : String(err)}`,
    );
    return { status: 502, body: { error: "checkout_failed" } };
  }
}

function escapeHTML(value: string): string {
  return value.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);
}

export function formatLocalizedAmount(locale: string, currency: string, amountMinor: number): string {
	const formatter = new Intl.NumberFormat(locale, { style: "currency", currency: currency.toUpperCase() });
	const options = formatter.resolvedOptions();
	const fractionDigits = options.maximumFractionDigits ?? options.minimumFractionDigits ?? 2;
	return formatter.format(amountMinor / 10 ** fractionDigits);
}

export async function checkoutPage(env: WorkerEnv, request: Request, stripeOverride?: Stripe): Promise<Response> {
  const stripe = stripeOverride ?? getStripe(env);
  const sessionId = new URL(request.url).searchParams.get("session_id") ?? "";
  if (!stripe || !sessionId.startsWith("cs_")) return new Response("Not found", { status: 404 });
  try {
    const session = await stripe.checkout.sessions.retrieve(sessionId);
    const locale = request.headers.get("accept-language")?.split(",")[0] || "en-GB";
    const amount = session.amount_total == null || !session.currency
      ? "the amount shown by Stripe"
      : formatLocalizedAmount(locale, session.currency, session.amount_total);
    const secret = escapeHTML(session.client_secret ?? "");
    const publishableKey = JSON.stringify(env.STRIPE_PUBLISHABLE_KEY);
    const clientSecret = JSON.stringify(session.client_secret ?? "");
    return new Response(`<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>llmpilot checkout</title><body><main><h1>Turn on the autopilot</h1><p id="amount">${escapeHTML(amount)}</p><p>charged once — we cancel the renewal automatically</p><div id="checkout" data-client-secret="${secret}"></div><section id="receipt" hidden><h2>Receipt</h2><p>Your statement will show <strong>LINK.COM* LLMPILOT.DEV</strong>.</p></section></main><script src="https://js.stripe.com/v3/"></script><script>(async()=>{const stripe=Stripe(${publishableKey});if(typeof stripe.createEmbeddedCheckoutPage!=="function")throw new Error("embedded_checkout_unavailable");const checkout=await stripe.createEmbeddedCheckoutPage({fetchClientSecret:async()=>${clientSecret},onComplete:async()=>{await fetch("/v1/activate",{method:"POST",headers:{"content-type":"application/json"},body:JSON.stringify({session_id:${JSON.stringify(session.id)}})});document.getElementById("receipt").hidden=false}});checkout.mount("#checkout")})().catch(()=>{document.getElementById("checkout").textContent="Checkout could not load. Try again."})</script></body></html>`, {
      headers: {
        "content-type": "text/html; charset=utf-8",
        "cache-control": "no-store",
        "x-robots-tag": "noindex",
        "content-security-policy": "default-src 'none'; script-src https://js.stripe.com 'unsafe-inline'; frame-src https://js.stripe.com https://hooks.stripe.com; connect-src 'self' https://api.stripe.com; style-src 'unsafe-inline'; img-src data: https://*.stripe.com",
      },
    });
  } catch {
    return new Response("Not found", { status: 404 });
  }
}
