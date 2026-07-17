// Run: node --test --experimental-strip-types test/hardening.test.ts
//
// The pro-hardening gate: one no-card trial per checkout email, seats under
// the cap with recovery-claim eviction, and per-install token re-signing.

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  TEST_INSTALL,
  TestD1,
  installN,
  makeKeys,
  makeEnv,
  makeFakeStripe,
  testQuote,
  calls,
  paidSession,
  trialSession,
  stripeEvent,
} from "./helpers.ts";
import { insertLicense, newLicenseID } from "../src/lib/licenses.ts";
import { fulfillSession, handleEvent } from "../src/routes/webhook.ts";
import { activateRoute, claimRecoveryRoute, validateRoute } from "../src/routes/api.ts";
import { createCheckout } from "../src/routes/checkout.ts";
import { importVerifyKey, verifyEntitlement, type EntitlementPayload } from "../src/lib/entitlement.ts";

const KEYS = await makeKeys();

async function tokenPayload(token: string): Promise<EntitlementPayload> {
  const key = await importVerifyKey(KEYS.verifyRawB64);
  const p = await verifyEntitlement(new Map([["key_test_1", key]]), token);
  assert.ok(p, "entitlement must verify against the real public key");
  return p!;
}

function seatRows(db: TestD1, lic: string): Array<{ install_id: string; last_seen: string }> {
  return db.db
    .prepare("SELECT install_id, last_seen FROM activations WHERE license_id = ? ORDER BY last_seen")
    .all(lic) as never;
}

async function seedNocardTrial(
  db: TestD1,
  env: ReturnType<typeof makeEnv>,
  email: string,
  install: string,
  session: string,
) {
  const id = newLicenseID();
  await insertLicense(db as never, id, "nocard_trial", install);
  const trialEnd = Math.floor(Date.now() / 1000) + 8 * 86400;
  const { stripe, state } = makeFakeStripe({
    session: trialSession(id, trialEnd, {
      id: session,
      metadata: { license_id: id, rung: "nocard_trial" },
      customer_details: { email },
    }),
  });
  const res = await fulfillSession(env, stripe, session);
  return { id, res, state, stripe };
}

// ---- Proof: a 2nd no-card trial for an email that already used one is refused ----

test("no-card trial: the same checkout email is refused a second one", async () => {
  const db = new TestD1();
  const env = makeEnv(db, KEYS.signingKeyB64);

  const first = await seedNocardTrial(db, env, "A@x.dev", installN(1), "cs_t1");
  assert.equal(first.res.state, "trialing");
  assert.equal(db.row("licenses", first.id)!.status, "trialing");

  // Same email (normalization included) on a fresh Mac: refused at
  // fulfillment, the subscription cancelled outright, no token minted.
  const second = await seedNocardTrial(db, env, "a@x.dev", installN(2), "cs_t2");
  assert.equal(second.res.state, "trial_email_used");
  const row = db.row("licenses", second.id)!;
  assert.equal(row.status, "lapsed");
  assert.equal(row.entitlement, null);
  assert.equal(calls(second.state, "subscriptions.cancel").length, 1);
  assert.equal(seatRows(db, second.id).length, 0, "a refused trial must not occupy a seat");

  // The app's activate poller sees the typed refusal.
  const res = await activateRoute(env, { session_id: "cs_t2", install_id: installN(2) }, second.stripe);
  assert.equal(res.status, 409);
  assert.deepEqual(await res.json(), { error: "trial_email_used" });

  // Replay (the webhook racing activate) stays refused and idempotent.
  const replay = await fulfillSession(env, second.stripe, "cs_t2");
  assert.equal(replay.state, "trial_email_used");

  // The accepted caveat, pinned: +alias farming still passes.
  const alias = await seedNocardTrial(db, env, "a+alias@x.dev", installN(3), "cs_t3");
  assert.equal(alias.res.state, "trialing");

  // Card-present rungs are untouched by the email cap.
  const paidId = newLicenseID();
  await insertLicense(db as never, paidId, "full", installN(4));
  const { stripe } = makeFakeStripe({
    session: paidSession(paidId, { id: "cs_full", customer_details: { email: "a@x.dev" } }),
  });
  const full = await fulfillSession(env, stripe, "cs_full");
  assert.equal(full.state, "minted");
});

test("no-card trial: a checkout that produced no email fails closed", async () => {
  const db = new TestD1();
  const env = makeEnv(db, KEYS.signingKeyB64);
  const id = newLicenseID();
  await insertLicense(db as never, id, "nocard_trial", installN(1));
  const trialEnd = Math.floor(Date.now() / 1000) + 8 * 86400;
  // Stripe returned no email on this session — the cap can't verify it, so it
  // must refuse the trial rather than grant one unchecked.
  const { stripe } = makeFakeStripe({
    session: trialSession(id, trialEnd, {
      id: "cs_noemail",
      metadata: { license_id: id, rung: "nocard_trial" },
      customer_details: { email: null },
    }),
  });
  const res = await fulfillSession(env, stripe, "cs_noemail");
  assert.equal(res.state, "trial_email_used");
  assert.equal(db.row("licenses", id)!.status, "lapsed");
});

test("seat cap: the atomic guard refuses a new install exactly at the cap", async () => {
  const db = new TestD1();
  const env = makeEnv(db, KEYS.signingKeyB64, { SEAT_LIMIT: "2" });
  const lic = newLicenseID();
  await insertLicense(db as never, lic, "full", installN(1));
  const { stripe } = makeFakeStripe({ session: paidSession(lic, { id: "cs_atomic" }) });
  await fulfillSession(env, stripe, "cs_atomic"); // seats install 1

  // Second install seats under the cap; a re-activation of a seated install
  // refreshes rather than double-counting.
  assert.equal((await activateRoute(env, { session_id: "cs_atomic", install_id: installN(2) }, stripe)).status, 200);
  assert.equal((await activateRoute(env, { session_id: "cs_atomic", install_id: installN(2) }, stripe)).status, 200);
  const count = db.db.prepare("SELECT COUNT(*) AS n FROM activations WHERE license_id = ?").get(lic) as { n: number };
  assert.equal(count.n, 2, "a re-activation must not create a second seat");

  // The third distinct install is refused and never inserted.
  const third = await activateRoute(env, { session_id: "cs_atomic", install_id: installN(3) }, stripe);
  assert.equal(third.status, 409);
  const after = db.db.prepare("SELECT COUNT(*) AS n FROM activations WHERE license_id = ?").get(lic) as { n: number };
  assert.equal(after.n, 2, "a refused activation must not occupy a seat");
});

test("trial refusal state: lapsed-from-pending row never mints and counts as consumed", async () => {
  const db = new TestD1();
  const env = makeEnv(db, KEYS.signingKeyB64);
  await seedNocardTrial(db, env, "b@x.dev", installN(1), "cs_b1");
  const refused = await seedNocardTrial(db, env, "b@x.dev", installN(2), "cs_b2");
  assert.equal(refused.res.state, "trial_email_used");
  // A third attempt is still refused even though the second row is lapsed
  // (only rows with rung=nocard_trial count, and the original is enough).
  const third = await seedNocardTrial(db, env, "b@x.dev", installN(3), "cs_b3");
  assert.equal(third.res.state, "trial_email_used");
});

// ---- Proof: the (cap+1)-th device activation is refused with a recover path ----

test("seat cap: session replay seats devices under the cap, refuses the (cap+1)th, recovery evicts the stalest", async () => {
  const db = new TestD1();
  const env = makeEnv(db, KEYS.signingKeyB64, { SEAT_LIMIT: "2" });
  const lic = newLicenseID();
  await insertLicense(db as never, lic, "full", installN(1));
  const { stripe } = makeFakeStripe({ session: paidSession(lic, { id: "cs_seat" }) });
  await fulfillSession(env, stripe, "cs_seat");
  assert.equal(seatRows(db, lic).length, 1, "fulfillment seats the checkout install");

  // Freeze distinct last_seen instants so eviction order is deterministic.
  db.db.prepare("UPDATE activations SET last_seen = '2020-01-01T00:00:01Z' WHERE install_id = ?").run(installN(1));

  // The same session id replayed from a second Mac: seats it under the cap
  // and mints a token bound to THAT install.
  const second = await activateRoute(env, { session_id: "cs_seat", install_id: installN(2) }, stripe);
  assert.equal(second.status, 200);
  const secondBody = (await second.json()) as { entitlement: string };
  assert.equal((await tokenPayload(secondBody.entitlement)).install, installN(2));
  assert.equal(seatRows(db, lic).length, 2);

  // The (cap+1)th device is refused with the typed error the app maps to
  // "seat limit reached — deactivate a Mac or recover by email".
  const third = await activateRoute(env, { session_id: "cs_seat", install_id: installN(3) }, stripe);
  assert.equal(third.status, 409);
  assert.deepEqual(await third.json(), { error: "seat_limit_reached" });
  assert.equal(seatRows(db, lic).length, 2);

  // Email recovery is the escape hatch: the claim always seats the claimer,
  // evicting the seat with the oldest last_seen (install 1).
  const token = "seat-recovery-token";
  const bytes = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(token)));
  const hash = Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
  db.db.prepare("INSERT INTO recovery_requests VALUES (?, ?, ?, ?, NULL, ?)")
    .run(hash, "emailhash", lic, new Date(Date.now() + 60_000).toISOString(), new Date().toISOString());
  const claim = await claimRecoveryRoute(env, { token, install_id: installN(3) });
  assert.equal(claim.status, 200);
  const claimBody = (await claim.json()) as { entitlement: string };
  assert.equal((await tokenPayload(claimBody.entitlement)).install, installN(3));
  const seats = seatRows(db, lic).map((r) => r.install_id).sort();
  assert.deepEqual(seats, [installN(2), installN(3)].sort());

  // The evicted Mac's validates now refuse: its stored token ages out within
  // one grace window and cannot silently re-seat itself.
  const evicted = await validateRoute(env, { license: lic, install_id: installN(1) });
  assert.equal(evicted.status, 403);
  assert.deepEqual(await evicted.json(), { error: "install_not_activated" });
  assert.equal(seatRows(db, lic).length, 2);
});

test("conversion never revives an evicted checkout install or exceeds the cap", async () => {
  const db = new TestD1();
  const env = makeEnv(db, KEYS.signingKeyB64, { SEAT_LIMIT: "2" });
  const lic = newLicenseID();
  await insertLicense(db as never, lic, "discount_trial", installN(1));
  const trialEnd = Math.floor(Date.now() / 1000) + 8 * 86400;
  const { stripe } = makeFakeStripe({
    session: trialSession(lic, trialEnd, { id: "cs_conv", metadata: { license_id: lic, rung: "discount_trial" } }),
  });
  await fulfillSession(env, stripe, "cs_conv"); // trialing, seats install 1
  // Make install 1 the stalest so recovery evicts it at the cap.
  db.db.prepare("UPDATE activations SET last_seen = '2020-01-01T00:00:00Z' WHERE install_id = ?").run(installN(1));

  const recoverOnto = async (installStr: string, tok: string) => {
    const bytes = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(tok)));
    const hash = Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
    db.db.prepare("INSERT INTO recovery_requests VALUES (?, ?, ?, ?, NULL, ?)")
      .run(hash, "eh", lic, new Date(Date.now() + 60_000).toISOString(), new Date().toISOString());
    return claimRecoveryRoute(env, { token: tok, install_id: installStr });
  };
  await recoverOnto(installN(2), "tok2");
  await recoverOnto(installN(3), "tok3"); // at cap 2, install 1 is evicted
  assert.deepEqual(seatRows(db, lic).map((r) => r.install_id).sort(), [installN(2), installN(3)].sort());

  // The trial converts on the paid cycle invoice. Before the fix this
  // unconditionally re-seated install 1 → cap+1 and a revived evicted Mac.
  const invoice = {
    id: "in_cycle_599",
    object: "invoice",
    amount_paid: 599,
    currency: "gbp",
    billing_reason: "subscription_cycle",
    parent: { subscription_details: { metadata: { license_id: lic }, subscription: "sub_2" } },
  };
  assert.equal(await handleEvent(env, stripe, stripeEvent("invoice.paid", invoice)), "ok");
  assert.equal(db.row("licenses", lic)!.status, "lifetime");
  const seats = seatRows(db, lic).map((r) => r.install_id).sort();
  assert.equal(seats.length, 2, "conversion must not exceed the seat cap");
  assert.ok(!seats.includes(installN(1)), "conversion must not revive the evicted checkout install");
  // The revived install must not be able to validate.
  const revived = await validateRoute(env, { license: lic, install_id: installN(1) });
  assert.equal(revived.status, 403);
});

// ---- validate re-signs per install with fresh issued_at --------------------------

test("validate: re-signs a fresh token for the calling seat with advancing issued_at", async () => {
  const db = new TestD1();
  const env = makeEnv(db, KEYS.signingKeyB64);
  const lic = newLicenseID();
  await insertLicense(db as never, lic, "full", TEST_INSTALL);
  const { stripe } = makeFakeStripe({ session: paidSession(lic, { id: "cs_v" }) });
  await fulfillSession(env, stripe, "cs_v");
  const minted = (db.row("licenses", lic) as { entitlement: string }).entitlement;
  const mintedIssued = (await tokenPayload(minted)).issued_at;

  await new Promise((r) => setTimeout(r, 5));
  const res = await validateRoute(env, { license: lic, install_id: TEST_INSTALL });
  assert.equal(res.status, 200);
  const body = (await res.json()) as { entitlement: string };
  assert.notEqual(body.entitlement, minted, "validate must re-sign, not re-serve");
  const p = await tokenPayload(body.entitlement);
  assert.equal(p.install, TEST_INSTALL);
  assert.ok(new Date(p.issued_at).getTime() > new Date(mintedIssued).getTime(), "issued_at must advance");

  // Trial rows re-sign with the same signed expiry (trial_end + grace).
  const trialLic = newLicenseID();
  await insertLicense(db as never, trialLic, "discount_trial", TEST_INSTALL);
  const trialEnd = Math.floor(Date.now() / 1000) + 8 * 86400;
  const fake = makeFakeStripe({ session: trialSession(trialLic, trialEnd, { id: "cs_vt" }) });
  await fulfillSession(env, fake.stripe, "cs_vt");
  const tres = await validateRoute(env, { license: trialLic, install_id: TEST_INSTALL });
  const tbody = (await tres.json()) as { entitlement: string };
  const tp = await tokenPayload(tbody.entitlement);
  assert.equal(tp.kind, "TRIAL");
  assert.equal(new Date(tp.expires_at!).getTime(), trialEnd * 1000 + 72 * 3600_000);

  // A missing or malformed install id never reaches the seat table.
  const bad = await validateRoute(env, { license: lic });
  assert.equal(bad.status, 400);
});

// ---- checkout requires the binding --------------------------------------------

test("checkout: a missing or malformed install id is refused before any row exists", async () => {
  const db = new TestD1();
  const env = makeEnv(db, KEYS.signingKeyB64);
  const fake = makeFakeStripe();
  const missing = await createCheckout(env, { rung: "full" }, "192.0.2.9", fake.stripe);
  assert.equal(missing.status, 400);
  const malformed = await createCheckout(env, { rung: "full", install_id: "not-a-uuid" }, "192.0.2.9", fake.stripe);
  assert.equal(malformed.status, 400);
  const count = db.db.prepare("SELECT COUNT(*) AS n FROM licenses").get() as { n: number };
  assert.equal(count.n, 0);
  assert.equal(calls(fake.state, "sessions.create").length, 0);
});

test("checkout: the embedded checkout URL uses the worker origin, not the site", async () => {
  const db = new TestD1();
  const env = makeEnv(db, KEYS.signingKeyB64);
  // A Stripe whose session carries a client_secret exercises the embedded
  // branch; the /checkout host page is a WORKER route, so its URL must be the
  // worker origin passed in — never PUBLIC_ORIGIN (the llmpilot.dev site).
  const stripe = {
    prices: { retrieve: async () => ({ type: "recurring", recurring: { interval: "year" }, currency: "gbp", unit_amount: 999 }) },
    checkout: { sessions: { create: async () => ({ id: "cs_test_embed", url: null, client_secret: "cs_test_embed_secret" }) } },
  } as never;
  const res = await createCheckout(env, { rung: "full", install_id: TEST_INSTALL, quote: testQuote("full") }, "192.0.2.50", stripe, "https://api.example.dev");
  assert.equal(res.status, 200);
  assert.match(res.body.checkoutUrl as string, /^https:\/\/api\.example\.dev\/checkout\?session_id=/);
  assert.doesNotMatch(res.body.checkoutUrl as string, /llmpilot\.dev\/checkout/);
});

// ---- lifetime conversion keeps the original seat set ----------------------------

test("trial conversion re-mints for the checkout install and keeps existing seats", async () => {
  const db = new TestD1();
  const env = makeEnv(db, KEYS.signingKeyB64);
  const first = await seedNocardTrial(db, env, "c@x.dev", installN(1), "cs_c1");
  assert.equal(first.res.state, "trialing");
  const invoice = {
    id: "in_cycle_599",
    object: "invoice",
    amount_paid: 599,
    currency: "gbp",
    billing_reason: "subscription_cycle",
    parent: { subscription_details: { metadata: { license_id: first.id }, subscription: "sub_2" } },
  };
  const out = await handleEvent(env, first.stripe, stripeEvent("invoice.paid", invoice));
  assert.equal(out, "ok");
  const row = db.row("licenses", first.id)!;
  assert.equal(row.status, "lifetime");
  const p = await tokenPayload(row.entitlement as string);
  assert.equal(p.kind, "LIFETIME");
  assert.equal(p.install, installN(1));
  assert.equal(seatRows(db, first.id).length, 1);
});
