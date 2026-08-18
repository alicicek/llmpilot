// Server-quote consent: the paywall renders from GET /v1/quote and checkout
// binds the shown terms by echo-compare. These tests prove the quote carries
// the authoritative values, and that no Session or license row can exist for
// terms that drifted from the current derivation.

import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";
// node:url's URL, NOT the global one — `fs.readFile` accepts only the former,
// and under this tsconfig (lib es2022 + @types/node) they are different types.
// Without this the file passes `npm test` and fails `npm run check`.
import { URL } from "node:url";

import { DEFAULT_TRIAL_DAYS } from "../src/lib/terms.ts";

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

test("quote: nonsense TRIAL_DAYS falls back to the default, which is the trial on sale", async () => {
  const env = makeEnv(new TestD1(), KEYS.signingKeyB64, { TRIAL_DAYS: "banana" });
  assert.equal(effectiveTrialDays(env), DEFAULT_TRIAL_DAYS);
  const res = await getQuote(env, "192.0.2.1", makeFakeStripe().stripe);
  assert.equal(res.status, 200);
  assert.equal(res.body.trial_days, 4);
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
    [{ rung: "full", install_id: TEST_INSTALL, quote: { trial_days: 8, currency: "usd", amount_minor: 1299 } }, "usd"],
    [{ rung: "full", install_id: TEST_INSTALL, quote: { trial_days: 8, currency: "gbp", amount_minor: 999 } }, "gbp"],
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
    { rung: "full", quote: { trial_days: 8, currency: "gbp", amount_minor: 899 } }, // old amount
    { rung: "full", quote: { trial_days: 3, currency: "gbp", amount_minor: 999 } }, // old trial length
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
    { rung: "full", quote: { trial_days: 8, currency: "gbp" } }, // amount missing
    { rung: "full", quote: { currency: "gbp", amount_minor: 999 } }, // pre-reshape client shape: the trial the rung now shows is missing
    { rung: "full", quote: { trial_days: 8.5, currency: "gbp", amount_minor: 999 } }, // junk trial value
    { rung: "nocard_trial", quote: { trial_days: 8, currency: "gbp", amount_minor: 599 } }, // nocard shows no amount
    { rung: "discount_trial", quote: { trial_days: "8", currency: "gbp", amount_minor: 599 } }, // wrong type
    { rung: "nocard_trial", quote: { trial_days: 0 } }, // non-positive is structural, not stale
    { rung: "nocard_trial", quote: { trial_days: -8 } },
    { rung: "full", quote: { trial_days: 8, currency: "gbp", amount_minor: 0 } },
    { rung: "full", quote: { trial_days: 8, currency: "gbp", amount_minor: -999 } },
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

// The fallback and the deployed value are the SAME promise — the paywall's
// consent copy and Stripe's trial_period_days both come from
// effectiveTrialDays, so a dropped TRIAL_DAYS must not change what a buyer is
// told or charged. release-local.sh already refuses a release when the LIVE
// worker disagrees with wrangler.jsonc; this is the other half, and the half
// that survives a var lost AFTER release.
test("the fallback trial length equals the one this tree deploys", async () => {
  const raw = await readFile(new URL("../wrangler.jsonc", import.meta.url), "utf8");
  // Strip WHOLE-LINE comments only. The anchor is what makes this safe, not
  // the absence of "//" in the values — wrangler.jsonc's PUBLIC_ORIGIN is
  // "https://llmpilot.dev", and an unanchored /\/\/.*$/ would truncate it to
  // "https:" and throw. Trailing comments ("x": 1, // note) are legal JSONC
  // and are NOT handled, so say that out loud rather than surfacing a raw
  // SyntaxError to whoever added one.
  const stripped = raw.replace(/^\s*\/\/.*$/gm, "");
  let cfg: { vars?: Record<string, unknown> };
  try {
    cfg = JSON.parse(stripped);
  } catch (err) {
    assert.fail(
      `could not parse worker/wrangler.jsonc after stripping whole-line comments: ${
        (err as Error).message
      }. This test only strips comments that start a line — if you added a trailing one, ` +
        `move it to its own line or teach this test to handle it.`,
    );
    return;
  }
  // Number-compare: wrangler accepts "4" and 4, and a strict compare against a
  // string would call the second one drift.
  assert.equal(
    Number(cfg.vars?.TRIAL_DAYS),
    DEFAULT_TRIAL_DAYS,
    "wrangler.jsonc TRIAL_DAYS and DEFAULT_TRIAL_DAYS must be the same number — " +
      "otherwise losing the var silently changes the trial that is promised and charged",
  );
});

test("the fallback keeps the trial-ending reminder sweep switched on", async () => {
  // runReminderSweep returns 0 at >= 7 (Stripe sends its own reminder for long
  // trials). A fallback at or above that would mean a dropped var ALSO stopped
  // the emails warning people before they are charged.
  assert.ok(
    DEFAULT_TRIAL_DAYS < 7,
    `DEFAULT_TRIAL_DAYS is ${DEFAULT_TRIAL_DAYS}; at >= 7 a dropped TRIAL_DAYS silently disables the reminder sweep`,
  );
});
