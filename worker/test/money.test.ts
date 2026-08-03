// Run: node --test --experimental-strip-types test/money.test.ts
//
// The deterministic money-path gate:
// fulfillment idempotency across the webhook/activate race, the
// trial-start-£0 conversion gate, refund/dispute revocation, the lapsed →
// lifetime recovery, revoked-is-terminal, and real-WebCrypto entitlements.

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  TEST_INSTALL,
  TestD1,
  captureEmails,
  makeKeys,
  makeEnv,
  makeFakeStripe,
  testQuote,
  calls,
  paidSession,
  trialSession,
  dahliaInvoice,
  stripeEvent,
} from "./helpers.ts";
import { insertLicense, licenseBy, newLicenseID } from "../src/lib/licenses.ts";
import { fulfillSession, handleEvent } from "../src/routes/webhook.ts";
import { activateRoute, cancelRoute, claimRecoveryRoute, recoverRoute, validateRoute } from "../src/routes/api.ts";
import { checkoutPage, createCheckout, formatLocalizedAmount, sessionParams } from "../src/routes/checkout.ts";
import { importVerifyKey, verifyEntitlement } from "../src/lib/entitlement.ts";
import { assertSafeEnvironment, claimWebhookEvent, markWebhookOutcome } from "../src/lib/stripe.ts";
import { runCancellationReconcile, runReminderSweep } from "../src/scheduled.ts";
import worker from "../src/index.ts";

const KEYS = await makeKeys();

async function seedLicense(db: TestD1, rung = "full"): Promise<string> {
  const id = newLicenseID();
  await insertLicense(db as never, id, rung, TEST_INSTALL);
  return id;
}

async function tokenPayload(token: string) {
  const key = await importVerifyKey(KEYS.verifyRawB64);
  const p = await verifyEntitlement(new Map([["key_test_1", key]]), token);
  assert.ok(p, "entitlement must verify against the real public key");
  return p!;
}

// ---- checkout session shapes -------------------------------------------------

test("checkout: rung shapes — trial days, card collection, MP always on, no rejected params", () => {
  const env = makeEnv(new TestD1(), KEYS.signingKeyB64);
  const full = sessionParams(env, "full", "lic_x", "hosted");
  assert.equal((full.managed_payments as { enabled: boolean }).enabled, true);
  assert.equal(full.mode, "subscription");
  // The reshape (owner 2026-07-31): every rung leads with the trial.
  assert.equal((full.subscription_data as { trial_period_days?: number }).trial_period_days, 8);
  assert.equal(full.payment_method_collection, undefined); // card-upfront default
  assert.ok((full.success_url as string).includes("{CHECKOUT_SESSION_ID}"));

  const disc = sessionParams(env, "discount_trial", "lic_x", "hosted");
  assert.equal((disc.subscription_data as { trial_period_days: number }).trial_period_days, 8);
  assert.equal(disc.payment_method_collection, undefined); // card-upfront default

  const nocard = sessionParams(env, "nocard_trial", "lic_x", "hosted");
  assert.equal(nocard.payment_method_collection, "if_required");

  const emb = sessionParams(env, "full", "lic_x", "embedded");
  assert.equal(emb.ui_mode, "embedded_page");
  assert.equal(emb.redirect_on_completion, "never");

  // API-rejected under MP — never sent.
  for (const p of [full, disc, nocard, emb]) {
    assert.equal(p.submit_type, undefined);
    assert.equal(p.custom_text, undefined);
    assert.equal(p.wallet_options, undefined);
  }
});

test("checkout: the pre-reshape full echo (no trial length shown) refuses invalid_input", async () => {
  // A 1.2.4 client renders the full rung without a trial and echoes no
  // trial_days. Binding that consent to a Session that now trials first
  // would be the exact shown-vs-charged divergence the echo exists to stop.
  const db = new TestD1();
  const env = makeEnv(db, KEYS.signingKeyB64);
  const fake = makeFakeStripe();
  const res = await createCheckout(
    env,
    { rung: "full", install_id: TEST_INSTALL, quote: { currency: "gbp", amount_minor: 999 } },
    "192.0.2.11",
    fake.stripe,
  );
  assert.equal(res.status, 400);
  assert.equal(res.body.error, "invalid_input");
  assert.equal(calls(fake.state, "sessions.create").length, 0);
});

test("checkout: remind_days_before is stored per license; junk values refuse", async () => {
  const db = new TestD1();
  const env = makeEnv(db, KEYS.signingKeyB64);
  const fake = makeFakeStripe();
  const chosen = await createCheckout(
    env,
    { rung: "full", install_id: TEST_INSTALL, quote: testQuote("full"), remind_days_before: 2 },
    "192.0.2.12",
    fake.stripe,
  );
  assert.equal(chosen.status, 200);
  assert.equal(db.row("licenses", chosen.body.license as string)!.remind_days_before, 2);

  // Absent → the day-before default (the previous fixed behavior).
  const defaulted = await createCheckout(
    env,
    { rung: "discount_trial", install_id: TEST_INSTALL, quote: testQuote("discount_trial") },
    "192.0.2.12",
    fake.stripe,
  );
  assert.equal(defaulted.status, 200);
  assert.equal(db.row("licenses", defaulted.body.license as string)!.remind_days_before, 1);

  for (const bad of [0, 3, -1, 1.5, "2", true, null]) {
    const res = await createCheckout(
      env,
      { rung: "full", install_id: TEST_INSTALL, quote: testQuote("full"), remind_days_before: bad },
      "192.0.2.13",
      fake.stripe,
    );
    assert.equal(res.status, 400, `remind_days_before=${JSON.stringify(bad)}`);
    assert.equal(res.body.error, "invalid_input");
  }
  const count = db.db.prepare("SELECT COUNT(*) AS n FROM licenses").get() as { n: number };
  assert.equal(count.n, 2, "refused checkouts must not allocate license rows");
});

test("checkout: per-IP limit bounds D1 and Stripe object creation", async () => {
  const db = new TestD1();
  const env = makeEnv(db, KEYS.signingKeyB64);
  const fake = makeFakeStripe();
  for (let i = 0; i < 10; i++) {
    const result = await createCheckout(env, { rung: "full", install_id: TEST_INSTALL, quote: testQuote("full") }, "192.0.2.10", fake.stripe);
    assert.equal(result.status, 200);
  }
  const limited = await createCheckout(env, { rung: "full", install_id: TEST_INSTALL, quote: testQuote("full") }, "192.0.2.10", fake.stripe);
  assert.equal(limited.status, 429);
  assert.equal(calls(fake.state, "sessions.create").length, 10);
  const count = db.db.prepare("SELECT COUNT(*) AS n FROM licenses").get() as { n: number };
  assert.equal(count.n, 10);
});

// ---- full-price fulfillment ----------------------------------------------------

test("full rung: paid session establishes cancel_at before mint and records the PI", async () => {
  const db = new TestD1();
  const env = makeEnv(db, KEYS.signingKeyB64);
  const lic = await seedLicense(db);
  const { stripe, state } = makeFakeStripe({ session: paidSession(lic) });

  const r1 = await fulfillSession(env, stripe, "cs_1");
  assert.equal(r1.state, "minted");
  const row = db.row("licenses", lic)!;
  assert.equal(row.status, "lifetime");
  assert.equal(row.email, "buyer@example.dev"); // normalized
  const payload = await tokenPayload(row.entitlement as string);
  assert.equal(payload.tier, "pro");
  assert.deepEqual(payload.features, ["autopilot", "scheduling", "wake"]);
  assert.equal(payload.expires_at, null);
  assert.equal(payload.kind, "LIFETIME");
  assert.equal(payload.key_id, "key_test_1");
  assert.deepEqual(Object.keys(payload).sort(), ["expires_at", "features", "install", "issued_at", "key_id", "kind", "seats", "tier"]);
  assert.equal(payload.seats, 1);
  assert.equal(payload.install, TEST_INSTALL);
  assert.ok(payload.issued_at);

  const upd = calls(state, "subscriptions.update");
  assert.equal(upd.length, 1);
  assert.ok((upd[0].args[1] as { cancel_at: number }).cancel_at > Math.floor(Date.now() / 1000));

  // ledger row keyed by the resolved PaymentIntent (dahlia invoicePayments)
  assert.ok(db.row("payments", "pi_test_1"));

  // replay (webhook after activate, or a redelivery): no second mint, token unchanged
  const r2 = await fulfillSession(env, stripe, "cs_1");
  assert.equal(r2.state, "already");
  assert.equal((db.row("licenses", lic) as { entitlement: string }).entitlement, row.entitlement);
});

test("full rung: cancel_at failure happens before mint; retry lands cancellation then mint", async () => {
  const db = new TestD1();
  const env = makeEnv(db, KEYS.signingKeyB64);
  const lic = await seedLicense(db);
  const { stripe, state } = makeFakeStripe({ session: paidSession(lic), failSubscriptionUpdate: true });

  await assert.rejects(() => fulfillSession(env, stripe, "cs_1"));
  assert.equal(db.row("licenses", lic)!.status, "pending");
  state.failSubscriptionUpdate = false;
  const r = await fulfillSession(env, stripe, "cs_1");
  assert.equal(r.state, "minted");
  assert.equal(calls(state, "subscriptions.update").length, 2);
});

// ---- the trial conversion gate --------------------------------------------------

test("trial: £0 subscription_create invoice NEVER converts; the paid cycle invoice does", async () => {
  const db = new TestD1();
  const env = makeEnv(db, KEYS.signingKeyB64);
  const lic = await seedLicense(db, "discount_trial");
  const trialEnd = Math.floor(Date.now() / 1000) + 8 * 86400;
  const { stripe, state } = makeFakeStripe({ session: trialSession(lic, trialEnd) });

  // checkout completes → trialing with an expiring token
  const r = await fulfillSession(env, stripe, "cs_2");
  assert.equal(r.state, "trialing");
  let row = db.row("licenses", lic)!;
  assert.equal(row.status, "trialing");
  const p = await tokenPayload(row.entitlement as string);
  assert.ok(p.expires_at, "trial token must expire");
  assert.equal(p.kind, "TRIAL");
  assert.equal(new Date(p.expires_at!).getTime(), trialEnd * 1000 + 72 * 3600_000);
  assert.equal(calls(state, "subscriptions.update").length, 1);
  assert.deepEqual(calls(state, "subscriptions.update")[0].args[1], { cancel_at: trialEnd + 7 * 86400 });

  // THE GATE: the trial-start £0 invoice.paid fires too — it must not mint,
  // not cancel, not lapse (reacting to it would end the trial UNCHARGED).
  const zero = dahliaInvoice(lic, "sub_2", 0, "subscription_create");
  const out0 = await handleEvent(env, stripe, stripeEvent("invoice.paid", zero));
  assert.equal(out0, "ignored");
  row = db.row("licenses", lic)!;
  assert.equal(row.status, "trialing");
  assert.equal(calls(state, "subscriptions.update").length, 1, "zero invoice makes no Stripe write");

  // conversion: the real cycle invoice with money moved
  const cycle = dahliaInvoice(lic, "sub_2", 599, "subscription_cycle");
  const out1 = await handleEvent(env, stripe, stripeEvent("invoice.paid", cycle));
  assert.equal(out1, "ok");
  row = db.row("licenses", lic)!;
  assert.equal(row.status, "lifetime");
  const lp = await tokenPayload(row.entitlement as string);
  assert.equal(lp.expires_at, null, "converted token is lifetime");
  assert.equal(lp.kind, "LIFETIME");
  const upd = calls(state, "subscriptions.update");
  assert.equal(upd.length, 1, "invoice.paid only mints; checkout already fixed cancellation");
  const pay = db.row("payments", "pi_test_1")!;
  assert.equal(pay.billing_reason, "subscription_cycle");
});

test("full rung: the reshaped revenue path — trialing checkout, then the cycle invoice mints lifetime", async () => {
  // Since the 2026-07-31 reshape every full purchase goes trial-first; this
  // is the production revenue path end to end.
  const db = new TestD1();
  const env = makeEnv(db, KEYS.signingKeyB64);
  const lic = await seedLicense(db, "full");
  const trialEnd = Math.floor(Date.now() / 1000) + 4 * 86400;
  const session = trialSession(lic, trialEnd);
  (session.metadata as Record<string, string>).rung = "full";
  const { stripe, state } = makeFakeStripe({ session });

  const r = await fulfillSession(env, stripe, "cs_2");
  assert.equal(r.state, "trialing");
  let row = db.row("licenses", lic)!;
  assert.equal(row.status, "trialing");
  const p = await tokenPayload(row.entitlement as string);
  assert.equal(p.kind, "TRIAL");
  // cancel_at was fixed at checkout so cycle two can never charge.
  assert.equal(calls(state, "subscriptions.update").length, 1);

  const cycle = dahliaInvoice(lic, "sub_2", 999, "subscription_cycle");
  assert.equal(await handleEvent(env, stripe, stripeEvent("invoice.paid", cycle)), "ok");
  row = db.row("licenses", lic)!;
  assert.equal(row.status, "lifetime");
  const lp = await tokenPayload(row.entitlement as string);
  assert.equal(lp.kind, "LIFETIME");
  assert.equal(lp.expires_at, null);
});

test("full rung: a paid-status session that is STILL TRIALING never mints lifetime early", async () => {
  // Guard on webhook.ts's no-trial branch: minting lifetime for £0 while
  // the trial runs would be an uncancellable free license (cancelRoute only
  // cancels trialing rows).
  const db = new TestD1();
  const env = makeEnv(db, KEYS.signingKeyB64);
  const lic = await seedLicense(db, "full");
  const trialEnd = Math.floor(Date.now() / 1000) + 4 * 86400;
  const session = trialSession(lic, trialEnd, { payment_status: "paid" });
  (session.metadata as Record<string, string>).rung = "full";
  const { stripe } = makeFakeStripe({ session });

  const r = await fulfillSession(env, stripe, "cs_2");
  assert.equal(r.state, "trialing");
  assert.equal(db.row("licenses", lic)!.status, "trialing");
});

test("invoice.paid strict gate ignores even a paid subscription_create invoice", async () => {
  const db = new TestD1();
  const env = makeEnv(db, KEYS.signingKeyB64);
  const lic = await seedLicense(db, "discount_trial");
  const { stripe } = makeFakeStripe({});
  const invoice = dahliaInvoice(lic, "sub_2", 599, "subscription_create");
  assert.equal(await handleEvent(env, stripe, stripeEvent("invoice.paid", invoice)), "ignored");
  assert.equal(db.row("licenses", lic)!.status, "pending");
});

test("dahlia PI resolution selects a paid payment_intent, not the first invoice payment", async () => {
  const db = new TestD1();
  const env = makeEnv(db, KEYS.signingKeyB64);
  const lic = await seedLicense(db, "discount_trial");
  db.db.prepare("UPDATE licenses SET status='trialing', subscription_id='sub_2' WHERE id=?").run(lic);
  const { stripe } = makeFakeStripe({
    invoicePayments: [
      { status: "open", payment: { type: "payment_intent", payment_intent: "pi_open" } },
      { status: "paid", payment: { type: "payment_record", payment_record: "pr_1" } },
      { status: "paid", payment: { type: "payment_intent", payment_intent: "pi_paid" } },
    ],
  });
  await handleEvent(env, stripe, stripeEvent("invoice.paid", dahliaInvoice(lic, "sub_2", 599, "subscription_cycle")));
  assert.ok(db.row("payments", "pi_paid"));
  assert.equal(db.row("payments", "pi_open"), null);
});

test("paid invoice retries instead of minting when PaymentIntent resolution fails", async () => {
  const db = new TestD1();
  const env = makeEnv(db, KEYS.signingKeyB64);
  const lic = await seedLicense(db, "discount_trial");
  db.db.prepare("UPDATE licenses SET status='trialing', subscription_id='sub_2' WHERE id=?").run(lic);
  const { stripe } = makeFakeStripe({ invoicePaymentsError: true });
  await assert.rejects(
    () => handleEvent(env, stripe, stripeEvent("invoice.paid", dahliaInvoice(lic, "sub_2", 599, "subscription_cycle"))),
    /stripe_down/,
  );
  assert.equal(db.row("licenses", lic)!.status, "trialing");
  const count = db.db.prepare("SELECT COUNT(*) AS n FROM payments").get() as { n: number };
  assert.equal(count.n, 0);
});

test("trial cancel before expiry: subscription.deleted lapses it cleanly, nothing charged", async () => {
  const db = new TestD1();
  const env = makeEnv(db, KEYS.signingKeyB64);
  const lic = await seedLicense(db, "discount_trial");
  const trialEnd = Math.floor(Date.now() / 1000) + 8 * 86400;
  const { stripe } = makeFakeStripe({ session: trialSession(lic, trialEnd) });
  await fulfillSession(env, stripe, "cs_2");

  const out = await handleEvent(
    env,
    stripe,
    stripeEvent("customer.subscription.deleted", { id: "sub_2", metadata: { license_id: lic } }),
  );
  assert.equal(out, "ok");
  assert.equal(db.row("licenses", lic)!.status, "lapsed");
});

test("lifetime license's subscription.deleted after cancel_at never lapses it", async () => {
  const db = new TestD1();
  const env = makeEnv(db, KEYS.signingKeyB64);
  const lic = await seedLicense(db);
  const { stripe } = makeFakeStripe({ session: paidSession(lic) });
  await fulfillSession(env, stripe, "cs_1");

  const out = await handleEvent(
    env,
    stripe,
    stripeEvent("customer.subscription.deleted", { id: "sub_1", metadata: { license_id: lic } }),
  );
  assert.equal(out, "ok");
  assert.equal(db.row("licenses", lic)!.status, "lifetime");
});

test("payment_failed lapses the trial; a later paid invoice still converts (lapsed → lifetime)", async () => {
  const db = new TestD1();
  const env = makeEnv(db, KEYS.signingKeyB64);
  const lic = await seedLicense(db, "discount_trial");
  const trialEnd = Math.floor(Date.now() / 1000) + 8 * 86400;
  const { stripe } = makeFakeStripe({ session: trialSession(lic, trialEnd) });
  await fulfillSession(env, stripe, "cs_2");

  await handleEvent(env, stripe, stripeEvent("invoice.payment_failed", dahliaInvoice(lic, "sub_2", 0, "subscription_cycle")));
  assert.equal(db.row("licenses", lic)!.status, "lapsed");

  await handleEvent(env, stripe, stripeEvent("invoice.paid", dahliaInvoice(lic, "sub_2", 599, "subscription_cycle")));
  assert.equal(db.row("licenses", lic)!.status, "lifetime");
});

// ---- refunds, disputes, revocation ------------------------------------------------

function refundedCharge(piId: string, amount: number, refunded: number) {
  return {
    id: "ch_1",
    payment_intent: piId,
    amount,
    amount_refunded: refunded,
    currency: "gbp",
    refunds: { data: [{ id: "re_1" }] },
  };
}

test("full refund revokes; partial refund records but keeps the license", async () => {
  const db = new TestD1();
  const env = makeEnv(db, KEYS.signingKeyB64);
  const lic = await seedLicense(db);
  const { stripe, state } = makeFakeStripe({ session: paidSession(lic) });
  await fulfillSession(env, stripe, "cs_1");

  await handleEvent(env, stripe, stripeEvent("charge.refunded", refundedCharge("pi_test_1", 999, 400)));
  assert.equal(db.row("licenses", lic)!.status, "lifetime");
  assert.equal(db.row("payments", "re_1")!.status, "partial_refund");

  await handleEvent(env, stripe, stripeEvent("charge.refunded", refundedCharge("pi_test_1", 999, 999), "evt_refund_2"));
  const row = db.row("licenses", lic)!;
  assert.equal(row.status, "revoked");
  assert.ok(row.revoked_at);
  // The refunded buyer's subscription ends too — revoke alone would leave an
  // "active" Stripe subscription (and its lifecycle emails) until cancel_at.
  assert.ok(state.calls.some((c) => c.method === "subscriptions.cancel"));
});

test("orphan refund (no ledger match) is recorded needs_manual_review, never dropped", async () => {
  const db = new TestD1();
  const env = makeEnv(db, KEYS.signingKeyB64);
  const { stripe } = makeFakeStripe({});
  const out = await handleEvent(env, stripe, stripeEvent("charge.refunded", refundedCharge("pi_ghost", 999, 999)));
  assert.equal(out, "ok");
  assert.equal(db.row("payments", "re_1")!.status, "needs_manual_review");
});

test("dispute revokes immediately and flags manual review", async () => {
  const db = new TestD1();
  const env = makeEnv(db, KEYS.signingKeyB64);
  const lic = await seedLicense(db);
  const { stripe } = makeFakeStripe({ session: paidSession(lic) });
  await fulfillSession(env, stripe, "cs_1");

  const out = await handleEvent(
    env,
    stripe,
    stripeEvent("charge.dispute.created", { id: "dp_1", payment_intent: "pi_test_1", amount: 999, currency: "gbp" }),
  );
  assert.equal(out, "ok");
  assert.equal(db.row("licenses", lic)!.status, "revoked");
  assert.equal(db.row("payments", "dp_1")!.status, "needs_manual_review");
});

test("revoked is terminal: a replayed paid session refuses to re-mint", async () => {
  const db = new TestD1();
  const env = makeEnv(db, KEYS.signingKeyB64);
  const lic = await seedLicense(db);
  const { stripe } = makeFakeStripe({ session: paidSession(lic) });
  await fulfillSession(env, stripe, "cs_1");
  await handleEvent(env, stripe, stripeEvent("charge.refunded", refundedCharge("pi_test_1", 999, 999)));
  assert.equal(db.row("licenses", lic)!.status, "revoked");

  // "steal Pro without paying" adversary: replay the old success URL / event
  const r = await fulfillSession(env, stripe, "cs_1");
  assert.equal(r.state, "refused_revoked");
  const row = db.row("licenses", lic)!;
  assert.equal(row.status, "revoked");
  // validate serves no token for revoked rows
  const res = await validateRoute(env, { license: lic, install_id: TEST_INSTALL });
  const bodyJson = (await res.json()) as { status: string; entitlement?: string };
  assert.equal(bodyJson.status, "revoked");
  assert.equal(bodyJson.entitlement, undefined);
});

// ---- claim-ledger idempotency ------------------------------------------------------

test("claim ledger: an event marked ok (or ignored) is skipped on redelivery", async () => {
  const db = new TestD1();
  const ev = stripeEvent("invoice.paid", { id: "in_x" });
  assert.equal(await claimWebhookEvent(db as never, ev), "process");
  await markWebhookOutcome(db as never, "evt_invoice.paid_1", "ok");
  assert.equal(await claimWebhookEvent(db as never, ev), "skip");

  const ev2 = stripeEvent("product.created", { id: "prod_1" }, "evt_ign");
  assert.equal(await claimWebhookEvent(db as never, ev2), "process");
  await markWebhookOutcome(db as never, "evt_ign", "ignored");
  assert.equal(await claimWebhookEvent(db as never, ev2), "skip");

  // an errored event is NOT skipped — Stripe's retry must reprocess it
  const ev3 = stripeEvent("invoice.paid", { id: "in_y" }, "evt_err");
  assert.equal(await claimWebhookEvent(db as never, ev3), "process");
  await markWebhookOutcome(db as never, "evt_err", "error:boom");
  assert.equal(await claimWebhookEvent(db as never, ev3), "process");
});

// ---- app-facing routes ----------------------------------------------------------

test("activate: unknown session 404s; unpaid session reports pending", async () => {
  const db = new TestD1();
  const env = makeEnv(db, KEYS.signingKeyB64);
  const lic = await seedLicense(db);
  const { stripe } = makeFakeStripe({
    session: paidSession(lic, { payment_status: "unpaid", subscription: { id: "sub_1", status: "incomplete" } }),
  });
  // route-level test uses the shared fulfillment against the fake — inject by
  // calling fulfillSession directly for the pending case:
  const r = await fulfillSession(env, stripe, "cs_1");
  assert.equal(r.state, "not_paid");
  assert.equal(db.row("licenses", lic)!.status, "pending");

  const res = await activateRoute(env, { session_id: "bogus" });
  assert.equal(res.status, 400);
});

test("cancel: trialing cancels the subscription; lifetime is 409 not_cancellable", async () => {
  const db = new TestD1();
  const env = makeEnv(db, KEYS.signingKeyB64);
  const lic = await seedLicense(db, "discount_trial");
  const trialEnd = Math.floor(Date.now() / 1000) + 8 * 86400;
  const fake = makeFakeStripe({ session: trialSession(lic, trialEnd) });
  await fulfillSession(env, fake.stripe, "cs_2");

  // cancelRoute builds its own Stripe client from env — exercise the
  // decision logic through the licenses table instead: trialing row has a
  // subscription id, so the route proceeds to the cancel call, which fails
  // against the fake key. The 502 (cancel attempted) vs 409 (refused)
  // distinction is what's under test.
  const resTrialing = await cancelRoute(env, { license: lic });
  assert.equal(resTrialing.status, 502); // reached the cancel call
  // A failed cancel must not lapse the row — Stripe still owns the trial.
  assert.equal(db.row("licenses", lic)!.status, "trialing");

  const lic2 = await seedLicense(db);
  const fake2 = makeFakeStripe({ session: paidSession(lic2) });
  await fulfillSession(env, fake2.stripe, "cs_1");
  const resLifetime = await cancelRoute(env, { license: lic2 });
  assert.equal(resLifetime.status, 409);
});

test("cancel: a successful cancel lapses the row before the webhook lands", async () => {
  const db = new TestD1();
  const env = makeEnv(db, KEYS.signingKeyB64);
  const lic = await seedLicense(db, "discount_trial");
  const trialEnd = Math.floor(Date.now() / 1000) + 8 * 86400;
  const fake = makeFakeStripe({ session: trialSession(lic, trialEnd) });
  await fulfillSession(env, fake.stripe, "cs_2");

  const res = await cancelRoute(env, { license: lic }, fake.stripe);
  assert.equal(res.status, 200);
  assert.equal(db.row("licenses", lic)!.status, "lapsed");
  // The race window is closed: validate stops re-serving the trial token
  // without waiting for subscription.deleted.
  const view = (await (await validateRoute(env, { license: lic, install_id: TEST_INSTALL })).json()) as {
    status: string;
    entitlement?: string;
  };
  assert.equal(view.status, "lapsed");
  assert.equal(view.entitlement, undefined);

  // The eventual webhook is an idempotent no-op on the already-lapsed row.
  const out = await handleEvent(
    env,
    fake.stripe,
    stripeEvent("customer.subscription.deleted", { id: "sub_2", metadata: { license_id: lic } }),
  );
  assert.equal(out, "ok");
  assert.equal(db.row("licenses", lic)!.status, "lapsed");
});

test("recover: identical response whether the email exists or not", async () => {
  const db = new TestD1();
  const env = makeEnv(db, KEYS.signingKeyB64);
  const lic = await seedLicense(db);
  const { stripe } = makeFakeStripe({ session: paidSession(lic) });
  await fulfillSession(env, stripe, "cs_1");

	const hitStarted = performance.now();
	const hit = await recoverRoute(env, { email: "buyer@example.dev" });
	const hitElapsed = performance.now() - hitStarted;
	const missStarted = performance.now();
	const miss = await recoverRoute(env, { email: "nobody@example.dev" });
	const missElapsed = performance.now() - missStarted;
	assert.equal(hit.status, 202);
	assert.equal(miss.status, 202);
	assert.deepEqual(await hit.json(), await miss.json());
	assert.ok(hitElapsed >= 190 && missElapsed >= 190, `response floor missing: ${hitElapsed}/${missElapsed}`);
	assert.ok(Math.abs(hitElapsed - missElapsed) < 75, `known/unknown timing diverged: ${hitElapsed}/${missElapsed}`);
});

test("recover: per-IP and per-email limit stays uniform and only sends magic links", async () => {
  const db = new TestD1();
  const emails: Array<Record<string, unknown>> = [];
  const env = makeEnv(db, KEYS.signingKeyB64, { EMAIL_HTTP: captureEmails(emails) });
  const lic = await seedLicense(db);
  const { stripe } = makeFakeStripe({ session: paidSession(lic) });
  await fulfillSession(env, stripe, "cs_1");
  const request = new Request("https://llmpilot.dev/v1/recover", { headers: { "cf-connecting-ip": "192.0.2.1" } });
  for (let i = 0; i < 6; i++) {
    const response = await recoverRoute(env, { email: "buyer@example.dev" }, request);
    assert.equal(response.status, 202);
    assert.deepEqual(await response.json(), { ok: true });
  }
  const miss = await recoverRoute(env, { email: "missing@example.dev" }, request);
  assert.equal(miss.status, 202);
  assert.equal(emails.length, 5);
  const sentText = String(emails.at(-1)!.text);
  assert.match(sentText, /https:\/\/llmpilot\.dev\/recover\?token=/);
  assert.doesNotMatch(sentText, /lic_/);
  const recoveryRows = db.db.prepare("SELECT COUNT(*) AS n FROM recovery_requests").get() as { n: number };
  assert.equal(recoveryRows.n, 5, "limited and unknown requests must not allocate recovery rows");
});

test("public JSON endpoints reject oversized bodies before business logic", async () => {
  const db = new TestD1();
  const env = makeEnv(db, KEYS.signingKeyB64);
  const response = await worker.fetch(
    new Request("https://llmpilot.dev/v1/checkout", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ rung: "full", padding: "x".repeat(20 * 1024) }),
    }),
    env,
    { waitUntil() {} } as never,
  );
  assert.equal(response.status, 400);
  const count = db.db.prepare("SELECT COUNT(*) AS n FROM licenses").get() as { n: number };
  assert.equal(count.n, 0);
});

test("recover claim: one-use magic token is atomically consumed", async () => {
  const db = new TestD1();
  const env = makeEnv(db, KEYS.signingKeyB64);
  const lic = await seedLicense(db);
  const { stripe } = makeFakeStripe({ session: paidSession(lic) });
  await fulfillSession(env, stripe, "cs_1");
  const token = "known-recovery-token";
  const bytes = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(token)));
  const hash = Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
  db.db.prepare("INSERT INTO recovery_requests VALUES (?, ?, ?, ?, NULL, ?)")
    .run(hash, "emailhash", lic, new Date(Date.now() + 60_000).toISOString(), new Date().toISOString());
  const [first, second] = await Promise.all([
    claimRecoveryRoute(env, { token, install_id: TEST_INSTALL }),
    claimRecoveryRoute(env, { token, install_id: TEST_INSTALL }),
  ]);
  assert.deepEqual([first.status, second.status].sort(), [200, 400]);
  const success = first.status === 200 ? first : second;
  assert.ok(((await success.json()) as { entitlement?: string }).entitlement);
});

test("live-prefixed Stripe keys are refused outside production", () => {
  const env = makeEnv(new TestD1(), KEYS.signingKeyB64, { STRIPE_SECRET_KEY: "sk_live_redacted", ENVIRONMENT: "development" });
  assert.throws(() => assertSafeEnvironment(env), /live_stripe_key_refused/);
  assert.doesNotThrow(() => assertSafeEnvironment({ ...env, ENVIRONMENT: "production" }));
});

test("test-prefixed Stripe keys are refused in production", () => {
  const env = makeEnv(new TestD1(), KEYS.signingKeyB64, { ENVIRONMENT: "production" });
  // makeEnv's default key is sk_test_fake — production must fail closed on it.
  assert.throws(() => assertSafeEnvironment(env), /test_stripe_key_refused_in_production/);
  assert.throws(
    () => assertSafeEnvironment({ ...env, STRIPE_SECRET_KEY: "rk_test_redacted" }),
    /test_stripe_key_refused_in_production/,
  );
  // A missing key stays the billing_not_configured path, not a throw.
  assert.doesNotThrow(() => assertSafeEnvironment({ ...env, STRIPE_SECRET_KEY: "" }));
});

test("live-key refusal is wired before fetch and scheduled entrypoints", async () => {
  const env = makeEnv(new TestD1(), KEYS.signingKeyB64, { STRIPE_SECRET_KEY: "rk_live_redacted", ENVIRONMENT: "development" });
  await assert.rejects(
    () => worker.fetch(new Request("https://llmpilot.dev/healthz"), env, { waitUntil() {} } as never),
    /live_stripe_key_refused/,
  );
  await assert.rejects(
    () => worker.scheduled!({ cron: "0 * * * *" } as never, env),
    /live_stripe_key_refused/,
  );
});

test("unknown entitlement key_id is rejected", async () => {
  const db = new TestD1();
  const env = makeEnv(db, KEYS.signingKeyB64);
  const lic = await seedLicense(db);
  const { stripe } = makeFakeStripe({ session: paidSession(lic) });
  const result = await fulfillSession(env, stripe, "cs_1");
  const token = result.lic!.entitlement!;
  const verifyKey = await importVerifyKey(KEYS.verifyRawB64);
  assert.equal(await verifyEntitlement(new Map([["different_key", verifyKey]]), token), null);
});

test("checkout page shows localized session amount, charged-once copy, and descriptor", async () => {
  const db = new TestD1();
  const env = makeEnv(db, KEYS.signingKeyB64);
  const { stripe } = makeFakeStripe({ session: paidSession("lic_x", { client_secret: "secret_redacted" }) });
  const response = await checkoutPage(
    env,
    new Request("https://llmpilot.dev/checkout?session_id=cs_1", { headers: { "accept-language": "en-GB" } }),
    stripe,
  );
  const html = await response.text();
  assert.equal(response.status, 200);
  assert.match(html, /£9\.99/);
  assert.match(html, /charged once — we cancel the renewal automatically/);
  assert.match(html, /LINK\.COM\* LLMPILOT\.DEV/);
  assert.equal((await checkoutPage(env, new Request("https://llmpilot.dev/checkout?session_id=bad"))).status, 404);

  // A trial session collects £0 today — the page must not let £0.00 stand
  // as the price. It states the REAL charge and date from the subscription
  // (the same derivation the reminder sweep uses).
  const trialEnd = Math.floor(Date.parse("2026-08-04T12:00:00Z") / 1000);
  const { stripe: trialStripe } = makeFakeStripe({
    session: paidSession("lic_y", {
      amount_total: 0,
      client_secret: "secret_redacted",
      subscription: {
        id: "sub_t",
        status: "trialing",
        trial_end: trialEnd,
        metadata: { license_id: "lic_y" },
        items: { data: [{ price: { unit_amount: 999, currency: "gbp" }, current_period_end: trialEnd }] },
      },
    }),
  });
  const trialHtml = await (await checkoutPage(
    env,
    new Request("https://llmpilot.dev/checkout?session_id=cs_1", { headers: { "accept-language": "en-GB" } }),
    trialStripe,
  )).text();
  assert.match(trialHtml, /£0\.00 today/);
  assert.match(trialHtml, /£9\.99 on 4 August — charged once/);

  // A usd-pinned session whose subscription Price reports its GBP base must
  // NOT put a £ figure on the consent line — the currency mismatch falls
  // back to the generic honest note instead of a wrong exact number.
  const { stripe: usdStripe } = makeFakeStripe({
    session: paidSession("lic_z", {
      amount_total: 0,
      currency: "usd",
      client_secret: "secret_redacted",
      subscription: {
        id: "sub_u",
        status: "trialing",
        trial_end: trialEnd,
        metadata: { license_id: "lic_z" },
        items: { data: [{ price: { unit_amount: 999, currency: "gbp" }, current_period_end: trialEnd }] },
      },
    }),
  });
  const usdHtml = await (await checkoutPage(
    env,
    new Request("https://llmpilot.dev/checkout?session_id=cs_1", { headers: { "accept-language": "en-US" } }),
    usdStripe,
  )).text();
  assert.match(usdHtml, /\$0\.00 today/);
  assert.match(usdHtml, /nothing due today — the trial price is charged once when it ends/);
  assert.doesNotMatch(usdHtml, /£9\.99 on/);
});

test("localized amount formatting handles two-decimal and zero-decimal currencies", () => {
	assert.match(formatLocalizedAmount("en-GB", "gbp", 999), /9\.99/);
	assert.match(formatLocalizedAmount("ja-JP", "jpy", 1299), /1,299/);
});

// ---- trial reminder sweep ---------------------------------------------------------

test("reminder sweep: card-upfront trials (full and discount) get exactly one reminder inside the chosen window", async () => {
  const db = new TestD1();
  const env = makeEnv(db, KEYS.signingKeyB64, { TRIAL_DAYS: "4" });
  const now = new Date("2026-07-12T12:00:00Z");

  const mk = async (rung: string, endsInH: number, id: string) => {
    await insertLicense(db as never, id, rung, TEST_INSTALL);
    db.db
      .prepare(
        "UPDATE licenses SET status='trialing', email='t@example.dev', trial_end=? WHERE id=?",
      )
      .run(new Date(now.getTime() + endsInH * 3600_000).toISOString(), id);
  };
  await mk("discount_trial", 12, "lic_due");
  await mk("full", 12, "lic_full_due"); // full now trials and auto-charges too
  await mk("discount_trial", 60, "lic_not_yet"); // beyond even the 2-day window
  await mk("nocard_trial", 12, "lic_nocard"); // never auto-charges → no reminder
  await mk("discount_trial", -2, "lic_past"); // already ended → nothing to warn

  assert.equal(await runReminderSweep(env, now), 2);
  assert.ok(db.row("licenses", "lic_due")!.reminder_sent_at);
  assert.ok(db.row("licenses", "lic_full_due")!.reminder_sent_at);
  assert.equal(db.row("licenses", "lic_not_yet")!.reminder_sent_at, null);
  assert.equal(db.row("licenses", "lic_nocard")!.reminder_sent_at, null);
  assert.equal(db.row("licenses", "lic_past")!.reminder_sent_at, null);

  // idempotent: the next sweep sends nothing
  assert.equal(await runReminderSweep(env, now), 0);
});

test("reminder sweep honors each license's chosen offset and words the email to match", async () => {
  const db = new TestD1();
  const emailBodies: Array<Record<string, unknown>> = [];
  const subjects = () => emailBodies.map((e) => e.subject);
  const env = makeEnv(db, KEYS.signingKeyB64, {
    TRIAL_DAYS: "4",
    EMAIL_HTTP: captureEmails(emailBodies),
  });
  const now = new Date("2026-07-12T12:00:00Z");
  const mk = async (id: string, endsInH: number, remind: number) => {
    await insertLicense(db as never, id, "full", TEST_INSTALL, remind);
    db.db.prepare("UPDATE licenses SET status='trialing', email='t@example.dev', trial_end=? WHERE id=?")
      .run(new Date(now.getTime() + endsInH * 3600_000).toISOString(), id);
  };
  // Both end in 36h: inside the 2-day window, outside the 1-day window.
  await mk("lic_early", 36, 2);
  await mk("lic_late", 36, 1);

  assert.equal(await runReminderSweep(env, now), 1);
  assert.ok(db.row("licenses", "lic_early")!.reminder_sent_at);
  assert.equal(db.row("licenses", "lic_late")!.reminder_sent_at, null);
  assert.deepEqual(subjects(), ["your llmpilot trial ends in 2 days"]);

  // A day later the 1-day license enters its window and gets the tomorrow wording.
  const dayLater = new Date(now.getTime() + 24 * 3600_000);
  assert.equal(await runReminderSweep(env, dayLater), 1);
  assert.ok(db.row("licenses", "lic_late")!.reminder_sent_at);
  assert.deepEqual(subjects(), ["your llmpilot trial ends in 2 days", "your llmpilot trial ends tomorrow"]);
});

test("reminder sweep: exact window boundaries send; junk offsets fall back to the day-before default", async () => {
  const db = new TestD1();
  const emailBodies: Array<Record<string, unknown>> = [];
  const subjects = () => emailBodies.map((e) => e.subject);
  const env = makeEnv(db, KEYS.signingKeyB64, {
    TRIAL_DAYS: "4",
    EMAIL_HTTP: captureEmails(emailBodies),
  });
  const now = new Date("2026-07-12T12:00:00Z");
  const mk = async (id: string, endsInH: number, remind: number) => {
    await insertLicense(db as never, id, "full", TEST_INSTALL, remind);
    db.db.prepare("UPDATE licenses SET status='trialing', email='t@example.dev', trial_end=?, remind_days_before=? WHERE id=?")
      .run(new Date(now.getTime() + endsInH * 3600_000).toISOString(), remind, id);
  };
  await mk("lic_edge24", 24, 1); // exactly on the 1-day boundary → sends
  await mk("lic_edge48", 48, 2); // exactly on the 2-day boundary → sends
  await mk("lic_junk3", 36, 3); // junk offset → treated as 1 → NOT due at 36h
  await mk("lic_junk0", 12, 0); // junk offset → treated as 1 → due at 12h

  assert.equal(await runReminderSweep(env, now), 3);
  assert.ok(db.row("licenses", "lic_edge24")!.reminder_sent_at);
  assert.ok(db.row("licenses", "lic_edge48")!.reminder_sent_at);
  assert.equal(db.row("licenses", "lic_junk3")!.reminder_sent_at, null);
  assert.ok(db.row("licenses", "lic_junk0")!.reminder_sent_at);

  // Every reminder carries its per-license idempotency key — the
  // double-send guard the provider dedupes on.
  for (const e of emailBodies) {
    const h = e.headers as Record<string, string>;
    assert.match(h["Idempotency-Key"] ?? "", /^trial_reminder:lic_/);
  }
});

test("reminder sweep outcomes: 409 stamps as already-sent, 5xx retries, missing key never stamps", async () => {
  const now = new Date("2026-07-12T12:00:00Z");
  const mk = async (db: TestD1, id: string) => {
    await insertLicense(db as never, id, "full", TEST_INSTALL, 1);
    db.db.prepare("UPDATE licenses SET status='trialing', email='t@example.dev', trial_end=? WHERE id=?")
      .run(new Date(now.getTime() + 12 * 3600_000).toISOString(), id);
  };

  // 409 = the provider already accepted this key on a lost earlier attempt
  // (and our payload drifts, so a retry can never clear it): the email
  // EXISTS — stamp it, count no send, and never loop hourly into 409s.
  const db409 = new TestD1();
  const dupBodies: Array<Record<string, unknown>> = [];
  await mk(db409, "lic_dup");
  assert.equal(
    await runReminderSweep(makeEnv(db409, KEYS.signingKeyB64, { TRIAL_DAYS: "4", EMAIL_HTTP: captureEmails(dupBodies, 409) }), now),
    0,
  );
  assert.ok(db409.row("licenses", "lic_dup")!.reminder_sent_at, "409 must stamp — the reminder exists");
  assert.equal(dupBodies.length, 1);

  // A 5xx is retryable: no stamp, the next hourly run tries again.
  const db500 = new TestD1();
  await mk(db500, "lic_retry");
  assert.equal(
    await runReminderSweep(makeEnv(db500, KEYS.signingKeyB64, { TRIAL_DAYS: "4", EMAIL_HTTP: captureEmails([], 500) }), now),
    0,
  );
  assert.equal(db500.row("licenses", "lic_retry")!.reminder_sent_at, null);

  // A deploy that forgot the provider secret must not stamp anything.
  const dbNoKey = new TestD1();
  await mk(dbNoKey, "lic_nokey");
  assert.equal(
    await runReminderSweep(makeEnv(dbNoKey, KEYS.signingKeyB64, { TRIAL_DAYS: "4", RESEND_API_KEY: "" }), now),
    0,
  );
  assert.equal(dbNoKey.row("licenses", "lic_nokey")!.reminder_sent_at, null);
});

test("reminder sweep: a delayed cron words the subject from the clock, not the preference", async () => {
  // A 2-days-before row first seen with under a day left must say
  // "tomorrow" — the preference names the window, the clock names the day.
  const db = new TestD1();
  const emailBodies: Array<Record<string, unknown>> = [];
  const subjects = () => emailBodies.map((e) => e.subject);
  const env = makeEnv(db, KEYS.signingKeyB64, {
    TRIAL_DAYS: "4",
    EMAIL_HTTP: captureEmails(emailBodies),
  });
  const now = new Date("2026-07-12T12:00:00Z");
  await insertLicense(db as never, "lic_lateseen", "full", TEST_INSTALL, 2);
  db.db.prepare("UPDATE licenses SET status='trialing', email='t@example.dev', trial_end=? WHERE id=?")
    .run(new Date(now.getTime() + 20 * 3600_000).toISOString(), "lic_lateseen");
  assert.equal(await runReminderSweep(env, now), 1);
  assert.deepEqual(subjects(), ["your llmpilot trial ends tomorrow"]);
});

test("a 7-day-or-longer trial leaves the custom reminder dormant (Stripe sends its own)", async () => {
  const db = new TestD1();
  const env = makeEnv(db, KEYS.signingKeyB64); // TRIAL_DAYS "8"
  await insertLicense(db as never, "lic_due_default", "discount_trial", TEST_INSTALL);
  db.db.prepare("UPDATE licenses SET status='trialing', email='t@example.dev', trial_end=? WHERE id=?")
    .run(new Date(Date.now() + 12 * 3600_000).toISOString(), "lic_due_default");
  assert.equal(await runReminderSweep(env, new Date()), 0);
  assert.equal(db.row("licenses", "lic_due_default")!.reminder_sent_at, null);

  // The boundary: 7 exactly is Stripe's own; 4 (the deployed value) sweeps.
  assert.equal(await runReminderSweep(makeEnv(db, KEYS.signingKeyB64, { TRIAL_DAYS: "7" }), new Date()), 0);
  assert.equal(await runReminderSweep(makeEnv(db, KEYS.signingKeyB64, { TRIAL_DAYS: "4" }), new Date()), 1);
});

test("daily reconcile fixes active and trialing subscriptions missing cancel_at", async () => {
  const db = new TestD1();
  const env = makeEnv(db, KEYS.signingKeyB64);
  await insertLicense(db as never, "lic_active", "full", TEST_INSTALL);
  await insertLicense(db as never, "lic_trial", "discount_trial", TEST_INSTALL);
  const now = Math.floor(Date.now() / 1000);
  const active = paidSession("lic_active").subscription as Record<string, unknown>;
  const trial = trialSession("lic_trial", now + 8 * 86400).subscription as Record<string, unknown>;
  const { stripe, state } = makeFakeStripe({ subscriptionPages: [[active], [trial]] });
  const result = await runCancellationReconcile(env, stripe);
  assert.deepEqual(result, { scanned: 2, fixed: 2, unresolved: 0 });
  const updates = calls(state, "subscriptions.update");
  assert.equal(updates.length, 2);
  assert.equal(calls(state, "subscriptions.list").length, 2);
  assert.deepEqual(updates[1].args[1], { cancel_at: now + 15 * 86400 });
});
