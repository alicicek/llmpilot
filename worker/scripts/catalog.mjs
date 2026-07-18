#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import { assertApprovedStripeIdentity, approvedStripeAccount, stripeProfile } from "./stripe-identity.mjs";

const catalog = [
  { rung: "full", gbp: 999, usd: 1299 },
  { rung: "discount", gbp: 599, usd: 799 },
  // The 14-day launch sale: the full rung's own Price at the launch amounts.
  { rung: "launch", gbp: 599, usd: 799 },
];
// --only=<rung> creates one Price without duplicating the others (the base
// catalog was applied 2026-07-12; a bare --apply would mint them again).
const only = process.argv.find((a) => a.startsWith("--only="))?.slice(7);
const products = only ? catalog.filter((p) => p.rung === only) : catalog;
if (!process.argv.includes("--apply")) {
  console.log(JSON.stringify({ mode: "dry-run", profile: stripeProfile, expectedAccount: approvedStripeAccount, recurringInterval: "year", products }));
  process.exit(0);
}
assertApprovedStripeIdentity();
for (const product of products) {
  // Raw POST: `stripe prices create` rejects nested flags like
  // --recurring[interval]; the generic form accepts the full param shape.
  const args = [
    "-p", stripeProfile, "post", "/v1/prices",
    // Inclusive: the buyer pays exactly the advertised number; VAT comes
    // out of it (owner decision 2026-07-12 — exclusive rendered £9.99+£2.00).
    "-d", "tax_behavior=inclusive",
    "-d", "currency=gbp", "-d", `unit_amount=${product.gbp}`,
    "-d", "recurring[interval]=year",
    "-d", `product_data[name]=llmpilot Pro ${product.rung}`,
    // Managed Payments refuses line items whose product lacks an eligible
    // tax code (verified live 2026-07-12: sessions 400 without it).
    "-d", "product_data[tax_code]=txcd_10202000",
    "-d", `currency_options[usd][unit_amount]=${product.usd}`,
    "-d", `metadata[rung]=${product.rung}`,
  ];
  const result = spawnSync("stripe", args, { stdio: "inherit" });
  if (result.status !== 0) process.exit(result.status ?? 1);
}
