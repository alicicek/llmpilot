#!/usr/bin/env node
import { assertApprovedStripeIdentity, approvedStripeAccount, stripeProfile } from "./stripe-identity.mjs";

const commands = [
  ["stripe", "-p", stripeProfile, "get", "/v1/account"],
  ["stripe", "-p", stripeProfile, "listen", "--forward-to", "localhost:8787/v1/stripe/webhook"],
  ["stripe", "-p", stripeProfile, "trigger", "checkout.session.completed"],
  ["stripe", "-p", stripeProfile, "events", "resend", "<event-id>", "--webhook-endpoint", "<endpoint-id>"],
];
if (!process.argv.includes("--apply")) {
  console.log(JSON.stringify({ mode: "dry-run", expectedAccount: approvedStripeAccount, commands }));
  process.exit(0);
}
assertApprovedStripeIdentity();
console.log(JSON.stringify({ identity: approvedStripeAccount, livemode: false, next: "start wrangler dev and stripe listen in separate terminals, then run the documented test events" }));
