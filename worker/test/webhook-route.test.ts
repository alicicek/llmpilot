// The webhook route end to end: a Stripe-signed RAW body through the real
// router, signature check, size cap and dedupe table. The handler tests call
// handleEvent directly, so without these a framework bump that re-read or
// re-serialized the body would pass every other test and break payments.

import assert from "node:assert/strict";
import { test } from "node:test";

import Stripe from "stripe";

import { TestD1, makeKeys, makeEnv } from "./helpers.ts";
import worker from "../src/index.ts";

const KEYS = await makeKeys();
const SECRET = "whsec_test_fake"; // makeEnv's STRIPE_WEBHOOK_SECRET
const signer = new Stripe("sk_test_fake").webhooks;
const ctx = { waitUntil() {}, passThroughOnException() {} } as unknown as ExecutionContext;

// customer.created falls through handleEvent to "ignored": no Stripe call.
// Multi-byte text and odd spacing make any re-encoding change the bytes.
function eventBody(id: string, pad = ""): string {
  return `{"id": "${id}", "object": "event", "type": "customer.created",  "data": {"object": {"name": "Zoë 🚀 Øre"}}${pad}}`;
}

function post(body: string, sig: string | null): Request {
  const headers: Record<string, string> = { "content-type": "application/json" };
  if (sig !== null) headers["stripe-signature"] = sig;
  return new Request("https://api.llmpilot.dev/v1/stripe/webhook", { method: "POST", headers, body });
}

test("webhook route: a signed raw body is accepted once, then deduped", async () => {
  const db = new TestD1();
  const env = makeEnv(db, KEYS.signingKeyB64);
  const body = eventBody("evt_route_ok");
  const sig = signer.generateTestHeaderString({ payload: body, secret: SECRET });

  const first = await worker.fetch(post(body, sig), env, ctx);
  assert.equal(first.status, 200);
  assert.deepEqual(await first.json(), { received: true });
  assert.equal(db.row("webhook_events", "evt_route_ok")?.outcome, "ignored");

  const replay = await worker.fetch(post(body, sig), env, ctx);
  assert.equal(replay.status, 200);
  assert.deepEqual(await replay.json(), { received: true, deduped: true });
});

test("webhook route: a body changed after signing is refused and never recorded", async () => {
  const db = new TestD1();
  const env = makeEnv(db, KEYS.signingKeyB64);
  const signed = eventBody("evt_route_a");
  const sig = signer.generateTestHeaderString({ payload: signed, secret: SECRET });

  const res = await worker.fetch(post(eventBody("evt_route_b"), sig), env, ctx);
  assert.equal(res.status, 400);
  assert.deepEqual(await res.json(), { error: "bad_signature" });
  assert.equal(db.row("webhook_events", "evt_route_a"), null);
  assert.equal(db.row("webhook_events", "evt_route_b"), null);
});

test("webhook route: a signature from another secret is refused", async () => {
  const db = new TestD1();
  const env = makeEnv(db, KEYS.signingKeyB64);
  const body = eventBody("evt_route_foreign");
  const sig = signer.generateTestHeaderString({ payload: body, secret: "whsec_someone_else" });

  const res = await worker.fetch(post(body, sig), env, ctx);
  assert.equal(res.status, 400);
  assert.deepEqual(await res.json(), { error: "bad_signature" });
  assert.equal(db.row("webhook_events", "evt_route_foreign"), null);
});

test("webhook route: no signature header is refused before the body is read", async () => {
  const db = new TestD1();
  const env = makeEnv(db, KEYS.signingKeyB64);

  const res = await worker.fetch(post(eventBody("evt_route_nosig"), null), env, ctx);
  assert.equal(res.status, 400);
  assert.deepEqual(await res.json(), { error: "missing_signature" });
  assert.equal(db.row("webhook_events", "evt_route_nosig"), null);
});

test("webhook route: a correctly signed body over 256 KiB is refused", async () => {
  const db = new TestD1();
  const env = makeEnv(db, KEYS.signingKeyB64);
  const body = eventBody("evt_route_big", `, "pad": "${"x".repeat(256 * 1024)}"`);
  const sig = signer.generateTestHeaderString({ payload: body, secret: SECRET });

  const res = await worker.fetch(post(body, sig), env, ctx);
  assert.equal(res.status, 413);
  assert.deepEqual(await res.json(), { error: "payload_too_large" });
  assert.equal(db.row("webhook_events", "evt_route_big"), null);
});
