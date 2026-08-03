// Hourly trial-reminder sweep — the consumer-law pre-charge reminder.
// Stripe's own pre-charge email only fires for trials of 7 days or more, so
// any shorter configuration activates this sweep. Card-upfront trials only
// (full and discount rungs): the no-card rung never auto-charges, so there
// is nothing to warn about; the in-app countdown covers it. Each license
// carries the buyer's chosen offset (remind_days_before, 1 or 2).
// Idempotent via reminder_sent_at.

import type Stripe from "stripe";
import type { WorkerEnv } from "./env.ts";
import { getStripe } from "./lib/stripe.ts";
import { sendEmail } from "./lib/email.ts";
import { ensureCancellation, licenseBy } from "./lib/licenses.ts";
import { effectiveTrialDays } from "./lib/terms.ts";

const DAY_MS = 24 * 60 * 60 * 1000;
const MAX_REMIND_DAYS = 2;

interface ReminderRow {
  id: string;
  email: string | null;
  subscription_id: string | null;
  trial_end: string;
  remind_days_before: number;
}

function money(amount: number | null | undefined, currency: string | null | undefined): string {
  if (amount == null || !currency) return "the price you chose";
  const v = (amount / 100).toFixed(2);
  const sym: Record<string, string> = { gbp: "£", usd: "$", eur: "€" };
  return `${sym[currency.toLowerCase()] ?? currency.toUpperCase() + " "}${v}`;
}

export async function runReminderSweep(env: WorkerEnv, now: Date): Promise<number> {
  // Trials of 7+ days use Stripe's own reminder; shorter ones activate this
  // sweep (flip TRIAL_DAYS below 7 only after a delivery from the email
  // provider is proven — worker/OPERATIONS.md).
  if (effectiveTrialDays(env) >= 7) return 0;
  const db = env.ENT_DB;
  // The SQL window is the widest offset; each row's own offset is applied
  // below, where the arithmetic is testable JS instead of SQL date math.
  const cutoff = new Date(now.getTime() + MAX_REMIND_DAYS * DAY_MS).toISOString();
  const due = await db
    .prepare(
      `SELECT id, email, subscription_id, trial_end, remind_days_before FROM licenses
       WHERE status = 'trialing' AND rung IN ('full', 'discount_trial')
         AND reminder_sent_at IS NULL AND trial_end <= ? AND trial_end > ?`,
    )
    .bind(cutoff, now.toISOString())
    .all<ReminderRow>();

  const stripe = getStripe(env);
  let sent = 0, duplicate = 0, failed = 0, dueNow = 0;
  for (const row of due.results ?? []) {
    if (!row.email) continue;
    // Not yet inside this buyer's chosen window — a later hourly run sends it.
    const days = row.remind_days_before === 2 ? 2 : 1;
    if (new Date(row.trial_end).getTime() - now.getTime() > days * DAY_MS) continue;
    dueNow++;
    // The exact charge: read the subscription's price (the checkout-locked
    // currency) — the reminder must state the real amount (consumer-law
    // rule a/b), never a guess.
    let amountLine = "the price you chose at checkout";
    if (stripe && row.subscription_id) {
      try {
        const sub = (await stripe.subscriptions.retrieve(row.subscription_id)) as Stripe.Subscription;
        const item = sub.items?.data?.[0];
        // The Price object reports its BASE currency; a usd-pinned
        // subscription resolves its amount from currency_options at invoice
        // time. Only quote the figure when the currencies agree — the
        // generic fallback beats a wrong exact number (consumer-law rule a).
        if (item?.price && item.price.currency === sub.currency) {
          amountLine = money(item.price.unit_amount, item.price.currency);
        }
      } catch {
        /* keep the honest fallback line */
      }
    }
    const when = new Date(row.trial_end);
    // Word the subject from the CLOCK, not the preference: a delayed cron
    // can first see a 2-day-preference row with under a day left, and
    // "ends in 2 days" would then contradict the body's real instant.
    const endsWithinADay = when.getTime() - now.getTime() <= DAY_MS;
    const outcome = await sendEmail(
      env,
      row.email,
      endsWithinADay ? "your llmpilot trial ends tomorrow" : "your llmpilot trial ends in 2 days",
      [
        `Your llmpilot Pro trial ends ${when.toUTCString()}.`,
        `${amountLine} will be charged then — once, never again. llmpilot Pro is a lifetime license.`,
        "",
        "To cancel before the charge: open llmpilot → Settings → License → Cancel trial. One click, no questions.",
        "",
        "Questions or a refund, any time: support@llmpilot.dev",
      ].join("\n"),
      "trial_reminder",
      `trial_reminder:${row.id}`,
    );
    // "duplicate" means the provider already accepted this reminder on an
    // earlier attempt whose result we lost — the email exists, so stamp it;
    // retrying can never clear a 409 (the payload legitimately drifts).
    if (outcome === "sent" || outcome === "duplicate") {
      await db
        .prepare("UPDATE licenses SET reminder_sent_at = ?, updated_at = ? WHERE id = ?")
        .bind(now.toISOString(), now.toISOString(), row.id)
        .run();
      if (outcome === "sent") sent++;
      else duplicate++;
    } else {
      failed++;
    }
  }
  // Unconditional, every run: "due 3 sent 0" is the alarm line the original
  // silent-failure incident never had. email_configured surfaces a deploy
  // that forgot the provider secret.
  console.log(JSON.stringify({
    event: "trial_reminder_sweep",
    due: dueNow,
    sent,
    duplicate,
    failed,
    email_configured: Boolean(env.RESEND_API_KEY),
  }));
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
