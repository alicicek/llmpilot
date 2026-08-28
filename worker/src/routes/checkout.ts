// POST /v1/checkout — create a Managed Payments Checkout Session for one
// decline-ladder rung. API-REJECTED params under Managed Payments are never sent
// (submit_type pay/book in subscription mode, custom_text,
// wallet_options.link — they 400 the session; button wording is fixed
// app-side around the checkout instead).

import type Stripe from "stripe";
import type { WorkerEnv } from "../env.ts";
import { getStripe } from "../lib/stripe.ts";
import { attachCheckout, insertLicense, installHasLiveLicense, markDeclined, newLicenseID, openCheckoutSessions } from "../lib/licenses.ts";
import { takeRateLimit } from "../lib/rate-limit.ts";
import { validInstallID } from "../lib/seats.ts";
import { currentTerms, effectiveTrialDays, resolvePriceID, type PriceTerms } from "../lib/terms.ts";

export type Rung = "full" | "discount_trial" | "nocard_trial";

const CHECKOUT_LIMIT = 10;
const CHECKOUT_WINDOW_MS = 60 * 60 * 1000;

// The hosted success URL: the app's checkout window intercepts this
// navigation and calls /v1/activate with the session id. The page itself
// (llmpilot.dev) is the browser-flow fallback.
const SUCCESS_URL = "https://llmpilot.dev/pro/activated?session_id={CHECKOUT_SESSION_ID}";
// Bare site fallback only. Hosted sessions get a per-checkout cancel URL on
// the API origin instead ({CHECKOUT_SESSION_ID} is documented for success_url
// ONLY, so the back-out signal rides our own token — as-of 2026-08-27).
const CANCEL_URL = "https://llmpilot.dev/pro/declined";

/** Opaque single-purpose back-out token (128-bit, hex) — its only power is
 *  setting declined_at on its own pending license. Never logged. */
export function newCancelToken(): string {
  const bytes = new Uint8Array(16);
  crypto.getRandomValues(bytes);
  let s = "";
  for (const b of bytes) s += b.toString(16).padStart(2, "0");
  return s;
}

export function sessionParams(
  env: WorkerEnv,
  rung: Rung,
  licenseId: string,
  ui: "hosted" | "embedded",
  now: Date = new Date(),
  cancelURL: string = CANCEL_URL,
): Stripe.Checkout.SessionCreateParams {
  const price = resolvePriceID(env, rung, now);
  const trialDays = effectiveTrialDays(env);
  const params: Stripe.Checkout.SessionCreateParams = {
    mode: "subscription",
    managed_payments: { enabled: true },
    line_items: [{ price, quantity: 1 }],
    metadata: { license_id: licenseId, rung },
    // Every rung leads with the free trial (owner 2026-07-31): full converts
    // to its one lifetime charge at trial end, same as the discount rung.
    subscription_data: {
      metadata: { license_id: licenseId, rung },
      trial_period_days: trialDays,
    },
    // Final ladder rung: trial without a card (payment_method_collection
    // default is card-upfront — the opt-out is only passed here).
    ...(rung === "nocard_trial" ? { payment_method_collection: "if_required" } : {}),
    ...(ui === "embedded"
      ? { ui_mode: "embedded_page", redirect_on_completion: "never" }
      : { success_url: SUCCESS_URL, cancel_url: cancelURL }),
  };
  return params;
}

/** QuoteEcho is the consent statement the buyer actually saw, sent back by
 *  the client. Every rung shows the trial, so every echo carries trial_days;
 *  full and discount_trial add currency+amount, nocard_trial shows no
 *  amount. Shape errors are invalid_input; value drift against a fresh
 *  derivation is quote_stale (refetch the quote, re-consent, retry). */
export interface QuoteEcho {
  trial_days?: number;
  currency?: string;
  amount_minor?: number;
}

function echoShapeValid(rung: Rung, q: QuoteEcho): boolean {
  const wantsAmount = rung !== "nocard_trial";
  // Non-positive values are structurally impossible terms, not stale ones:
  // they refuse here as invalid_input, never as a misleading quote_stale.
  if (typeof q.trial_days !== "number" || !Number.isInteger(q.trial_days) || q.trial_days <= 0) return false;
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
  if (q.trial_days !== trialDays) return false;
  if (rung !== "nocard_trial") {
    const current = terms.amounts[(q.currency ?? "").toLowerCase()];
    if (current === undefined || current !== q.amount_minor) return false;
  }
  return true;
}

/** The buyer's reminder-timing choice: days before the charge the pre-charge
 *  email lands. Absent defaults to 1 (the day before, the previous fixed
 *  behavior); anything but 1 or 2 is client drift and refuses. */
function parseRemindDays(v: unknown): number | null {
  if (v === undefined) return 1;
  return v === 1 || v === 2 ? v : null;
}

export async function createCheckout(
  env: WorkerEnv,
  body: { rung?: string; ui?: string; install_id?: string; quote?: unknown; remind_days_before?: unknown },
  clientIP = "unknown",
  stripeOverride?: Stripe,
  // origin is the WORKER's own public origin (from the incoming request). The
  // embedded /checkout host page is a worker route, NOT a site page — building
  // its URL from PUBLIC_ORIGIN (the llmpilot.dev site) 404s. Default to the
  // worker origin; PUBLIC_ORIGIN stays for the success/cancel SITE pages.
  origin?: string,
  // One clock reading binds consent compare AND Session creation — a request
  // arriving at the launch-window boundary resolves the same price for both.
  now: Date = new Date(),
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
  const remindDays = parseRemindDays(body.remind_days_before);
  if (remindDays === null) {
    return { status: 400, body: { error: "invalid_input" } };
  }
  const ui = body.ui === "hosted" ? "hosted" : "embedded";
  if (!await takeRateLimit(env.ENT_DB, "checkout-ip", clientIP, new Date(), CHECKOUT_LIMIT, CHECKOUT_WINDOW_MS)) {
    return { status: 429, body: { error: "rate_limited" } };
  }
  // One live purchase per install: an install already holding a trialing or
  // lifetime license is never sold a second one — fulfillment converges per
  // LICENSE row, not per install, so a second session here could become a
  // second charge (money review 2026-08-27 F2). The app pre-flights the same
  // fact from its local store; this is the boundary that holds when it lags.
  if (await installHasLiveLicense(env.ENT_DB, body.install_id)) {
    return { status: 409, body: { error: "already_licensed" } };
  }

  try {
    // Bind consent BEFORE any license row or Session exists: the shown terms
    // must equal the terms this Session will be created with, from the same
    // derivation (lib/terms.ts).
    const terms = await currentTerms(stripe, env, rung, now);
    if (!echoMatches(rung, echo, effectiveTrialDays(env), terms)) {
      return { status: 409, body: { error: "quote_stale" } };
    }

    // One payable checkout per install (owner 2026-08-27): expire the
    // install's prior open sessions BEFORE minting, so an armed win-back can
    // never complete behind a stale full-price tab. A session that just
    // completed refuses to expire — swallowed; fulfillment idempotency owns
    // that race.
    const dayAgo = new Date(now.getTime() - 24 * 60 * 60 * 1000);
    for (const prior of await openCheckoutSessions(env.ENT_DB, body.install_id, dayAgo)) {
      try {
        await stripe.checkout.sessions.expire(prior.session_id);
      } catch {
        // not open anymore (completed or already expired) — nothing to close
      }
    }

    const licenseId = newLicenseID();
    const cancelToken = newCancelToken();
    await insertLicense(env.ENT_DB, licenseId, rung, body.install_id, remindDays, cancelToken);
    // The back-out URL lives on the WORKER origin (it must record before it
    // forwards to the site page) and carries our token, not a Stripe template.
    const cancelURL = `${origin ?? "https://api.llmpilot.dev"}/checkout/declined?t=${cancelToken}`;
    const params = sessionParams(env, rung, licenseId, ui, now, ui === "hosted" ? cancelURL : CANCEL_URL);
    // Pin the Session to the CONSENTED currency. Without this, Checkout may
    // localize to the Price's other currency option and present an amount the
    // echo never showed — the same consent/charge divergence class as the
    // tax-behavior defect. echoMatches has already proven this currency is
    // one the Price carries at exactly the echoed amount. The no-card rung
    // shows no amount, echoes no currency, and stays unpinned.
    if (echo.currency) params.currency = echo.currency.toLowerCase();
    const session = await stripe.checkout.sessions.create(params, {
      idempotencyKey: `checkout:${licenseId}`,
    });
    // Record the session at MINT time (COALESCE keeps it on fulfillment
    // replay): expire-on-mint above can only close sessions it can find.
    await attachCheckout(env.ENT_DB, licenseId, { session: session.id });
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

const DECLINED_LIMIT = 60;
const DECLINED_WINDOW_MS = 60 * 60 * 1000;

/** GET /checkout/declined?t=<token> — the hosted session's cancel_url. Records
 *  the back-out (first-write-wins, pending-only) and EXPIRES the session that
 *  was declined, so the discount the app is about to arm can never sit behind
 *  a still-payable full-price tab (money review 2026-08-27 F1 — a browser
 *  Back-press would otherwise reach it for 24h). Then forwards to the site's
 *  "Nothing was charged" page. The redirect is unconditional — unknown,
 *  replayed, expired-token, malformed, and rate-limited hits all land on the
 *  same page, so the endpoint is no oracle for token validity. Our code never
 *  logs the token (it rides the URL, so platform request logs may carry it —
 *  which is why markDeclined time-bounds it). */
export async function declinedRoute(env: WorkerEnv, request: Request, stripeOverride?: Stripe): Promise<Response> {
  const redirect = () => Response.redirect(`${env.PUBLIC_ORIGIN}/pro/declined`, 302);
  const token = new URL(request.url).searchParams.get("t") ?? "";
  if (!/^[0-9a-f]{32}$/.test(token)) return redirect();
  const ip = request.headers.get("cf-connecting-ip") ?? "unknown";
  try {
    if (!await takeRateLimit(env.ENT_DB, "declined-ip", ip, new Date(), DECLINED_LIMIT, DECLINED_WINDOW_MS)) {
      return redirect();
    }
    const declined = await markDeclined(env.ENT_DB, token);
    const stripe = stripeOverride ?? getStripe(env);
    if (declined?.session_id && stripe) {
      try {
        await stripe.checkout.sessions.expire(declined.session_id);
      } catch {
        // Not open anymore — a completing payment beat the back-out here;
        // fulfillment idempotency owns that race, and declined_at on a row
        // that then pays stops meaning anything (status leaves pending).
      }
    }
  } catch (err) {
    // The buyer-facing page never breaks on our write failing; the win-back
    // then arms on the poll deadline instead of instantly.
    console.error(`declined_record_failed: ${err instanceof Error ? err.message : String(err)}`);
  }
  return redirect();
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
    const session = await stripe.checkout.sessions.retrieve(sessionId, { expand: ["subscription"] });
    const locale = request.headers.get("accept-language")?.split(",")[0] || "en-GB";
    let amount = session.amount_total == null || !session.currency
      ? "the amount shown by Stripe"
      : formatLocalizedAmount(locale, session.currency, session.amount_total);
    let note = "charged once — we cancel the renewal automatically";
    if (session.amount_total === 0) {
      // Trial session: nothing collected today, so the page's dominant
      // figure must not read as the price. State the REAL charge and its
      // date from the subscription (the checkout-locked currency — the same
      // derivation the reminder sweep sends), consumer-law rule a.
      amount = `${amount} today`;
      const sub = typeof session.subscription === "object" ? session.subscription : null;
      const price = sub?.items?.data?.[0]?.price;
      // Only state a specific figure when the Price row carries the
      // SESSION's pinned currency: the Price object reports its base
      // currency, so on a usd-pinned session it would put the WRONG number
      // on the consent-critical line. A mismatch falls back to the generic
      // honest line instead of a wrong exact one.
      note = price?.unit_amount != null && price.currency && sub?.trial_end && price.currency === session.currency
        ? `${formatLocalizedAmount(locale, price.currency, price.unit_amount)} on ${new Date(sub.trial_end * 1000).toLocaleDateString(locale, { day: "numeric", month: "long" })} — charged once; we cancel the renewal automatically`
        : "nothing due today — the trial price is charged once when it ends; we cancel the renewal automatically";
    }
    const secret = escapeHTML(session.client_secret ?? "");
    const publishableKey = JSON.stringify(env.STRIPE_PUBLISHABLE_KEY);
    const clientSecret = JSON.stringify(session.client_secret ?? "");
    return new Response(`<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>llmpilot checkout</title><style>:root{color-scheme:light}body{margin:0;background:#f5f5f4;color:#1c1917;font:14px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;-webkit-font-smoothing:antialiased}main{max-width:460px;margin:0 auto;padding:26px 20px 40px}h1{margin:0;font-size:19px;font-weight:650;letter-spacing:-0.01em}#amount{margin:10px 0 2px;font-size:26px;font-weight:700;font-variant-numeric:tabular-nums}.note{margin:0 0 16px;font-size:12.5px;color:#78716c}#receipt{margin-top:18px;border:1px solid #e7e5e4;border-radius:10px;padding:12px 14px;background:#fff}#receipt h2{margin:0 0 4px;font-size:13px}#receipt p{margin:0;font-size:12.5px;color:#57534e}</style><body><main><h1>Turn on the autopilot</h1><p id="amount">${escapeHTML(amount)}</p><p class="note">${escapeHTML(note)}</p><div id="checkout" data-client-secret="${secret}"></div><section id="receipt" hidden><h2>Receipt</h2><p>Your statement will show <strong>LINK.COM* LLMPILOT.DEV</strong>.</p></section></main><script src="https://js.stripe.com/v3/"></script><script>(async()=>{const stripe=Stripe(${publishableKey});if(typeof stripe.createEmbeddedCheckoutPage!=="function")throw new Error("embedded_checkout_unavailable");const checkout=await stripe.createEmbeddedCheckoutPage({fetchClientSecret:async()=>${clientSecret},onComplete:async()=>{await fetch("/v1/activate",{method:"POST",headers:{"content-type":"application/json"},body:JSON.stringify({session_id:${JSON.stringify(session.id)}})});document.getElementById("receipt").hidden=false}});checkout.mount("#checkout")})().catch(()=>{document.getElementById("checkout").textContent="Checkout could not load. Try again."})</script></body></html>`, {
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
