// llmpilot entitlement service — checkout, webhook, activate/validate/
// cancel/recover, and the trial-reminder cron. No telemetry, no listing
// endpoints; logs carry ids only.

import { Hono } from "hono";
import type { WorkerEnv } from "./env.ts";
import { checkoutPage, createCheckout, declinedRoute } from "./routes/checkout.ts";
import { getQuote } from "./routes/quote.ts";
import { webhookRoute } from "./routes/webhook.ts";
import { activateRoute, cancelRoute, claimRecoveryRoute, recoverRoute, validateRoute } from "./routes/api.ts";
import { runCancellationReconcile, runReminderSweep } from "./scheduled.ts";
import { assertSafeEnvironment } from "./lib/stripe.ts";
import { readTextBody } from "./lib/http.ts";

const app = new Hono<{ Bindings: WorkerEnv }>();

async function jsonBody(req: Request): Promise<Record<string, unknown> | null> {
  try {
    const raw = await readTextBody(req, 16 * 1024);
    if (raw === null) return null;
    const v = JSON.parse(raw) as unknown;
    return v && typeof v === "object" ? (v as Record<string, unknown>) : null;
  } catch {
    return null;
  }
}

app.get("/healthz", (c) => c.json({ ok: true }));
app.get("/checkout", (c) => checkoutPage(c.env, c.req.raw));
app.get("/checkout/declined", (c) => declinedRoute(c.env, c.req.raw));

// The landing site renders its pricing from the same quote the app paywall
// uses — CORS for exactly the site origins, GET only (no preflight needed).
const QUOTE_CORS_ORIGINS = new Set(["https://llmpilot.dev", "https://www.llmpilot.dev"]);

app.get("/v1/quote", async (c) => {
  const res = await getQuote(c.env, c.req.header("cf-connecting-ip") ?? "unknown");
  const origin = c.req.header("origin") ?? "";
  // vary on BOTH branches — a shared cache must never serve one origin's
  // CORS decision to another.
  const cors: Record<string, string> = QUOTE_CORS_ORIGINS.has(origin)
    ? { "access-control-allow-origin": origin, vary: "origin" }
    : { vary: "origin" };
  return c.json(res.body, res.status as 200, cors);
});

app.post("/v1/checkout", async (c) => {
  const body = await jsonBody(c.req.raw);
  if (!body) return c.json({ error: "invalid_json" }, 400);
  const res = await createCheckout(
    c.env,
    body as { rung?: string; ui?: string; install_id?: string },
    c.req.header("cf-connecting-ip") ?? "unknown",
    undefined,
    new URL(c.req.url).origin,
  );
  return c.json(res.body, res.status as 200);
});

app.post("/v1/stripe/webhook", (c) => webhookRoute(c.env, c.req.raw));

app.post("/v1/activate", async (c) => {
  const body = await jsonBody(c.req.raw);
  if (!body) return c.json({ error: "invalid_json" }, 400);
  return activateRoute(c.env, body);
});

app.post("/v1/validate", async (c) => {
  const body = await jsonBody(c.req.raw);
  if (!body) return c.json({ error: "invalid_json" }, 400);
  return validateRoute(c.env, body);
});

app.post("/v1/cancel", async (c) => {
  const body = await jsonBody(c.req.raw);
  if (!body) return c.json({ error: "invalid_json" }, 400);
  return cancelRoute(c.env, body);
});

app.post("/v1/recover", async (c) => {
  const body = await jsonBody(c.req.raw);
  if (!body) return c.json({ error: "invalid_json" }, 400);
  return recoverRoute(c.env, body, c.req.raw, (task) => c.executionCtx.waitUntil(task));
});

app.post("/v1/recover/claim", async (c) => {
  const body = await jsonBody(c.req.raw);
  if (!body) return c.json({ error: "invalid_json" }, 400);
  return claimRecoveryRoute(c.env, body);
});

export default {
  async fetch(request: Request, env: WorkerEnv, ctx: ExecutionContext): Promise<Response> {
    assertSafeEnvironment(env);
    return app.fetch(request, env, ctx);
  },
  async scheduled(controller: ScheduledController, env: WorkerEnv): Promise<void> {
    assertSafeEnvironment(env);
    if (controller.cron === "17 3 * * *") {
      await runCancellationReconcile(env);
      return;
    }
    // The sweep logs its own counts unconditionally — a "due N, sent 0"
    // line is the alarm the silent-failure incident never had.
    await runReminderSweep(env, new Date());
  },
} satisfies ExportedHandler<WorkerEnv>;
