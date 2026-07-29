#!/usr/bin/env node
import { assertApprovedStripeIdentity, approvedStripeAccount, stripeArgs } from "./stripe-identity.mjs";

// Built through the same argv builder the other scripts use, so a change to
// profile scoping cannot drift these documented commands.
const commands = [
  ["stripe", ...stripeArgs(["get", "/v1/account"])],
  ["stripe", ...stripeArgs(["listen", "--forward-to", "localhost:8787/v1/stripe/webhook"])],
  ["stripe", ...stripeArgs(["trigger", "checkout.session.completed"])],
  ["stripe", ...stripeArgs(["events", "resend", "<event-id>", "--webhook-endpoint", "<endpoint-id>"])],
];
if (!process.argv.includes("--apply")) {
  console.log(JSON.stringify({ mode: "dry-run", expectedAccount: approvedStripeAccount, commands }));
  process.exit(0);
}
// e2e is test-mode only; the guard throws on a live-mode CLI (env-key
// overrides included) before any command is suggested.
try {
  const identity = assertApprovedStripeIdentity({ live: false });
  console.log(JSON.stringify({ identity: identity.account, livemode: identity.livemode, next: "start wrangler dev and stripe listen in separate terminals, then run the documented test events" }));
} catch (err) {
  console.error(err instanceof Error ? err.message : String(err));
  process.exit(1);
}
