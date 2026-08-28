// Deterministic test doubles, run under node --test (strip-types).
// TestD1 is a REAL SQLite (node:sqlite) behind a D1-shaped shim and applies
// the actual migration — the tests assert the migration is valid SQL as a
// side effect. Stripe is a recording fake; Ed25519 keys are REAL WebCrypto.

import { readFileSync, readdirSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { fileURLToPath, URL as NodeURL } from "node:url";
import { join } from "node:path";
import type { WorkerEnv } from "../src/env.ts";

class TestStmt {
  private bound: unknown[] = [];
  private db: DatabaseSync;
  private sql: string;
  constructor(db: DatabaseSync, sql: string) {
    this.db = db;
    this.sql = sql;
  }
  bind(...args: unknown[]) {
    this.bound = args;
    return this;
  }
  async first<T>(): Promise<T | null> {
    const row = this.db.prepare(this.sql).get(...(this.bound as never[]));
    return (row as T) ?? null;
  }
  async run() {
    const info = this.db.prepare(this.sql).run(...(this.bound as never[]));
    return { meta: { changes: Number(info.changes) } };
  }
  async all<T>() {
    const rows = this.db.prepare(this.sql).all(...(this.bound as never[]));
    return { results: rows as T[] };
  }
}

export class TestD1 {
  db: DatabaseSync;
  constructor() {
    this.db = new DatabaseSync(":memory:");
    const dir = fileURLToPath(new NodeURL("../migrations/", import.meta.url));
    for (const f of readdirSync(dir).filter((f) => f.endsWith(".sql")).sort()) {
      this.db.exec(readFileSync(join(dir, f), "utf8"));
    }
  }
  prepare(sql: string) {
    return new TestStmt(this.db, sql);
  }
  row(table: string, id: string): Record<string, unknown> | null {
    return (this.db.prepare(`SELECT * FROM ${table} WHERE id = ?`).get(id) as Record<string, unknown>) ?? null;
  }
}

// ---- real Ed25519 test keys --------------------------------------------------

export interface TestKeys {
  signingKeyB64: string; // base64(pkcs8) — what ENT_SIGNING_KEY holds
  verifyKey: CryptoKey;
  verifyRawB64: string;
}

export async function makeKeys(): Promise<TestKeys> {
  const pair = (await crypto.subtle.generateKey("Ed25519", true, [
    "sign",
    "verify",
  ])) as CryptoKeyPair;
  const pkcs8Export = await crypto.subtle.exportKey("pkcs8", pair.privateKey);
  const rawExport = await crypto.subtle.exportKey("raw", pair.publicKey);
  if (!(pkcs8Export instanceof ArrayBuffer) || !(rawExport instanceof ArrayBuffer)) throw new Error("unexpected_key_export");
  const pkcs8 = new Uint8Array(pkcs8Export);
  const raw = new Uint8Array(rawExport);
  const b64 = (b: Uint8Array) => Buffer.from(b).toString("base64");
  return { signingKeyB64: b64(pkcs8), verifyKey: pair.publicKey, verifyRawB64: b64(raw) };
}

// ---- recording fake Stripe ---------------------------------------------------

export interface FakeStripeState {
  session?: Record<string, unknown>;
  subscription?: Record<string, unknown>;
  calls: Array<{ method: string; args: unknown[] }>;
  failSubscriptionUpdate?: boolean;
  failExpire?: boolean;
  subscriptions?: Record<string, unknown>[];
  subscriptionPages?: Record<string, unknown>[][];
  invoicePayments?: Record<string, unknown>[];
  invoicePaymentsError?: boolean;
}

export function makeFakeStripe(state: Partial<FakeStripeState> = {}) {
  const st: FakeStripeState = { calls: [], ...state };
  let subscriptionPage = 0;
  const rec = (method: string, ...args: unknown[]) => st.calls.push({ method, args });
  const stripe = {
    checkout: {
      sessions: {
        async retrieve(id: string) {
          rec("sessions.retrieve", id);
          if (!st.session || st.session.id !== id) throw new Error(`no such session ${id}`);
          return st.session;
        },
        async create(params: Record<string, unknown>) {
          rec("sessions.create", params);
          return { id: "cs_new", url: "https://checkout.stripe.com/c/cs_new", client_secret: null };
        },
        async expire(id: string) {
          rec("sessions.expire", id);
          if (st.failExpire) throw new Error("session_not_expireable");
          return { id, status: "expired" };
        },
      },
    },
    prices: {
      async retrieve(id: string, params?: Record<string, unknown>) {
        rec("prices.retrieve", id, params);
        // Amounts mirror the real ladder: full £9.99/$12.99, discount AND
        // launch £5.99/$7.99 (the launch sale sells the full rung at the
        // discount amounts under its own Price id).
        const cheap = id.includes("discount") || id.includes("launch");
        return {
          id,
          type: "recurring",
          recurring: { interval: "year" },
          currency: "gbp",
          unit_amount: cheap ? 599 : 999,
          currency_options: {
            gbp: { unit_amount: cheap ? 599 : 999 },
            usd: { unit_amount: cheap ? 799 : 1299 },
          },
        };
      },
    },
    subscriptions: {
      async update(id: string, params: Record<string, unknown>) {
        rec("subscriptions.update", id, params);
        if (st.failSubscriptionUpdate) throw new Error("stripe_down");
        return { id, ...params };
      },
      async retrieve(id: string) {
        rec("subscriptions.retrieve", id);
        if (!st.subscription || st.subscription.id !== id) throw new Error(`no such sub ${id}`);
        return st.subscription;
      },
      async cancel(id: string) {
        rec("subscriptions.cancel", id);
        return { id, status: "canceled" };
      },
      async list() {
        rec("subscriptions.list");
        if (st.subscriptionPages) {
          const data = st.subscriptionPages[subscriptionPage] ?? [];
          subscriptionPage++;
          return { data, has_more: subscriptionPage < st.subscriptionPages.length };
        }
        return { data: st.subscriptions ?? [], has_more: false };
      },
    },
    invoicePayments: {
      async list(args: { invoice: string }) {
        rec("invoicePayments.list", args);
        if (st.invoicePaymentsError) throw new Error("stripe_down");
        return { data: st.invoicePayments ?? [{ status: "paid", payment: { type: "payment_intent", payment_intent: "pi_test_1" } }] };
      },
    },
  };
  return { stripe: stripe as never, state: st };
}

export function calls(st: FakeStripeState, method: string) {
  return st.calls.filter((c) => c.method === method);
}

// ---- env ---------------------------------------------------------------------

export function makeEnv(db: TestD1, signingKeyB64: string, over: Partial<WorkerEnv> = {}): WorkerEnv {
  return {
    ENT_DB: db as never,
    STRIPE_SECRET_KEY: "sk_test_fake",
    STRIPE_WEBHOOK_SECRET: "whsec_test_fake",
    STRIPE_PUBLISHABLE_KEY: "pk_test_fake",
    ENT_SIGNING_KEY: signingKeyB64,
    ENT_SIGNING_KEY_ID: "key_test_1",
    PRICE_FULL: "price_full_test",
    PRICE_DISCOUNT: "price_discount_test",
    ENVIRONMENT: "development",
    EMAIL_FROM: "support@llmpilot.dev",
    PUBLIC_ORIGIN: "https://llmpilot.dev",
    TRIAL_DAYS: "8",
    SEAT_LIMIT: "4",
    RESEND_API_KEY: "re_test_fake",
    EMAIL_HTTP: (async () => new Response('{"id":"email_test_1"}', { status: 200 })) as never,
    ...over,
  } as WorkerEnv;
}

/** An EMAIL_HTTP double that records each send's parsed JSON body plus the
 *  request headers (under `headers` — we never send a body field of that
 *  name) — tests assert on what would actually reach the provider, not on
 *  a hand-fed answer (the LaunchAgentInstalled lesson). Pass `status` to
 *  exercise the non-2xx outcomes. */
export function captureEmails(into: Array<Record<string, unknown>>, status = 200) {
  return (async (_url: unknown, init?: { body?: string; headers?: Record<string, string> }) => {
    into.push({ ...(JSON.parse(init?.body ?? "{}") as Record<string, unknown>), headers: init?.headers ?? {} });
    return new Response('{"id":"email_test_1"}', { status });
  }) as never;
}

/** The quote echo matching makeFakeStripe's prices + makeEnv's TRIAL_DAYS.
 *  Every rung leads with the trial, so every echo carries trial_days. */
export function testQuote(rung: "full" | "discount_trial" | "nocard_trial"): Record<string, unknown> {
  if (rung === "full") return { trial_days: 8, currency: "gbp", amount_minor: 999 };
  if (rung === "nocard_trial") return { trial_days: 8 };
  return { trial_days: 8, currency: "gbp", amount_minor: 599 };
}

/** A well-formed install id (UUIDv4 shape) for boundary-validated routes. */
export const TEST_INSTALL = "11111111-1111-4111-8111-111111111111";

/** More distinct install ids for seat-limit scenarios. */
export function installN(n: number): string {
  return `${String(n).padStart(8, "0")}-1111-4111-8111-111111111111`;
}

// ---- canned Stripe objects ----------------------------------------------------

export function paidSession(licenseId: string, over: Record<string, unknown> = {}) {
  return {
    id: "cs_1",
    payment_status: "paid",
    metadata: { license_id: licenseId, rung: "full" },
    customer: "cus_1",
    customer_details: { email: "Buyer@Example.dev" },
    subscription: {
      id: "sub_1",
      status: "active",
      cancel_at: null,
      metadata: { license_id: licenseId },
      items: { data: [{ current_period_end: Math.floor(Date.now() / 1000) + 365 * 86400 }] },
    },
    invoice: { id: "in_1" },
    currency: "gbp",
    amount_total: 999,
    ...over,
  };
}

export function trialSession(licenseId: string, trialEndEpoch: number, over: Record<string, unknown> = {}) {
  return {
    id: "cs_2",
    payment_status: "no_payment_required",
    metadata: { license_id: licenseId, rung: "discount_trial" },
    customer: "cus_2",
    customer_details: { email: "trial@example.dev" },
    subscription: {
      id: "sub_2",
      status: "trialing",
      trial_end: trialEndEpoch,
      cancel_at: null,
      metadata: { license_id: licenseId },
      items: { data: [{ current_period_end: trialEndEpoch }] },
    },
    invoice: null,
    currency: "gbp",
    amount_total: 0,
    ...over,
  };
}

/** A dahlia-shaped invoice: linkage at parent.subscription_details, no
 *  top-level subscription / payment_intent fields. */
export function dahliaInvoice(
  licenseId: string,
  subId: string,
  amountPaid: number,
  billingReason: string,
  over: Record<string, unknown> = {},
) {
  return {
    id: `in_${billingReason}_${amountPaid}`,
    object: "invoice",
    amount_paid: amountPaid,
    currency: "gbp",
    billing_reason: billingReason,
    parent: { subscription_details: { metadata: { license_id: licenseId }, subscription: subId } },
    ...over,
  };
}

export function stripeEvent(type: string, obj: Record<string, unknown>, id = `evt_${type}_1`) {
  return { id, type, data: { object: obj } } as never;
}
