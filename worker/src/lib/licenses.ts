// License state machine over D1. States:
//   pending → trialing → lifetime          (trial converts)
//   pending → lifetime                     (full-price rung, paid at checkout)
//   pending → lapsed                       (no-card trial refused: email already used one)
//   trialing → lapsed                      (cancelled / conversion failed — honest pause)
//   trialing|lifetime → revoked            (full refund / dispute)
// Revoked is terminal: nothing re-mints a revoked license.

import type Stripe from "stripe";
import type { WorkerEnv } from "../env.ts";
import {
  importSigningKey,
  lifetimePayload,
  signEntitlement,
  trialPayload,
} from "./entitlement.ts";
import { seatLimit, seatUnderCap } from "./seats.ts";
import { idOf, recordPayment } from "./stripe.ts";

export interface LicenseRow {
  id: string;
  email: string | null;
  customer_id: string | null;
  subscription_id: string | null;
  session_id: string | null;
  status: string;
  rung: string;
  trial_end: string | null;
  cancel_at: string | null;
  reminder_sent_at: string | null;
  entitlement: string | null;
  install_id: string | null;
  created_at: string;
  updated_at: string;
  revoked_at: string | null;
}

export function newLicenseID(): string {
  const bytes = new Uint8Array(16);
  crypto.getRandomValues(bytes);
  let s = "";
  for (const b of bytes) s += b.toString(16).padStart(2, "0");
  return `lic_${s}`;
}

export async function insertLicense(db: D1Database, id: string, rung: string, installId: string): Promise<void> {
  const now = new Date().toISOString();
  await db
    .prepare(
      "INSERT INTO licenses (id, status, rung, install_id, created_at, updated_at) VALUES (?, 'pending', ?, ?, ?, ?)",
    )
    .bind(id, rung, installId, now, now)
    .run();
}

export async function licenseBy(
  db: D1Database,
  col: "id" | "session_id" | "subscription_id",
  v: string,
): Promise<LicenseRow | null> {
  return await db.prepare(`SELECT * FROM licenses WHERE ${col} = ?`).bind(v).first<LicenseRow>();
}

export async function licensesByEmail(db: D1Database, email: string): Promise<LicenseRow[]> {
  const res = await db
    .prepare("SELECT * FROM licenses WHERE email = ? ORDER BY created_at DESC")
    .bind(email.trim().toLowerCase())
    .all<LicenseRow>();
  return res.results ?? [];
}

/** Attach the Stripe identities a completed checkout reveals. COALESCE keeps
 *  earlier values on replay. */
export async function attachCheckout(
  db: D1Database,
  id: string,
  f: { email?: string | null; customer?: string | null; subscription?: string | null; session?: string | null },
): Promise<void> {
  await db
    .prepare(
      `UPDATE licenses SET
         email = COALESCE(?, email),
         customer_id = COALESCE(?, customer_id),
         subscription_id = COALESCE(?, subscription_id),
         session_id = COALESCE(?, session_id),
         updated_at = ?
       WHERE id = ?`,
    )
    .bind(
      f.email ? f.email.trim().toLowerCase() : null,
      f.customer ?? null,
      f.subscription ?? null,
      f.session ?? null,
      new Date().toISOString(),
      id,
    )
    .run();
}

/** requireInstall is the mint-path guard: every post-8.1 checkout row binds
 *  an install id at creation, so a missing one is a hard invariant break —
 *  minting an unbound token would defeat device binding entirely. */
function requireInstall(lic: LicenseRow): string {
  if (!lic.install_id) throw new Error("license_missing_install");
  return lic.install_id;
}

/** mintFor signs a fresh token for one activated seat: the row's status
 *  decides the kind, issued_at is now (the app's offline-grace anchor), and
 *  the install claim is the CALLER's seat — never blindly the checkout Mac's. */
export async function mintFor(
  env: WorkerEnv,
  lic: LicenseRow,
  installId: string,
  now = new Date(),
): Promise<string> {
  const key = await importSigningKey(env.ENT_SIGNING_KEY);
  if (lic.status === "lifetime") {
    return signEntitlement(key, lifetimePayload(env.ENT_SIGNING_KEY_ID, installId, now));
  }
  if (lic.status === "trialing" && lic.trial_end) {
    // trialPayload adds the grace window itself; hand it the raw trial end.
    return signEntitlement(key, trialPayload(env.ENT_SIGNING_KEY_ID, new Date(lic.trial_end), installId, now));
  }
  throw new Error("license_not_mintable");
}

/** pending → trialing, minting the expiring trial token bound to the
 *  checkout install and seating that install. Idempotent: only a pending row
 *  transitions; anything else keeps its state. */
export async function markTrialing(
  env: WorkerEnv,
  db: D1Database,
  lic: LicenseRow,
  trialEnd: Date,
): Promise<void> {
  const install = requireInstall(lic);
  const now = new Date();
  const key = await importSigningKey(env.ENT_SIGNING_KEY);
  const token = await signEntitlement(key, trialPayload(env.ENT_SIGNING_KEY_ID, trialEnd, install, now));
  const res = await db
    .prepare(
      `UPDATE licenses SET status = 'trialing', trial_end = ?, entitlement = ?, updated_at = ?
       WHERE id = ? AND status = 'pending'`,
    )
    .bind(trialEnd.toISOString(), token, now.toISOString(), lic.id)
    .run();
  if ((res.meta?.changes ?? 0) > 0) {
    // Trial start is the checkout install's first seat (pending → trialing), so
    // this is always under the cap; seatUnderCap keeps the seating cap-aware
    // for symmetry with conversion.
    await seatUnderCap(db, lic.id, install, seatLimit(env), now);
  }
}

export type FulfillResult = "minted" | "already" | "refused_revoked";

/** The one lifetime-fulfillment path, called by BOTH checkout.session.completed
 *  (full-price rung, paid at checkout) and invoice.paid with amount_paid > 0
 *  (trial conversion, billing_reason=subscription_cycle). Idempotent at the
 *  license row: the conditional UPDATE only fires once; replays and the
 *  session/invoice event race both land in "already". Revoked licenses are
 *  never re-minted. The separate checkout-completion path establishes
 *  cancel_at before this function can mint.
 */
export async function fulfillLifetime(
  env: WorkerEnv,
  db: D1Database,
  lic: LicenseRow,
  pay: { id: string; currency?: string | null; amount?: number | null; billingReason?: string | null },
): Promise<FulfillResult> {
  if (lic.status === "revoked") {
    await recordPayment(db, {
      id: pay.id,
      license_id: lic.id,
      kind: "purchase",
      currency: pay.currency,
      amount: pay.amount,
      billing_reason: pay.billingReason,
      status: "needs_manual_review", // money moved on a revoked license
    });
    return "refused_revoked";
  }

  const install = requireInstall(lic);
  const now = new Date();
  const key = await importSigningKey(env.ENT_SIGNING_KEY);
  const token = await signEntitlement(key, lifetimePayload(env.ENT_SIGNING_KEY_ID, install, now));
  const res = await db
    .prepare(
      `UPDATE licenses SET status = 'lifetime', entitlement = ?, updated_at = ?
       WHERE id = ? AND status IN ('pending', 'trialing', 'lapsed')`,
    )
    .bind(token, now.toISOString(), lic.id)
    .run();
  const minted = (res.meta?.changes ?? 0) > 0;
  if (minted) {
    // Cap-aware, NOT an unconditional re-seat: if the checkout install was
    // evicted during a recover-past-cap and the license is now full,
    // conversion must NOT revive it or push the seat count past the cap. It
    // refreshes the seat when still present, or takes an open slot when there
    // is one.
    await seatUnderCap(db, lic.id, install, seatLimit(env), now);
  }

  await recordPayment(db, {
    id: pay.id,
    license_id: lic.id,
    kind: "purchase",
    currency: pay.currency,
    amount: pay.amount,
    billing_reason: pay.billingReason,
    status: "paid",
  });
  return minted ? "minted" : "already";
}

/** trialing → lapsed (cancel before charge, or conversion failed). The
 *  designed honest pause: schedules pause visibly, nothing deleted. A
 *  lifetime license never lapses — cancel_at ends its
 *  subscription by design. */
export async function lapseTrial(db: D1Database, licId: string): Promise<boolean> {
  const res = await db
    .prepare(
      "UPDATE licenses SET status = 'lapsed', updated_at = ? WHERE id = ? AND status = 'trialing'",
    )
    .bind(new Date().toISOString(), licId)
    .run();
  return (res.meta?.changes ?? 0) > 0;
}

/** pending → lapsed without ever trialing: the checkout email already
 *  consumed its no-card trial, so this row never mints. */
export async function refuseTrial(db: D1Database, licId: string): Promise<void> {
  await db
    .prepare(
      "UPDATE licenses SET status = 'lapsed', updated_at = ? WHERE id = ? AND status = 'pending'",
    )
    .bind(new Date().toISOString(), licId)
    .run();
}

/** One prior consumed no-card trial per checkout email. Trialing counts (in
 *  use), lifetime counts (it converted), lapsed counts (used then ended);
 *  `+alias@` farming is the accepted low-friction caveat. */
export async function nocardTrialConsumed(db: D1Database, email: string, exceptId: string): Promise<boolean> {
  const row = await db
    .prepare(
      `SELECT 1 AS one FROM licenses
       WHERE email = ? AND rung = 'nocard_trial' AND status IN ('trialing', 'lifetime', 'lapsed') AND id != ?
       LIMIT 1`,
    )
    .bind(email.trim().toLowerCase(), exceptId)
    .first();
  return row !== null;
}

/** Full refund or dispute: terminal revoke. */
export async function revokeLicense(db: D1Database, licId: string): Promise<void> {
  const now = new Date().toISOString();
  await db
    .prepare(
      "UPDATE licenses SET status = 'revoked', revoked_at = ?, updated_at = ? WHERE id = ? AND status != 'revoked'",
    )
    .bind(now, now, licId)
    .run();
}

/** Resolve the underlying PaymentIntent id for ledger keying: dahlia-era
 *  invoices carry NO payment_intent field — the link lives in the separate
 *  invoice_payments resource. A paid invoice without a resolvable PI must
 *  retry; using the invoice id would break later refund/dispute matching. */
export async function resolvePaymentId(
  stripe: Stripe,
  invoice: Stripe.Invoice | null,
  invoiceId: string | null,
): Promise<string | null> {
  if (invoiceId) {
    const payments = await stripe.invoicePayments.list({ invoice: invoiceId, status: "paid", limit: 10 });
    const payment = payments.data.find(
      (candidate) => candidate.status === "paid" && candidate.payment.type === "payment_intent",
    );
    const piId = payment ? idOf(payment.payment.payment_intent) : null;
    if (!piId) throw new Error("payment_intent_unresolved");
    return piId;
  }
  return null;
}

const CANCELLATION_GRACE_SECONDS = 7 * 24 * 60 * 60;

export function cancellationAt(subscription: Stripe.Subscription): number | null {
  if (subscription.trial_end) return subscription.trial_end + CANCELLATION_GRACE_SECONDS;
  const periodEnd = subscription.items.data[0]?.current_period_end;
  return periodEnd ?? null;
}

/** Establish the no-second-charge invariant before an entitlement is minted. */
export async function ensureCancellation(
  stripe: Stripe,
  db: D1Database,
  lic: LicenseRow,
  subscription: Stripe.Subscription,
): Promise<number> {
  const target = cancellationAt(subscription);
  if (!target) throw new Error("subscription_missing_cancel_anchor");
  if (subscription.cancel_at !== target) {
    await stripe.subscriptions.update(subscription.id, { cancel_at: target });
  }
  await db
    .prepare("UPDATE licenses SET cancel_at = ?, updated_at = ? WHERE id = ?")
    .bind(new Date(target * 1000).toISOString(), new Date().toISOString(), lic.id)
    .run();
  return target;
}
