// Launch-price window: for 14 real days the full rung sells at PRICE_LAUNCH;
// at LAUNCH_ENDS_AT it reverts to PRICE_FULL. The window is config + clock —
// no cron, no state — so these tests drive the boundary with an injected now.

import assert from "node:assert/strict";
import { test } from "node:test";

import {
  TEST_INSTALL,
  TestD1,
  makeKeys,
  makeEnv,
  makeFakeStripe,
  calls,
} from "./helpers.ts";
import { getQuote } from "../src/routes/quote.ts";
import { createCheckout } from "../src/routes/checkout.ts";
import { launchActive, resolvePriceID } from "../src/lib/terms.ts";
import worker from "../src/index.ts";

const KEYS = await makeKeys();

const ENDS = "2026-08-04T07:00:00Z";
const DURING = new Date("2026-07-28T12:00:00Z");
const AFTER = new Date("2026-08-04T07:00:01Z");
const LAUNCH_ENV = { PRICE_LAUNCH: "price_launch_test", LAUNCH_ENDS_AT: ENDS };

function launchEnv(db: TestD1) {
  return makeEnv(db, KEYS.signingKeyB64, LAUNCH_ENV);
}

test("resolve: full rung uses the launch price only inside the window", () => {
  const env = launchEnv(new TestD1());
  assert.equal(resolvePriceID(env, "full", DURING), "price_launch_test");
  assert.equal(resolvePriceID(env, "full", AFTER), "price_full_test");
  // The boundary instant itself is over — [open, ends_at).
  assert.equal(resolvePriceID(env, "full", new Date(ENDS)), "price_full_test");
  // The ladder's discount rung never changes.
  assert.equal(resolvePriceID(env, "discount_trial", DURING), "price_discount_test");
});

test("resolve: a half-configured or malformed window is no window", () => {
  const db = new TestD1();
  const cases = [
    { PRICE_LAUNCH: "price_launch_test" }, // no end date
    { LAUNCH_ENDS_AT: ENDS }, // no launch price
    { PRICE_LAUNCH: "price_launch_test", LAUNCH_ENDS_AT: "not-a-date" },
  ];
  for (const over of cases) {
    const env = makeEnv(db, KEYS.signingKeyB64, over);
    assert.equal(launchActive(env, DURING), false, JSON.stringify(over));
    assert.equal(resolvePriceID(env, "full", DURING), "price_full_test");
  }
});

test("quote: during the window full carries launch amounts plus the honest extras", async () => {
  const env = launchEnv(new TestD1());
  const fake = makeFakeStripe();
  const res = await getQuote(env, "192.0.2.30", fake.stripe, DURING);
  assert.equal(res.status, 200);
  assert.deepEqual(res.body.prices, {
    full: { gbp: 599, usd: 799 },
    discount: { gbp: 599, usd: 799 },
  });
  assert.deepEqual(res.body.launch, {
    ends_at: new Date(ENDS).toISOString(),
    regular_full: { gbp: 999, usd: 1299 },
  });
});

test("quote: after the window the launch block is gone and full is regular", async () => {
  const env = launchEnv(new TestD1());
  const res = await getQuote(env, "192.0.2.31", makeFakeStripe().stripe, AFTER);
  assert.equal(res.status, 200);
  assert.deepEqual(res.body.prices, {
    full: { gbp: 999, usd: 1299 },
    discount: { gbp: 599, usd: 799 },
  });
  assert.equal(res.body.launch, undefined);
});

test("checkout: during the window a launch-amount echo binds and the Session sells PRICE_LAUNCH", async () => {
  const db = new TestD1();
  const env = launchEnv(db);
  const fake = makeFakeStripe();
  const res = await createCheckout(
    env,
    { rung: "full", install_id: TEST_INSTALL, quote: { trial_days: 8, currency: "gbp", amount_minor: 599 } },
    "192.0.2.32",
    fake.stripe,
    undefined,
    DURING,
  );
  assert.equal(res.status, 200, JSON.stringify(res.body));
  const created = calls(fake.state, "sessions.create");
  assert.equal(created.length, 1);
  const params = created[0].args[0] as { line_items: Array<{ price: string }> };
  assert.equal(params.line_items[0].price, "price_launch_test");
});

test("checkout: during the window a regular-amount echo is quote_stale", async () => {
  const env = launchEnv(new TestD1());
  const fake = makeFakeStripe();
  const res = await createCheckout(
    env,
    { rung: "full", install_id: TEST_INSTALL, quote: { trial_days: 8, currency: "gbp", amount_minor: 999 } },
    "192.0.2.33",
    fake.stripe,
    undefined,
    DURING,
  );
  assert.equal(res.status, 409);
  assert.equal(res.body.error, "quote_stale");
  assert.equal(calls(fake.state, "sessions.create").length, 0);
});

test("checkout: past the boundary an open paywall's launch echo refuses to bind", async () => {
  // The drift this kills: the window ends while a buyer has £5.99 on screen.
  const env = launchEnv(new TestD1());
  const fake = makeFakeStripe();
  const stale = await createCheckout(
    env,
    { rung: "full", install_id: TEST_INSTALL, quote: { trial_days: 8, currency: "gbp", amount_minor: 599 } },
    "192.0.2.34",
    fake.stripe,
    undefined,
    AFTER,
  );
  assert.equal(stale.status, 409);
  assert.equal(stale.body.error, "quote_stale");
  const fresh = await createCheckout(
    env,
    { rung: "full", install_id: TEST_INSTALL, quote: { trial_days: 8, currency: "gbp", amount_minor: 999 } },
    "192.0.2.34",
    fake.stripe,
    undefined,
    AFTER,
  );
  assert.equal(fresh.status, 200, JSON.stringify(fresh.body));
  const created = calls(fake.state, "sessions.create");
  assert.equal(created.length, 1);
  const params = created[0].args[0] as { line_items: Array<{ price: string }> };
  assert.equal(params.line_items[0].price, "price_full_test");
});

test("quote route: CORS opens for exactly the site origins", async () => {
  // Through the real router; the fake key can't reach Stripe so the body is
  // an error — the CORS decision must not depend on the body succeeding.
  const env = makeEnv(new TestD1(), KEYS.signingKeyB64);
  const ctx = { waitUntil() {}, passThroughOnException() {} } as unknown as ExecutionContext;
  const site = await worker.fetch(
    new Request("https://api.llmpilot.dev/v1/quote", { headers: { origin: "https://llmpilot.dev" } }),
    env,
    ctx,
  );
  assert.equal(site.headers.get("access-control-allow-origin"), "https://llmpilot.dev");
  assert.equal(site.headers.get("vary"), "origin");
  const foreign = await worker.fetch(
    new Request("https://api.llmpilot.dev/v1/quote", { headers: { origin: "https://evil.example" } }),
    env,
    ctx,
  );
  assert.equal(foreign.headers.get("access-control-allow-origin"), null);
});
