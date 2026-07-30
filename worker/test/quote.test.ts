// Server-quote consent: the paywall renders from GET /v1/quote and checkout
// binds the shown terms by echo-compare. These tests prove the quote carries
// the authoritative values, and that no Session or license row can exist for
// terms that drifted from the current derivation.

import assert from "node:assert/strict";
import { test } from "node:test";

import {
  TEST_INSTALL,
  TestD1,
  makeKeys,
  makeEnv,
  makeFakeStripe,
  testQuote,
  calls,
} from "./helpers.ts";
import { getQuote } from "../src/routes/quote.ts";
import { createCheckout } from "../src/routes/checkout.ts";
import { effectiveTrialDays } from "../src/lib/terms.ts";

const KEYS = await makeKeys();

function licenseCount(db: TestD1): number {
  return (db.db.prepare("SELECT COUNT(*) AS n FROM licenses").get() as { n: number }).n;
}

test("quote: serves env trial days, charge date, and both currencies per price", async () => {
  const env = makeEnv(new TestD1(), KEYS.signingKeyB64, { TRIAL_DAYS: "5" });
  const fake = makeFakeStripe();
  const res = await getQuote(env, "192.0.2.1", fake.stripe);
  assert.equal(res.status, 200);
  assert.equal(res.body.trial_days, 5);
  assert.ok(typeof res.body.charge_date === "string" && !Number.isNaN(Date.parse(res.body.charge_date)));
  assert.deepEqual(res.body.prices, {
    full: { gbp: 999, usd: 1299 },
    discount: { gbp: 599, usd: 799 },
  });
  // The derivation must expand currency_options — a bare retrieve hides usd.
  const retrieves = calls(fake.state, "prices.retrieve");
  assert.equal(retrieves.length, 2);
  for (const r of retrieves) {
    assert.deepEqual(r.args[1], { expand: ["currency_options"] });
  }
});

test("quote: nonsense TRIAL_DAYS falls back to the default", async () => {
  const env = makeEnv(new TestD1(), KEYS.signingKeyB64, { TRIAL_DAYS: "banana" });
  assert.equal(effectiveTrialDays(env), 8);
  const res = await getQuote(env, "192.0.2.1", makeFakeStripe().stripe);
  assert.equal(res.status, 200);
  assert.equal(res.body.trial_days, 8);
});

test("quote: per-IP rate limit answers 429 past the bucket", async () => {
  const db = new TestD1();
  const env = makeEnv(db, KEYS.signingKeyB64);
  const fake = makeFakeStripe();
  for (let i = 0; i < 60; i++) {
    assert.equal((await getQuote(env, "192.0.2.7", fake.stripe)).status, 200);
  }
  assert.equal((await getQuote(env, "192.0.2.7", fake.stripe)).status, 429);
});

test("checkout: a matching echo creates the Session with the echoed trial length", async () => {
  const db = new TestD1();
  const env = makeEnv(db, KEYS.signingKeyB64);
  const fake = makeFakeStripe();
  const res = await createCheckout(
    env,
    { rung: "discount_trial", install_id: TEST_INSTALL, quote: testQuote("discount_trial") },
    "192.0.2.20",
    fake.stripe,
  );
  assert.equal(res.status, 200);
  const created = calls(fake.state, "sessions.create");
  assert.equal(created.length, 1);
  const params = created[0].args[0] as { subscription_data: { trial_period_days: number } };
  assert.equal(params.subscription_data.trial_period_days, 8);
});

test("checkout: the Session is pinned to the CONSENTED currency", async () => {
  // Without the pin, Checkout may localize to the Price's other currency
  // option and present an amount the buyer never consented to — the same
  // divergence class as the tax-behavior defect. A US echo must produce a
  // usd Session, a GBP echo a gbp Session, and the no-card rung (no amount
  // shown, no currency echoed) must stay unpinned for Stripe to localize.
  const env = makeEnv(new TestD1(), KEYS.signingKeyB64);
  const fake = makeFakeStripe();
  const cases: Array<[Record<string, unknown>, string | undefined]> = [
    [{ rung: "full", install_id: TEST_INSTALL, quote: { currency: "usd", amount_minor: 1299 } }, "usd"],
    [{ rung: "full", install_id: TEST_INSTALL, quote: { currency: "gbp", amount_minor: 999 } }, "gbp"],
    [{ rung: "nocard_trial", install_id: TEST_INSTALL, quote: { trial_days: 8 } }, undefined],
  ];
  for (const [body, want] of cases) {
    const res = await createCheckout(env, body, "192.0.2.30", fake.stripe);
    assert.equal(res.status, 200, JSON.stringify(res.body));
  }
  const created = calls(fake.state, "sessions.create");
  assert.equal(created.length, cases.length);
  created.forEach((c, i) => {
    assert.equal((c.args[0] as { currency?: string }).currency, cases[i][1]);
  });
});

test("checkout: full and nocard rungs accept their own echo shapes", async () => {
  const env = makeEnv(new TestD1(), KEYS.signingKeyB64);
  const fake = makeFakeStripe();
  for (const rung of ["full", "nocard_trial"] as const) {
    const res = await createCheckout(
      env,
      { rung, install_id: TEST_INSTALL, quote: testQuote(rung) },
      "192.0.2.21",
      fake.stripe,
    );
    assert.equal(res.status, 200, `${rung}: ${JSON.stringify(res.body)}`);
  }
});

test("checkout: drifted echo values are quote_stale and create nothing", async () => {
  const db = new TestD1();
  const env = makeEnv(db, KEYS.signingKeyB64);
  const fake = makeFakeStripe();
  const stale = [
    { rung: "discount_trial", quote: { trial_days: 3, currency: "gbp", amount_minor: 599 } }, // old trial length
    { rung: "discount_trial", quote: { trial_days: 8, currency: "gbp", amount_minor: 499 } }, // old amount
    { rung: "discount_trial", quote: { trial_days: 8, currency: "eur", amount_minor: 599 } }, // currency the price lacks
    { rung: "full", quote: { currency: "gbp", amount_minor: 899 } },
    { rung: "nocard_trial", quote: { trial_days: 7 } },
  ];
  for (const c of stale) {
    const res = await createCheckout(env, { rung: c.rung, install_id: TEST_INSTALL, quote: c.quote }, "192.0.2.22", fake.stripe);
    assert.equal(res.status, 409, `${c.rung} ${JSON.stringify(c.quote)}`);
    assert.equal(res.body.error, "quote_stale");
  }
  assert.equal(calls(fake.state, "sessions.create").length, 0);
  assert.equal(licenseCount(db), 0);
});

test("checkout: a missing or malformed echo is invalid_input and creates nothing", async () => {
  const db = new TestD1();
  const env = makeEnv(db, KEYS.signingKeyB64);
  const fake = makeFakeStripe();
  const bad: { rung: string; quote?: unknown }[] = [
    { rung: "full" }, // no echo at all
    { rung: "full", quote: "gbp999" },
    { rung: "full", quote: { currency: "gbp" } }, // amount missing
    { rung: "full", quote: { trial_days: 8, currency: "gbp", amount_minor: 999 } }, // full shows no trial
    { rung: "full", quote: { trial_days: 8.5, currency: "gbp", amount_minor: 999 } }, // junk trial value on full
    { rung: "nocard_trial", quote: { trial_days: 8, currency: "gbp", amount_minor: 599 } }, // nocard shows no amount
    { rung: "discount_trial", quote: { trial_days: "8", currency: "gbp", amount_minor: 599 } }, // wrong type
    { rung: "nocard_trial", quote: { trial_days: 0 } }, // non-positive is structural, not stale
    { rung: "nocard_trial", quote: { trial_days: -8 } },
    { rung: "full", quote: { currency: "gbp", amount_minor: 0 } },
    { rung: "full", quote: { currency: "gbp", amount_minor: -999 } },
  ];
  for (const c of bad) {
    const res = await createCheckout(env, { ...c, install_id: TEST_INSTALL }, "192.0.2.23", fake.stripe);
    assert.equal(res.status, 400, `${c.rung} ${JSON.stringify(c.quote)}`);
    assert.equal(res.body.error, "invalid_input");
  }
  assert.equal(calls(fake.state, "sessions.create").length, 0);
  assert.equal(licenseCount(db), 0);
});

test("checkout: a changed deployment invalidates an open paywall's echo", async () => {
  // The drift class this kills: the worker's trial flips 8 → 3 while a buyer
  // has the old terms on screen. Their consent echo must refuse to bind.
  const db = new TestD1();
  const envBefore = makeEnv(db, KEYS.signingKeyB64, { TRIAL_DAYS: "8" });
  const fake = makeFakeStripe();
  const shown = await getQuote(envBefore, "192.0.2.24", fake.stripe);
  assert.equal(shown.status, 200);

  const envAfter = makeEnv(db, KEYS.signingKeyB64, { TRIAL_DAYS: "3" });
  const res = await createCheckout(
    envAfter,
    {
      rung: "discount_trial",
      install_id: TEST_INSTALL,
      quote: { trial_days: shown.body.trial_days, currency: "gbp", amount_minor: 599 },
    },
    "192.0.2.24",
    fake.stripe,
  );
  assert.equal(res.status, 409);
  assert.equal(res.body.error, "quote_stale");
  assert.equal(calls(fake.state, "sessions.create").length, 0);
});
