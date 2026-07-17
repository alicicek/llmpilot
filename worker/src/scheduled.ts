// Hourly trial-reminder sweep — the consumer-law pre-charge reminder
// Three-day trials get no provider reminder email, so we send one when that
// configuration is enabled. Card-upfront trials only: the no-card rung never
// auto-charges, so there is nothing to warn about; the in-app countdown
// covers it. Idempotent via reminder_sent_at.

import type Stripe from "stripe";
import type { WorkerEnv } from "./env.ts";
import { getStripe } from "./lib/stripe.ts";
import { sendEmail } from "./lib/email.ts";
import { ensureCancellation, licenseBy } from "./lib/licenses.ts";

const REMIND_WITHIN_MS = 24 * 60 * 60 * 1000;

interface ReminderRow {
  id: string;
  email: string | null;
  subscription_id: string | null;
  trial_end: string;
}

function money(amount: number | null | undefined, currency: string | null | undefined): string {
  if (amount == null || !currency) return "the price you chose";
  const v = (amount / 100).toFixed(2);
  const sym: Record<string, string> = { gbp: "£", usd: "$", eur: "€" };
  return `${sym[currency.toLowerCase()] ?? currency.toUpperCase() + " "}${v}`;
}

export async function runReminderSweep(env: WorkerEnv, now: Date): Promise<number> {
  // Eight-day trials use Stripe's own reminder. Flip TRIAL_DAYS to 3 only
  // after this native-email path has been proven; then this sweep takes over.
  if (env.TRIAL_DAYS !== "3") return 0;
  const db = env.ENT_DB;
  const cutoff = new Date(now.getTime() + REMIND_WITHIN_MS).toISOString();
  const due = await db
    .prepare(
      `SELECT id, email, subscription_id, trial_end FROM licenses
       WHERE status = 'trialing' AND rung = 'discount_trial'
         AND reminder_sent_at IS NULL AND trial_end <= ? AND trial_end > ?`,
    )
    .bind(cutoff, now.toISOString())
    .all<ReminderRow>();

  const stripe = getStripe(env);
  let sent = 0;
  for (const row of due.results ?? []) {
    if (!row.email) continue;
    // The exact charge: read the subscription's price (the checkout-locked
    // currency) — the reminder must state the real amount (consumer-law
    // rule a/b), never a guess.
    let amountLine = "the price you chose at checkout";
    if (stripe && row.subscription_id) {
      try {
        const sub = await stripe.subscriptions.retrieve(row.subscription_id);
        const item = (sub as Stripe.Subscription).items?.data?.[0];
        if (item?.price) {
          amountLine = money(item.price.unit_amount, item.price.currency);
        }
      } catch {
        /* keep the honest fallback line */
      }
    }
    const when = new Date(row.trial_end);
    const ok = await sendEmail(
      env,
      row.email,
      "your llmpilot trial ends tomorrow",
      [
        `Your llmpilot Pro trial ends ${when.toUTCString()}.`,
        `${amountLine} will be charged then — once, never again. llmpilot Pro is a lifetime license.`,
        "",
        "To cancel before the charge: open llmpilot → Settings → License → Cancel trial. One click, no questions.",
        "",
        "Questions or a refund, any time: support@llmpilot.dev",
      ].join("\n"),
      "trial_reminder",
    );
    if (ok) {
      await db
        .prepare("UPDATE licenses SET reminder_sent_at = ?, updated_at = ? WHERE id = ?")
        .bind(now.toISOString(), now.toISOString(), row.id)
        .run();
      sent++;
    }
  }
  return sent;
}

export interface ReconcileResult { scanned: number; fixed: number; unresolved: number }

export async function runCancellationReconcile(env: WorkerEnv, stripeOverride?: Stripe): Promise<ReconcileResult> {
  const stripe = stripeOverride ?? getStripe(env);
  if (!stripe) throw new Error("billing_not_configured");
  const result: ReconcileResult = { scanned: 0, fixed: 0, unresolved: 0 };
  let startingAfter: string | undefined;
  for (;;) {
    const page = await stripe.subscriptions.list({ status: "all", limit: 100, ...(startingAfter ? { starting_after: startingAfter } : {}) });
    for (const subscription of page.data) {
      if (subscription.status !== "active" && subscription.status !== "trialing") continue;
      result.scanned++;
      if (subscription.cancel_at) continue;
      const licenseId = subscription.metadata.license_id;
      const lic = licenseId ? await licenseBy(env.ENT_DB, "id", licenseId) : null;
      if (!lic) {
        result.unresolved++;
        continue;
      }
      try {
        await ensureCancellation(stripe, env.ENT_DB, lic, subscription);
        result.fixed++;
      } catch {
        result.unresolved++;
      }
    }
    if (!page.has_more || page.data.length === 0) break;
    startingAfter = page.data.at(-1)!.id;
  }
  console.log(JSON.stringify({ event: "cancellation_reconcile", ...result }));
  return result;
}
