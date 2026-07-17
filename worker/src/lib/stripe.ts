// Stripe client + webhook-ledger helpers on the pinned dahlia shapes:
//
// ⚠️ FIELD SHAPES ARE API-VERSION-SENSITIVE (pinned 2026-05-27.dahlia):
// invoices carry NO top-level subscription/subscription_details — the
// linkage lives at invoice.parent.subscription_details — and charges carry
// NO invoice field. The SDK's static types don't model these; dahlia-only
// accesses are cast.

import Stripe from "stripe";
import type { WorkerEnv } from "../env.ts";

// Must be ≥ 2026-03-25.dahlia for ui_mode embedded_page. Keep in sync with
// the webhook endpoint's version in the Stripe dashboard.
export const STRIPE_API_VERSION = "2026-06-24.dahlia";

export function assertSafeEnvironment(env: WorkerEnv): void {
  const key = env.STRIPE_SECRET_KEY ?? "";
  const liveKey = /^(?:sk|rk)_live_/.test(key);
  if (env.ENVIRONMENT !== "production" && liveKey) {
    throw new Error("live_stripe_key_refused");
  }
  // Bidirectional: a test-mode key in production would let test-mode payment
  // events mint real entitlements. A missing key stays the softer
  // billing_not_configured path in getStripe.
  if (env.ENVIRONMENT === "production" && key && !liveKey) {
    throw new Error("test_stripe_key_refused_in_production");
  }
}

export function getStripe(env: WorkerEnv): Stripe | null {
  assertSafeEnvironment(env);
  const key = env.STRIPE_SECRET_KEY;
  if (!key) return null;
  return new Stripe(key, {
    apiVersion: STRIPE_API_VERSION,
    httpClient: Stripe.createFetchHttpClient(),
  });
}

/** Verify + parse a webhook using Web Crypto (Workers has no Node crypto).
 *  `body` MUST be the raw request text (never re-serialized JSON). */
export async function constructWebhookEvent(
  stripe: Stripe,
  body: string,
  sig: string,
  secret: string,
): Promise<Stripe.Event> {
  const provider = Stripe.createSubtleCryptoProvider();
  return stripe.webhooks.constructEventAsync(body, sig, secret, undefined, provider);
}

/** Coerce a Stripe expandable reference (string id | { id } | absent). */
export function idOf(v: unknown): string | null {
  if (typeof v === "string") return v;
  if (v && typeof v === "object" && typeof (v as { id?: unknown }).id === "string") {
    return (v as { id: string }).id;
  }
  return null;
}

// ---- webhook claim ledger (idempotency) -------------------------------------

export async function claimWebhookEvent(
  db: D1Database,
  ev: Stripe.Event,
): Promise<"skip" | "process"> {
  const row = await db
    .prepare("SELECT outcome FROM webhook_events WHERE id = ?")
    .bind(ev.id)
    .first<{ outcome: string }>();
  if (row && (row.outcome === "ok" || row.outcome === "ignored")) return "skip";
  if (!row) {
    await db
      .prepare(
        "INSERT OR IGNORE INTO webhook_events (id, type, received_at, outcome) VALUES (?, ?, ?, 'pending')",
      )
      .bind(ev.id, ev.type, new Date().toISOString())
      .run();
  }
  return "process";
}

export async function markWebhookOutcome(
  db: D1Database,
  id: string,
  outcome: string,
): Promise<void> {
  await db
    .prepare("UPDATE webhook_events SET outcome = ?, processed_at = ? WHERE id = ?")
    .bind(outcome, new Date().toISOString(), id)
    .run();
}

export interface PaymentRow {
  id: string;
  license_id: string;
  kind: string;
  currency?: string | null;
  amount?: number | null;
  billing_reason?: string | null;
  status: string;
}

export async function recordPayment(db: D1Database, p: PaymentRow): Promise<void> {
  await db
    .prepare(
      `INSERT INTO payments (id, license_id, kind, currency, amount, billing_reason, status, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT(id) DO UPDATE SET status = excluded.status, kind = excluded.kind`,
    )
    .bind(
      p.id,
      p.license_id,
      p.kind,
      p.currency ?? null,
      p.amount ?? null,
      p.billing_reason ?? null,
      p.status,
      new Date().toISOString(),
    )
    .run();
}
