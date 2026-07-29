#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import { realpathSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { assertApprovedStripeIdentity, approvedStripeAccount, stripeArgs, stripeProfile } from "./stripe-identity.mjs";

// `name` is BUYER-VISIBLE: under Managed Payments the Product name appears on
// the checkout line item and the receipt. It must match the names the test
// catalog validated — never the internal rung word.
const catalog = [
  { rung: "full", name: "llmpilot Pro", gbp: 999, usd: 1299 },
  { rung: "discount", name: "llmpilot Pro (introductory)", gbp: 599, usd: 799 },
  // The 14-day launch sale: the full rung's own Price at the launch amounts.
  // NOT part of any default run — see OPERATIONS.md §Launch-price window.
  { rung: "launch", name: "llmpilot Pro launch", gbp: 599, usd: 799 },
];

/** Stripe CLI argv that creates one rung's Price in the requested key mode.
 *  Raw POST: `stripe prices create` rejects nested flags like
 *  --recurring[interval]; the generic form accepts the full param shape. */
export function priceArgs(product, live = false) {
  return stripeArgs([
    "post", "/v1/prices",
    // Same-day re-runs replay instead of duplicating (Stripe keys live ~24h).
    // The mode is part of the key so a test replay can never answer a live
    // create even if the idempotency namespace were shared across modes.
    "-i", `llmpilot-catalog-${live ? "live" : "test"}-${product.rung}-${product.gbp}-${product.usd}`,
    // Expanded so verifyPriceTerms can PROVE the money terms on the object
    // Stripe actually created — a Price response omits currency_options
    // unless asked.
    "-e", "currency_options",
    // Inclusive: the buyer pays exactly the advertised number; VAT comes
    // out of it (owner decision 2026-07-12 — exclusive rendered £9.99+£2.00).
    "-d", "tax_behavior=inclusive",
    "-d", "currency=gbp", "-d", `unit_amount=${product.gbp}`,
    "-d", "recurring[interval]=year",
    "-d", `product_data[name]=${product.name}`,
    // Managed Payments refuses line items whose product lacks an eligible
    // tax code (verified live 2026-07-12: sessions 400 without it).
    "-d", "product_data[tax_code]=txcd_10202000",
    "-d", `currency_options[usd][unit_amount]=${product.usd}`,
    // tax_behavior does NOT propagate into currency_options: each option
    // carries its own, and an unspecified one falls back to the account's
    // /v1/tax/settings default — which is EXCLUSIVE here, so a US buyer
    // would be charged tax on top of the advertised number (adversarial
    // review 2026-07-29; the shipped test catalog had this and was repaired).
    "-d", "currency_options[usd][tax_behavior]=inclusive",
    "-d", `metadata[rung]=${product.rung}`,
  ], live);
}

/** Compare the Price Stripe RETURNED against the terms the rung sells.
 *  Returns human-readable mismatches; empty means proven. Exported for tests. */
export function verifyPriceTerms(price, product) {
  const usd = price.currency_options?.usd;
  const checks = [
    ["tax_behavior", price.tax_behavior, "inclusive"],
    ["currency", price.currency, "gbp"],
    ["unit_amount", price.unit_amount, product.gbp],
    ["recurring.interval", price.recurring?.interval, "year"],
    ["currency_options.usd.unit_amount", usd?.unit_amount, product.usd],
    ["currency_options.usd.tax_behavior", usd?.tax_behavior, "inclusive"],
  ];
  return checks
    .filter(([, got, want]) => got !== want)
    .map(([name, got, want]) => `${name}: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`);
}

/** Parse argv into a validated plan, or throw. Exported for tests.
 *  Strict on --only: the space form (`--only launch`) used to fall through
 *  to ALL THREE rungs, and an unknown rung selected zero and exited 0. */
export function planFromArgv(argv) {
  for (const a of argv) {
    if (a === "--only" || a === "--only=") {
      // `--only launch` fell through to ALL rungs, and so would an empty
      // value from an unset shell variable (`--only=$RUNG`).
      throw new Error("use --only=<rung>, not --only <rung> or an empty value");
    }
    if (!["--apply", "--live"].includes(a) && !a.startsWith("--only=")) {
      throw new Error(`unknown argument: ${a}`);
    }
  }
  const onlyArgs = argv.filter((a) => a.startsWith("--only="));
  if (onlyArgs.length > 1) throw new Error("more than one --only=");
  const only = onlyArgs[0]?.slice(7);
  const products = only !== undefined ? catalog.filter((p) => p.rung === only) : catalog;
  if (only !== undefined && products.length === 0) {
    throw new Error(`unknown rung "${only}" — valid: ${catalog.map((p) => p.rung).join(", ")}`);
  }
  return { live: argv.includes("--live"), apply: argv.includes("--apply"), products };
}

function defaultSpawn(args) {
  // stdout is CAPTURED, not inherited: the CLI exits 0 on HTTP errors
  // (verified: a 404 GET exits 0 with the error JSON on stdout), so the only
  // trustworthy success signal is the response body itself.
  return spawnSync("stripe", args, { encoding: "utf8", stdio: ["ignore", "pipe", "inherit"] });
}

/** The CLI body. Deps are injectable for tests only. Returns the exit code. */
export function runCatalog(argv, deps = {}) {
  const { spawn = defaultSpawn, assertIdentity = assertApprovedStripeIdentity, log = console.log, warn = console.error } = deps;
  const plan = planFromArgv(argv);
  if (process.env.STRIPE_API_KEY) {
    warn("WARNING: STRIPE_API_KEY is set and overrides the profile AND --live; the identity guard will verify the observed mode.");
  }
  if (!plan.apply) {
    log(JSON.stringify({ mode: "dry-run", keyMode: plan.live ? "live" : "test", profile: stripeProfile, expectedAccount: approvedStripeAccount, recurringInterval: "year", products: plan.products }));
    return 0;
  }
  const identity = assertIdentity({ live: plan.live });
  // The cutover's evidence line: which account and mode were verified in the
  // seconds before the mint.
  log(JSON.stringify({ verified: identity }));
  for (const product of plan.products) {
    const result = spawn(priceArgs(product, plan.live));
    if (result.error || result.status !== 0) {
      warn(`stripe post failed for rung ${product.rung}: ${result.error?.message ?? `exit ${result.status}`}`);
      return 1;
    }
    let price;
    try {
      price = JSON.parse(result.stdout);
    } catch {
      warn(`rung ${product.rung}: response was not JSON`);
      return 1;
    }
    if (price.object !== "price" || typeof price.id !== "string") {
      // The error JSON Stripe returned — surfaced, never mistaken for success.
      warn(`rung ${product.rung}: Stripe did not return a price:\n${result.stdout.trim()}`);
      return 1;
    }
    if (price.livemode !== plan.live) {
      warn(`rung ${product.rung}: created ${price.id} with livemode=${price.livemode}, expected ${plan.live} — INVESTIGATE`);
      return 1;
    }
    // Prove the money terms on the object Stripe created, not on our argv:
    // the P0 property (USD inclusive) is only real if the response shows it.
    const mismatches = verifyPriceTerms(price, product);
    if (mismatches.length > 0) {
      warn(`rung ${product.rung}: created ${price.id} with WRONG TERMS — deactivate it before retrying:\n  ${mismatches.join("\n  ")}`);
      return 1;
    }
    log(JSON.stringify({ rung: product.rung, id: price.id, livemode: price.livemode, product: price.product, terms: "verified" }));
  }
  return 0;
}

// Only run the CLI when invoked as a script — importing this module (the tests
// drive the exported functions directly) must not create anything. realpath
// both sides: through a symlink import.meta.url is the real path while argv[1]
// is not, and a mismatched guard would make --apply a silent exit-0 no-op.
if (process.argv[1] && import.meta.url === pathToFileURL(realpathSync(process.argv[1])).href) {
  let code;
  try {
    code = runCatalog(process.argv.slice(2));
  } catch (err) {
    console.error(err instanceof Error ? err.message : String(err));
    code = 1;
  }
  process.exit(code);
}
