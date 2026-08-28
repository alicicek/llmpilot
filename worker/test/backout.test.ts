// Run: node --test --experimental-strip-types test/backout.test.ts
//
// The browser-checkout back-out path: cancel-token mint + cancel_url shape,
// the declined record (first-write-wins, pending-only, no oracle), the
// rate-limit fail case, expire-on-mint (one payable checkout per install),
// and declined riding the activate poll answer.

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
} from "./helpers.ts";
import { markDeclined } from "../src/lib/licenses.ts";
import { activateRoute } from "../src/routes/api.ts";
import { createCheckout, declinedRoute, newCancelToken, sessionParams } from "../src/routes/checkout.ts";

const KEYS = await makeKeys();
const API_ORIGIN = "https://api.example.dev";

/** Sequentially-unique session ids so expire-on-mint has distinct targets. */
function uniqueSessions(fake: ReturnType<typeof makeFakeStripe>) {
  let n = 0;
  (fake.stripe as { checkout: { sessions: { create: unknown } } }).checkout.sessions.create =
    async (params: Record<string, unknown>) => {
      fake.state.calls.push({ method: "sessions.create", args: [params] });
      n++;
      return { id: `cs_n${n}`, url: `https://checkout.stripe.com/c/cs_n${n}`, client_secret: null };
    };
}

async function mint(env: ReturnType<typeof makeEnv>, fake: ReturnType<typeof makeFakeStripe>, install = TEST_INSTALL) {
  const res = await createCheckout(
    env,
    { rung: "full", ui: "hosted", install_id: install, quote: testQuote("full") },
    "192.0.2.60",
    fake.stripe,
    API_ORIGIN,
  );
  assert.equal(res.status, 200);
  return res.body as { license: string; sessionId: string };
}

function declinedHit(
  env: ReturnType<typeof makeEnv>,
  fake: ReturnType<typeof makeFakeStripe>,
  token: string,
  ip = "192.0.2.61",
) {
  return declinedRoute(
    env,
    new Request(`${API_ORIGIN}/checkout/declined?t=${token}`, { headers: { "cf-connecting-ip": ip } }),
    fake.stripe,
  );
}

// ---- mint shape ---------------------------------------------------------------

test("backout: hosted mint stores the cancel token and session id; cancel_url carries the token on the API origin", async () => {
  const db = new TestD1();
  const env = makeEnv(db, KEYS.signingKeyB64);
  const fake = makeFakeStripe();
  const minted = await mint(env, fake);
  const row = db.row("licenses", minted.license)!;
  assert.match(row.cancel_token as string, /^[0-9a-f]{32}$/);
  assert.equal(row.session_id, "cs_new", "session id recorded at MINT time, not first fulfillment");
  assert.equal(row.declined_at, null);
  const params = calls(fake.state, "sessions.create")[0].args[0] as Record<string, unknown>;
  assert.equal(params.cancel_url, `${API_ORIGIN}/checkout/declined?t=${row.cancel_token}`);
  // The success URL keeps the documented template — only cancel_url changed.
  assert.ok((params.success_url as string).includes("{CHECKOUT_SESSION_ID}"));
});

test("backout: the embedded (1.3.3 fallback) mint keeps its shape — no cancel_url at all", () => {
  const env = makeEnv(new TestD1(), KEYS.signingKeyB64);
  const emb = sessionParams(env, "full", "lic_x", "embedded");
  assert.equal(emb.cancel_url, undefined);
  assert.equal(emb.success_url, undefined);
  // Direct hosted params without a per-checkout URL fall back to the site page.
  const hosted = sessionParams(env, "full", "lic_x", "hosted");
  assert.equal(hosted.cancel_url, "https://llmpilot.dev/pro/declined");
});

// ---- the declined record ------------------------------------------------------

test("backout: declined hit records once, EXPIRES the declined session, and every outcome redirects identically", async () => {
  const db = new TestD1();
  const env = makeEnv(db, KEYS.signingKeyB64);
  const fake = makeFakeStripe();
  const minted = await mint(env, fake);
  const token = db.row("licenses", minted.license)!.cancel_token as string;

  const hit = await declinedHit(env, fake, token);
  assert.equal(hit.status, 302);
  assert.equal(hit.headers.get("location"), "https://llmpilot.dev/pro/declined");
  const declinedAt = db.row("licenses", minted.license)!.declined_at as string;
  assert.ok(declinedAt, "back-out recorded");
  // The invariant the win-back rests on: the checkout that armed the
  // discount is no longer payable — a browser Back-press finds a dead page.
  assert.deepEqual(calls(fake.state, "sessions.expire").map((c) => c.args[0]), ["cs_new"]);

  // Replay: first-write-wins, the recorded instant never moves, and the
  // already-dead session is not expired again.
  const replay = await declinedHit(env, fake, token);
  assert.equal(replay.status, 302);
  assert.equal(db.row("licenses", minted.license)!.declined_at, declinedAt);
  assert.equal(calls(fake.state, "sessions.expire").length, 1);

  // Unknown-but-well-formed and malformed tokens: same redirect, no writes —
  // the endpoint is no oracle for token validity.
  for (const junk of [newCancelToken(), "zz", "", "0".repeat(31), "G".repeat(32)]) {
    const res = await declinedHit(env, fake, junk);
    assert.equal(res.status, 302);
    assert.equal(res.headers.get("location"), "https://llmpilot.dev/pro/declined");
  }
  assert.equal(calls(fake.state, "sessions.expire").length, 1, "junk never reaches Stripe");
});

test("backout: a payment completing under the back-out (expire refuses) still redirects and never breaks", async () => {
  const db = new TestD1();
  const env = makeEnv(db, KEYS.signingKeyB64);
  const fake = makeFakeStripe();
  const minted = await mint(env, fake);
  const token = db.row("licenses", minted.license)!.cancel_token as string;
  fake.state.failExpire = true;

  const hit = await declinedHit(env, fake, token);
  assert.equal(hit.status, 302);
  // The record stands; fulfillment idempotency owns the race, and a row
  // that then pays leaves pending — the flag stops meaning anything.
  assert.ok(db.row("licenses", minted.license)!.declined_at);
});

test("backout: a token older than its session's 24h life is dead — recorded nothing, expired nothing", async () => {
  const db = new TestD1();
  const env = makeEnv(db, KEYS.signingKeyB64);
  const fake = makeFakeStripe();
  const minted = await mint(env, fake);
  const token = db.row("licenses", minted.license)!.cancel_token as string;
  const old = new Date(Date.now() - 25 * 60 * 60 * 1000).toISOString();
  db.db.prepare("UPDATE licenses SET created_at = ? WHERE id = ?").run(old, minted.license);

  const res = await declinedHit(env, fake, token);
  assert.equal(res.status, 302);
  assert.equal(db.row("licenses", minted.license)!.declined_at, null);
  assert.equal(calls(fake.state, "sessions.expire").length, 0);
});

test("backout: a D1 failure still lands the buyer on the declined page", async () => {
  const db = new TestD1();
  const env = makeEnv(db, KEYS.signingKeyB64);
  const fake = makeFakeStripe();
  const broken = { ...env, ENT_DB: { prepare() { throw new Error("d1_down"); } } as never } as typeof env;

  const res = await declinedHit(broken, fake, newCancelToken());
  assert.equal(res.status, 302);
  assert.equal(res.headers.get("location"), "https://llmpilot.dev/pro/declined");
});

test("backout: an install already holding a live license is refused a second purchase; lapsed may re-buy", async () => {
  const db = new TestD1();
  const env = makeEnv(db, KEYS.signingKeyB64);
  const fake = makeFakeStripe();
  const first = await mint(env, fake);
  db.db.prepare("UPDATE licenses SET status = 'trialing' WHERE id = ?").run(first.license);

  const refused = await createCheckout(
    env,
    { rung: "full", ui: "hosted", install_id: TEST_INSTALL, quote: testQuote("full") },
    "192.0.2.60",
    fake.stripe,
    API_ORIGIN,
  );
  assert.equal(refused.status, 409);
  assert.equal(refused.body.error, "already_licensed");
  assert.equal(calls(fake.state, "sessions.create").length, 1, "no second session minted");

  // The guard's fail case both ways: lapsed is the designed comeback path.
  db.db.prepare("UPDATE licenses SET status = 'lapsed' WHERE id = ?").run(first.license);
  const comeback = await mint(env, fake);
  assert.ok(comeback.sessionId);
});

test("backout: a hit landing after payment changes nothing — paid state wins", async () => {
  const db = new TestD1();
  const env = makeEnv(db, KEYS.signingKeyB64);
  const fake = makeFakeStripe();
  const minted = await mint(env, fake);
  const token = db.row("licenses", minted.license)!.cancel_token as string;
  db.db.prepare("UPDATE licenses SET status = 'trialing' WHERE id = ?").run(minted.license);

  const res = await declinedHit(env, fake, token);
  assert.equal(res.status, 302);
  assert.equal(db.row("licenses", minted.license)!.declined_at, null);
  // The same guard, unit level: markDeclined only ever touches pending rows.
  assert.equal(await markDeclined(env.ENT_DB, token), null);
});

test("backout: the rate limit's fail case — the 61st hit from one IP skips the write but still redirects", async () => {
  const db = new TestD1();
  const env = makeEnv(db, KEYS.signingKeyB64);
  const fake = makeFakeStripe();
  const minted = await mint(env, fake);
  const token = db.row("licenses", minted.license)!.cancel_token as string;

  for (let i = 0; i < 60; i++) {
    assert.equal((await declinedHit(env, fake, newCancelToken(), "192.0.2.66")).status, 302);
  }
  const blocked = await declinedHit(env, fake, token, "192.0.2.66");
  assert.equal(blocked.status, 302, "rate-limited hits reveal nothing");
  assert.equal(db.row("licenses", minted.license)!.declined_at, null, "over-limit hit must not write");
  // A different IP is outside the exhausted window and records normally.
  await declinedHit(env, fake, token, "192.0.2.67");
  assert.ok(db.row("licenses", minted.license)!.declined_at);
});

// ---- expire-on-mint -----------------------------------------------------------

test("backout: a new mint expires the install's prior open sessions — one payable checkout at a time", async () => {
  const db = new TestD1();
  const env = makeEnv(db, KEYS.signingKeyB64);
  const fake = makeFakeStripe();
  uniqueSessions(fake);

  await mint(env, fake); // cs_n1
  assert.equal(calls(fake.state, "sessions.expire").length, 0, "first mint has nothing to expire");
  await mint(env, fake); // cs_n2 expires cs_n1
  assert.deepEqual(calls(fake.state, "sessions.expire").map((c) => c.args[0]), ["cs_n1"]);
  await mint(env, fake); // cs_n3 expires cs_n2 AND the still-pending cs_n1
  assert.deepEqual(calls(fake.state, "sessions.expire").map((c) => c.args[0]).sort(), ["cs_n1", "cs_n1", "cs_n2"].sort());
});

test("backout: expire-on-mint never crosses installs and skips non-pending rows", async () => {
  const db = new TestD1();
  const env = makeEnv(db, KEYS.signingKeyB64);
  const fake = makeFakeStripe();
  uniqueSessions(fake);

  const first = await mint(env, fake); // cs_n1, TEST_INSTALL
  // Another Mac minting must not close this install's live checkout.
  await mint(env, fake, installN(2)); // cs_n2
  assert.equal(calls(fake.state, "sessions.expire").length, 0);
  // A prior that LEFT pending (here: lapsed — trialing/lifetime would refuse
  // the mint itself via already_licensed) is not an expire target.
  db.db.prepare("UPDATE licenses SET status = 'lapsed' WHERE id = ?").run(first.license);
  await mint(env, fake); // cs_n3, TEST_INSTALL
  assert.equal(calls(fake.state, "sessions.expire").length, 0);
});

test("backout: a session that refuses to expire (just completed) never blocks the new mint", async () => {
  const db = new TestD1();
  const env = makeEnv(db, KEYS.signingKeyB64);
  const fake = makeFakeStripe();
  uniqueSessions(fake);
  await mint(env, fake); // cs_n1
  fake.state.failExpire = true;
  const second = await mint(env, fake); // expire throws, mint proceeds
  assert.equal(calls(fake.state, "sessions.expire").length, 1);
  assert.equal(second.sessionId, "cs_n2");
});

// ---- the activate answer ------------------------------------------------------

test("backout: declined rides the pending activate answer, and payment supersedes it", async () => {
  const db = new TestD1();
  const env = makeEnv(db, KEYS.signingKeyB64);
  const fake = makeFakeStripe();
  const minted = await mint(env, fake);
  const token = db.row("licenses", minted.license)!.cancel_token as string;

  // Still-open session: pending, no declined flag yet.
  fake.state.session = {
    id: "cs_new",
    payment_status: "unpaid",
    metadata: { license_id: minted.license },
    subscription: null,
    customer: null,
    customer_details: null,
    invoice: null,
  };
  const before = await activateRoute(env, { session_id: "cs_new", install_id: TEST_INSTALL }, fake.stripe as never);
  assert.deepEqual(await before.json(), { pending: true, status: "pending" });

  // Back-arrow lands: the very next poll tick carries the signal.
  await declinedHit(env, fake, token);
  const after = await activateRoute(env, { session_id: "cs_new", install_id: TEST_INSTALL }, fake.stripe as never);
  assert.deepEqual(await after.json(), { pending: true, status: "pending", declined: true });

  // History-back payment supersedes the back-out — no declined in a paid answer.
  fake.state.session = paidSession(minted.license, { id: "cs_new" });
  const paid = await activateRoute(env, { session_id: "cs_new", install_id: TEST_INSTALL }, fake.stripe as never);
  const body = (await paid.json()) as Record<string, unknown>;
  assert.equal(body.status, "lifetime");
  assert.equal(body.declined, undefined);
  assert.ok(body.entitlement, "paid answer serves the token as ever");
});

test("backout: activate reports session_expired so the daemon's reconcile can stop", async () => {
  const db = new TestD1();
  const env = makeEnv(db, KEYS.signingKeyB64);
  const fake = makeFakeStripe();
  const minted = await mint(env, fake);

  // An OPEN session carries no lifecycle flag — the poll keeps watching.
  fake.state.session = {
    id: "cs_new",
    status: "open",
    payment_status: "unpaid",
    metadata: { license_id: minted.license },
    subscription: null,
    customer: null,
    customer_details: null,
    invoice: null,
  };
  const open = await activateRoute(env, { session_id: "cs_new", install_id: TEST_INSTALL }, fake.stripe as never);
  assert.deepEqual(await open.json(), { pending: true, status: "pending" });

  // Once Stripe reports it expired, nothing can pay it — say so.
  fake.state.session = { ...(fake.state.session as Record<string, unknown>), status: "expired" };
  const expired = await activateRoute(env, { session_id: "cs_new", install_id: TEST_INSTALL }, fake.stripe as never);
  assert.deepEqual(await expired.json(), { pending: true, status: "pending", session_expired: true });
});
