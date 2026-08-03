// POST /v1/stripe/webhook — RAW body verify, claim-ledger idempotency,
// dahlia field shapes. Throwing forces a Stripe retry; "ignored" records the
// event as deliberately skipped. Logs carry event type+id and license ids
// only — never payloads or emails.

import type Stripe from "stripe";
import type { WorkerEnv } from "../env.ts";
import {
  claimWebhookEvent,
  constructWebhookEvent,
  getStripe,
  idOf,
  markWebhookOutcome,
  recordPayment,
} from "../lib/stripe.ts";
import {
  attachCheckout,
  ensureCancellation,
  fulfillLifetime,
  lapseTrial,
  licenseBy,
  markTrialing,
  nocardTrialConsumed,
  refuseTrial,
  resolvePaymentId,
  revokeLicense,
  type LicenseRow,
} from "../lib/licenses.ts";
import { readTextBody } from "../lib/http.ts";

/** The one checkout-completion fulfillment, shared by the webhook and
 *  /v1/activate (the app's confirm path — an alternative to
 *  success_url-only flows; whoever runs first wins, the other is idempotent).
 */
export async function fulfillSession(
  env: WorkerEnv,
  stripe: Stripe,
  sessionId: string,
): Promise<{ lic: LicenseRow | null; state: string }> {
  const db = env.ENT_DB;
  const session = await stripe.checkout.sessions.retrieve(sessionId, {
    expand: ["subscription", "invoice"],
  });
  const licenseId = (session.metadata && session.metadata.license_id) || "";
  let lic = licenseId
    ? await licenseBy(db, "id", licenseId)
    : await licenseBy(db, "session_id", session.id);
  if (!lic) return { lic: null, state: "unattributed" };

  const sub =
    typeof session.subscription === "object"
      ? session.subscription
      : session.subscription
        ? await stripe.subscriptions.retrieve(session.subscription)
        : null;
  await attachCheckout(db, lic.id, {
    email: session.customer_details?.email ?? null,
    customer: idOf(session.customer),
    subscription: idOf(session.subscription),
    session: session.id,
  });
  lic = (await licenseBy(db, "id", lic.id)) as LicenseRow;

  if (session.payment_status === "paid" && lic.rung === "full" && sub && !sub.trial_end) {
    // The no-trial full path. Its live purpose since the 2026-07-31 reshape
    // (every rung now trials): full Sessions created BEFORE the reshape
    // deploy that complete after it — those collected payment at completion
    // and must mint here; waiting for subscription_cycle would withhold the
    // product after payment. The !trial_end guard keeps any trialing
    // session out: a paid-status trialing session minting here would grant
    // lifetime for £0 with the trial still running (and cancelRoute only
    // cancels trialing rows — the mistake would be uncancellable). A refund
    // cancels the subscription and revokes — fulfillLifetime refuses
    // revoked rows, so a replayed success URL can never re-arm a refunded
    // license.
    await ensureCancellation(stripe, db, lic, sub);
    const invoice = typeof session.invoice === "object" ? session.invoice : null;
    const invoiceId = invoice ? invoice.id : idOf(session.invoice);
    const payId = (await resolvePaymentId(stripe, invoice, invoiceId ?? null)) || session.id;
    const res = await fulfillLifetime(env, db, lic, {
      id: payId,
      currency: session.currency,
      amount: session.amount_total,
      billingReason: "checkout",
    });
    return { lic: (await licenseBy(db, "id", lic.id)) as LicenseRow, state: res };
  }

  if (sub && sub.status === "trialing" && sub.trial_end) {
    // One consumed no-card trial per checkout email (server-side; the
    // synchronizable Apple ID marker is only the client-side courtesy). The
    // refused row lapses from pending and its subscription is cancelled
    // outright so no zombie sub ever reaches a charge. A no-card trial with
    // no email to check against fails CLOSED — Stripe Checkout always collects
    // one, so an absent email is anomalous, not a free pass.
    if (lic.rung === "nocard_trial" && (!lic.email || (await nocardTrialConsumed(db, lic.email, lic.id)))) {
      try {
        await stripe.subscriptions.cancel(sub.id);
      } catch {
        // Replays land here with the subscription already cancelled.
      }
      await refuseTrial(db, lic.id);
      return { lic: (await licenseBy(db, "id", lic.id)) as LicenseRow, state: "trial_email_used" };
    }
    // This Stripe write is deliberately before minting: even if the Worker
    // disappears after this event, the subscription cannot reach cycle two.
    await ensureCancellation(stripe, db, lic, sub);
    await markTrialing(env, db, lic, new Date(sub.trial_end * 1000));
    await recordPayment(db, {
      id: session.id,
      license_id: lic.id,
      kind: "trial_start",
      currency: session.currency,
      amount: 0,
      status: "paid",
    });
    return { lic: (await licenseBy(db, "id", lic.id)) as LicenseRow, state: "trialing" };
  }

  return { lic, state: "not_paid" };
}

/** Resolve the license an invoice belongs to. Dahlia: linkage lives at
 *  invoice.parent.subscription_details (NO top-level subscription field). */
async function licenseForInvoice(
  env: WorkerEnv,
  stripe: Stripe,
  invoice: Stripe.Invoice,
): Promise<LicenseRow | null> {
  const sd = invoice.parent?.subscription_details;
  if (!sd) return null;
  const licenseId = sd.metadata?.license_id;
  if (licenseId) {
    const lic = await licenseBy(env.ENT_DB, "id", licenseId);
    if (lic) return lic;
  }
  const subId = idOf(sd.subscription);
  if (subId) {
    const lic = await licenseBy(env.ENT_DB, "subscription_id", subId);
    if (lic) return lic;
    try {
      const sub = await stripe.subscriptions.retrieve(subId);
      const viaMeta = sub.metadata?.license_id;
      if (viaMeta) return await licenseBy(env.ENT_DB, "id", viaMeta);
    } catch {
      /* fall through */
    }
  }
  return null;
}

/** Dispatch one verified event. Returns "ok" | "ignored"; throws to retry. */
export async function handleEvent(
  env: WorkerEnv,
  stripe: Stripe,
  ev: Stripe.Event,
): Promise<"ok" | "ignored"> {
  const db = env.ENT_DB;
  switch (ev.type) {
    case "checkout.session.completed":
    case "checkout.session.async_payment_succeeded": {
      const session = ev.data.object as Stripe.Checkout.Session;
      const { lic, state } = await fulfillSession(env, stripe, session.id);
      if (!lic) throw new Error("checkout_unattributed");
      if (state === "not_paid") return "ignored";
      return "ok";
    }

    case "invoice.paid": {
      const invoice = ev.data.object as Stripe.Invoice;
      // Lifetime conversion is exclusively the first real renewal cycle —
      // for every rung, now that full also trials before its one charge.
      if (invoice.billing_reason !== "subscription_cycle" || invoice.amount_paid <= 0) return "ignored";
      const amountPaid = invoice.amount_paid;
      const lic = await licenseForInvoice(env, stripe, invoice);
      if (!lic) throw new Error("invoice_unattributed");
      const payId = (await resolvePaymentId(stripe, invoice, invoice.id)) || invoice.id;
      await fulfillLifetime(env, db, lic, {
        id: payId,
        currency: invoice.currency,
        amount: amountPaid,
        billingReason: invoice.billing_reason,
      });
      return "ok";
    }

    case "invoice.payment_failed": {
      // Trial conversion failed (no-card rung, or a declined card). Honest
      // pause — and if a retried payment later lands, fulfillLifetime
      // transitions lapsed → lifetime.
      const lic = await licenseForInvoice(env, stripe, ev.data.object as Stripe.Invoice);
      if (!lic) return "ignored";
      await lapseTrial(db, lic.id);
      return "ok";
    }

    case "customer.subscription.deleted": {
      const subscription = ev.data.object as Stripe.Subscription;
      const meta = subscription.metadata;
      const lic =
        (meta?.license_id ? await licenseBy(db, "id", meta.license_id) : null) ??
        (await licenseBy(db, "subscription_id", subscription.id));
      if (!lic) return "ignored";
      // A lifetime license's subscription ends by design
      // (cancel_at) — only a live trial lapses.
      await lapseTrial(db, lic.id);
      return "ok";
    }

    case "charge.refunded": {
      const charge = ev.data.object as Stripe.Charge;
      const piId = idOf(charge.payment_intent) ?? charge.id;
      const row = await db
        .prepare("SELECT license_id FROM payments WHERE id = ? AND kind = 'purchase'")
        .bind(piId)
        .first<{ license_id: string }>();
      const full = charge.amount_refunded >= charge.amount;
      const refunds = charge.refunds;
      const refundId = refunds?.data?.[0]?.id || `${piId}_refund`;
      if (!row) {
        // No ledger match — visible orphan, never dropped (ops reviews it).
        await recordPayment(db, {
          id: refundId,
          license_id: "",
          kind: "refund",
          currency: charge.currency,
          amount: charge.amount_refunded,
          status: "needs_manual_review",
        });
        return "ok";
      }
      if (full) {
        await revokeLicense(db, row.license_id);
        // End the subscription too: cancel_at already blocks any further
        // charge, but a refunded buyer must not keep an "active"
        // subscription (and its Stripe lifecycle emails) for months.
        const lic = await licenseBy(db, "id", row.license_id);
        if (lic?.subscription_id) {
          try {
            await stripe.subscriptions.cancel(lic.subscription_id);
          } catch {
            /* already canceled or gone — the revoke stands regardless */
          }
        }
      }
      await recordPayment(db, {
        id: refundId,
        license_id: row.license_id,
        kind: "refund",
        currency: charge.currency,
        amount: charge.amount_refunded,
        status: full ? "refunded" : "partial_refund",
      });
      return "ok";
    }

    case "charge.dispute.created": {
      // Dispute hygiene is account-existential: revoke immediately, flag for
      // a fast refund decision.
      const dispute = ev.data.object as Stripe.Dispute;
      const piId = idOf(dispute.payment_intent);
      const row = piId
        ? await db
            .prepare("SELECT license_id FROM payments WHERE id = ? AND kind = 'purchase'")
            .bind(piId)
            .first<{ license_id: string }>()
        : null;
      if (row) await revokeLicense(db, row.license_id);
      await recordPayment(db, {
        id: dispute.id,
        license_id: row?.license_id ?? "",
        kind: "dispute",
        currency: dispute.currency,
        amount: dispute.amount,
        status: "needs_manual_review",
      });
      return "ok";
    }

    default:
      return "ignored";
  }
}

export async function webhookRoute(env: WorkerEnv, req: Request): Promise<Response> {
  const stripe = getStripe(env);
  if (!stripe || !env.STRIPE_WEBHOOK_SECRET) {
    return Response.json({ error: "billing_not_configured" }, { status: 500 });
  }
  const sig = req.headers.get("stripe-signature");
  if (!sig) return Response.json({ error: "missing_signature" }, { status: 400 });

  const body = await readTextBody(req, 256 * 1024); // RAW body — never re-serialized
  if (body === null) return Response.json({ error: "payload_too_large" }, { status: 413 });
  let ev: Stripe.Event;
  try {
    ev = await constructWebhookEvent(stripe, body, sig, env.STRIPE_WEBHOOK_SECRET);
  } catch {
    return Response.json({ error: "bad_signature" }, { status: 400 });
  }

  if ((await claimWebhookEvent(env.ENT_DB, ev)) === "skip") {
    return Response.json({ received: true, deduped: true });
  }
  try {
    const outcome = await handleEvent(env, stripe, ev);
    await markWebhookOutcome(env.ENT_DB, ev.id, outcome);
    return Response.json({ received: true });
  } catch (err) {
    const reason = err instanceof Error ? err.message : String(err);
    console.error(`webhook ${ev.type} ${ev.id} failed: ${reason}`);
    await markWebhookOutcome(env.ENT_DB, ev.id, `error:${reason}`.slice(0, 100));
    return Response.json({ error: "handler_failed" }, { status: 500 }); // Stripe retries
  }
}
