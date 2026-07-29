// The Stripe CLI takes its key mode from the presence of `--live` (absent an
// STRIPE_API_KEY override, which the identity guard catches). These tests
// drive the REAL exported functions — argv builders, argv parser, CLI body,
// identity guard — with injected fakes where a real call would touch Stripe.
// The defects they pin: an argv that silently omitted --live, a guard that
// read livemode off an object that doesn't carry it, `--only launch` (space
// form) selecting ALL rungs, an unknown rung selecting zero and exiting 0,
// HTTP errors exiting 0, and a USD currency option left tax-EXCLUSIVE.

import assert from "node:assert/strict";
import { test } from "node:test";

import { planFromArgv, priceArgs, runCatalog, verifyPriceTerms } from "../scripts/catalog.mjs";
import { assertApprovedStripeIdentity, approvedStripeAccount, stripeArgs, stripeProfile } from "../scripts/stripe-identity.mjs";

const FULL = { rung: "full", name: "llmpilot Pro", gbp: 999, usd: 1299 } as const;

// ---- argv builders ----------------------------------------------------------

test("stripeArgs adds --live only when live mode is requested", () => {
  assert.ok(stripeArgs(["get", "/v1/account"], true).includes("--live"));
  assert.ok(!stripeArgs(["get", "/v1/account"], false).includes("--live"));
  // Default is test mode: a caller that forgets the argument cannot reach live.
  assert.ok(!stripeArgs(["get", "/v1/account"]).includes("--live"));
});

test("stripeArgs scopes every call to the llmpilot profile", () => {
  const args = stripeArgs(["get", "/v1/balance"], true);
  assert.equal(args[0], "-p");
  assert.equal(args[1], stripeProfile);
});

test("priceArgs writes to live mode ONLY with --live", () => {
  assert.ok(priceArgs(FULL, true).includes("--live"));
  assert.ok(!priceArgs(FULL, false).includes("--live"));
  assert.ok(!priceArgs(FULL).includes("--live"));
});

test("priceArgs makes BOTH currencies tax-inclusive", () => {
  // tax_behavior does not propagate into currency_options; unspecified falls
  // back to the account default, which is EXCLUSIVE — a US buyer would pay
  // tax on top of the number they consented to.
  const joined = priceArgs(FULL, true).join(" ");
  assert.ok(joined.includes("tax_behavior=inclusive"));
  assert.ok(joined.includes("currency_options[usd][tax_behavior]=inclusive"));
});

test("priceArgs carries the terms Managed Payments and the ladder require", () => {
  const args = priceArgs(FULL, true);
  const joined = args.join(" ");
  assert.ok(args.includes("post") && args.includes("/v1/prices"));
  assert.ok(joined.includes("product_data[tax_code]=txcd_10202000"));
  assert.ok(joined.includes("recurring[interval]=year"));
  assert.ok(joined.includes("currency=gbp"));
  assert.ok(joined.includes("unit_amount=999"));
  assert.ok(joined.includes("currency_options[usd][unit_amount]=1299"));
  assert.ok(joined.includes("metadata[rung]=full"));
  // Same-day re-runs replay instead of duplicating — and the key carries the
  // mode, so a test replay can never answer a live create.
  const key = args[args.indexOf("-i") + 1];
  assert.ok(key.includes("live"), "idempotency key must carry the mode");
  assert.ok(!priceArgs(FULL, false).join(" ").includes("catalog-live"));
  // currency_options expanded so the response can prove the USD terms.
  assert.ok(args.includes("-e") && args.includes("currency_options"));
  // Buyer-visible name, never the internal rung word.
  assert.ok(joined.includes("product_data[name]=llmpilot Pro"));
  assert.ok(!joined.includes("product_data[name]=llmpilot Pro full"));
});

// ---- argv parsing -----------------------------------------------------------

test("planFromArgv threads --live through and defaults to test", () => {
  assert.equal(planFromArgv(["--only=full", "--live"]).live, true);
  assert.equal(planFromArgv(["--only=full"]).live, false);
});

test("planFromArgv rejects the --only space form instead of selecting ALL rungs", () => {
  // `--only launch --apply --live` used to fall through to the whole catalog.
  assert.throws(() => planFromArgv(["--only", "launch", "--apply", "--live"]), /--only=/);
});

test("planFromArgv rejects an EMPTY --only= instead of selecting ALL rungs", () => {
  // `--only=$RUNG` with the variable unset — same fall-through, worse source.
  assert.throws(() => planFromArgv(["--only=", "--apply", "--live"]), /empty value/);
});

test("planFromArgv rejects duplicate --only= instead of silently taking the first", () => {
  assert.throws(() => planFromArgv(["--only=full", "--only=discount"]), /more than one/);
});

test("planFromArgv rejects an unknown rung instead of matching zero and exiting 0", () => {
  assert.throws(() => planFromArgv(["--only=lunch"]), /unknown rung/);
});

test("planFromArgv rejects unknown arguments", () => {
  assert.throws(() => planFromArgv(["--apply", "--liv"]), /unknown argument/);
});

test("planFromArgv selects one rung with --only and all three without", () => {
  assert.deepEqual(planFromArgv(["--only=discount"]).products.map((p: { rung: string }) => p.rung), ["discount"]);
  assert.deepEqual(planFromArgv([]).products.map((p: { rung: string }) => p.rung), ["full", "discount", "launch"]);
});

// ---- CLI body wiring (fakes; nothing touches Stripe) ------------------------

function fakePriceObj(rung: string, livemode: boolean, gbp = 999, usd = 1299) {
  return {
    object: "price", id: `price_fake_${rung}`, livemode, product: `prod_fake_${rung}`,
    tax_behavior: "inclusive", currency: "gbp", unit_amount: gbp,
    recurring: { interval: "year" },
    currency_options: { usd: { unit_amount: usd, tax_behavior: "inclusive" } },
  };
}

function fakePrice(rung: string, livemode: boolean) {
  return JSON.stringify(fakePriceObj(rung, livemode));
}

test("runCatalog wires the command-line --live into the spawned argv AND the guard", () => {
  // THE regression this file exists for: reintroduce `priceArgs(product)` in
  // the loop, or typo the flag scan, and this fails.
  const spawned: string[][] = [];
  let guardArgs: { live?: boolean } | undefined;
  const code = runCatalog(["--only=full", "--apply", "--live"], {
    spawn: (args: string[]) => { spawned.push(args); return { status: 0, stdout: fakePrice("full", true) }; },
    assertIdentity: (o: { live?: boolean }) => { guardArgs = o; return { account: approvedStripeAccount, livemode: true }; },
    log: () => {}, warn: () => {},
  });
  assert.equal(code, 0);
  assert.equal(guardArgs?.live, true);
  assert.equal(spawned.length, 1);
  assert.ok(spawned[0].includes("--live"));
});

test("runCatalog without --live spawns without the flag and guards test mode", () => {
  const spawned: string[][] = [];
  let guardArgs: { live?: boolean } | undefined;
  const code = runCatalog(["--only=full", "--apply"], {
    spawn: (args: string[]) => { spawned.push(args); return { status: 0, stdout: fakePrice("full", false) }; },
    assertIdentity: (o: { live?: boolean }) => { guardArgs = o; return { account: approvedStripeAccount, livemode: false }; },
    log: () => {}, warn: () => {},
  });
  assert.equal(code, 0);
  assert.equal(guardArgs?.live, false);
  assert.ok(!spawned[0].includes("--live"));
});

test("runCatalog dry run spawns nothing and never calls the guard", () => {
  let out = "";
  const code = runCatalog(["--only=full", "--live"], {
    spawn: () => { throw new Error("must not spawn"); },
    assertIdentity: () => { throw new Error("must not guard a dry run"); },
    log: (s: string) => { out = s; }, warn: () => {},
  });
  assert.equal(code, 0);
  assert.equal(JSON.parse(out).keyMode, "live");
});

test("runCatalog treats a Stripe error body as FAILURE despite exit 0", () => {
  // The CLI exits 0 on HTTP errors; only the response body is trustworthy.
  const code = runCatalog(["--only=full", "--apply"], {
    spawn: () => ({ status: 0, stdout: JSON.stringify({ error: { type: "invalid_request_error" } }) }),
    assertIdentity: () => ({ account: approvedStripeAccount, livemode: false }),
    log: () => {}, warn: () => {},
  });
  assert.equal(code, 1);
});

test("runCatalog stops at the first failed rung instead of minting the rest", () => {
  const spawned: string[][] = [];
  const code = runCatalog(["--apply"], {
    spawn: (args: string[]) => { spawned.push(args); return { status: 0, stdout: "not json" }; },
    assertIdentity: () => ({ account: approvedStripeAccount, livemode: false }),
    log: () => {}, warn: () => {},
  });
  assert.equal(code, 1);
  assert.equal(spawned.length, 1);
});

test("runCatalog refuses a created price whose livemode contradicts the plan", () => {
  const code = runCatalog(["--only=full", "--apply", "--live"], {
    spawn: () => ({ status: 0, stdout: fakePrice("full", false) }),
    assertIdentity: () => ({ account: approvedStripeAccount, livemode: true }),
    log: () => {}, warn: () => {},
  });
  assert.equal(code, 1);
});

test("runCatalog refuses a non-price object even when its livemode matches", () => {
  // Pins the object check itself: an idempotency replay of some other object
  // could carry a matching livemode, so livemode alone must not pass it.
  let warned = "";
  const code = runCatalog(["--only=full", "--apply"], {
    spawn: () => ({ status: 0, stdout: JSON.stringify({ object: "product", id: "prod_x", livemode: false }) }),
    assertIdentity: () => ({ account: approvedStripeAccount, livemode: false }),
    log: () => {}, warn: (s: string) => { warned = s; },
  });
  assert.equal(code, 1);
  assert.match(warned, /did not return a price/);
});

test("runCatalog refuses a price whose money terms are wrong (USD not inclusive)", () => {
  // The P0 property, proven on the RESPONSE: argv saying inclusive is not
  // enough if the created object does not show it.
  const bad = fakePriceObj("full", false);
  bad.currency_options.usd.tax_behavior = "unspecified";
  let warned = "";
  const code = runCatalog(["--only=full", "--apply"], {
    spawn: () => ({ status: 0, stdout: JSON.stringify(bad) }),
    assertIdentity: () => ({ account: approvedStripeAccount, livemode: false }),
    log: () => {}, warn: (s: string) => { warned = s; },
  });
  assert.equal(code, 1);
  assert.match(warned, /WRONG TERMS/);
  assert.match(warned, /currency_options\.usd\.tax_behavior/);
});

test("runCatalog logs the verified identity before minting", () => {
  const lines: string[] = [];
  runCatalog(["--only=full", "--apply"], {
    spawn: () => ({ status: 0, stdout: fakePrice("full", false) }),
    assertIdentity: () => ({ account: approvedStripeAccount, livemode: false }),
    log: (s: string) => { lines.push(s); }, warn: () => {},
  });
  assert.deepEqual(JSON.parse(lines[0]).verified, { account: approvedStripeAccount, livemode: false });
});

test("verifyPriceTerms passes a correct price and names each divergence", () => {
  assert.deepEqual(verifyPriceTerms(fakePriceObj("full", true), FULL), []);
  const wrong = fakePriceObj("full", true, 999, 1399);
  const mismatches = verifyPriceTerms(wrong, FULL);
  assert.equal(mismatches.length, 1);
  assert.match(mismatches[0], /currency_options\.usd\.unit_amount: got 1399, want 1299/);
  // A response missing currency_options entirely (unexpanded) must FAIL, not pass.
  const unexpanded = fakePriceObj("full", true) as { currency_options?: object };
  delete unexpanded.currency_options;
  assert.equal(verifyPriceTerms(unexpanded, FULL).length, 2);
});

// ---- identity guard (fake exec; nothing touches Stripe) ---------------------

function fakeExec(account: object, balance: object) {
  return (args: string[]) => ({
    status: 0,
    stdout: JSON.stringify(args.includes("/v1/account") ? account : balance),
  });
}

test("identity guard refuses the wrong account", () => {
  assert.throws(
    () => assertApprovedStripeIdentity({ live: false, exec: fakeExec({ id: "acct_other" }, { livemode: false }) }),
    /not the approved account/,
  );
});

test("identity guard refuses a mode mismatch in BOTH directions", () => {
  // A live CLI when test was requested (the env-var override scenario) …
  assert.throws(
    () => assertApprovedStripeIdentity({ live: false, exec: fakeExec({ id: approvedStripeAccount }, { livemode: true }) }),
    /LIVE mode but test was requested/,
  );
  // … and a test CLI when live was requested.
  assert.throws(
    () => assertApprovedStripeIdentity({ live: true, exec: fakeExec({ id: approvedStripeAccount }, { livemode: false }) }),
    /test mode but live was requested/,
  );
});

test("identity guard refuses a balance without a livemode flag (the /v1/account defect)", () => {
  // /v1/account carries no livemode field; the old guard read it there and
  // was therefore vacuous. The mode must come from an object that states it.
  assert.throws(
    () => assertApprovedStripeIdentity({ live: false, exec: fakeExec({ id: approvedStripeAccount }, {}) }),
    /no livemode flag/,
  );
});

test("identity guard returns the verified identity on a clean match", () => {
  const id = assertApprovedStripeIdentity({ live: true, exec: fakeExec({ id: approvedStripeAccount }, { livemode: true }) });
  assert.deepEqual(id, { account: approvedStripeAccount, livemode: true });
});

test("identity guard THROWS (never exits) on a CLI that fails to run", () => {
  assert.throws(
    () => assertApprovedStripeIdentity({ live: false, exec: () => ({ status: null, stdout: "", error: new Error("spawn stripe ENOENT") }) }),
    /failed to run/,
  );
});

test("identity guard throws on a non-zero CLI exit", () => {
  assert.throws(
    () => assertApprovedStripeIdentity({ live: false, exec: () => ({ status: 1, stdout: "" }) }),
    /exited 1/,
  );
});

test("identity guard throws on a non-JSON response", () => {
  assert.throws(
    () => assertApprovedStripeIdentity({ live: false, exec: () => ({ status: 0, stdout: "<html>login</html>" }) }),
    /not JSON/,
  );
});
